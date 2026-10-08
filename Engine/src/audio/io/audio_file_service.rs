use super::decoder::{AudioDecoder, SymphoniaDecoder};
use super::peaks::PeakBuilder;
use super::sample_reader::{SampleReader, MAX_REQUEST_FRAMES};
use super::waveform_cache::{
    cleanup_stale_temp_files, generate_cache_key, get_cache_dir, PeakFile, CACHE_EXT,
};
use anyhow::Result;
use crossbeam::channel::{self, Receiver, Sender};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::fs;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

/// Job types for the worker pool
#[derive(Debug, Clone)]
pub enum AfsJob {
    DecodeAndWaveform { req_id: String, path: String },
    Cancel { req_id: String },
}

/// A raw-sample request, served by the dedicated sample thread (not the decode workers), so
/// deep-zoom drawing never waits behind a long decode.
#[derive(Debug, Clone)]
struct SamplesJob {
    req_id: String,
    cache_key: String,
    channel: u16,
    start_frame: u64,
    count: usize,
}

/// Events emitted by the service
#[derive(Debug, Clone)]
pub enum AfsEvent {
    DecodeReady {
        req_id: String,
        cache_key: String,
        channels: u16,
        frames: u64,
        sample_rate: u32,
        duration_s: f32,
        samples: Vec<f32>, // Interleaved PCM samples for engine playback
    },
    /// The peak file for `req_id` is complete and valid.
    WaveformReady {
        req_id: String,
        peak_file_path: String,
    },
    /// Raw native-rate samples of one channel, answering `request_samples`. `samples` may be
    /// shorter than requested (end of file).
    SamplesData {
        req_id: String,
        channel: u16,
        start_frame: u64,
        samples: Vec<f32>,
    },
    Progress {
        req_id: String,
        progress_0_1: f32,
    },
    Error {
        req_id: String,
        code: i32,
        message: String,
    },
}

/// Audio File Service with worker pool
pub struct AudioFileService {
    job_tx: Sender<AfsJob>,
    samples_tx: Sender<SamplesJob>,
    event_rx: Receiver<AfsEvent>,
    /// Rate files are decoded to: the device rate. Read per job, so a rate change (Phase 7)
    /// applies to the next load.
    project_sample_rate: Arc<AtomicU32>,
}

impl AudioFileService {
    /// Create a new service with specified number of workers
    pub fn new(num_workers: usize, project_sample_rate: u32) -> Result<Self> {
        let project_sample_rate = Arc::new(AtomicU32::new(project_sample_rate));
        let (job_tx, job_rx) = channel::unbounded();
        let (event_tx, event_rx) = channel::unbounded();

        // cache_key -> source path, filled by decode jobs so sample requests can name a file
        // by the key Godot already has.
        let known_files: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));

        if let Ok(dir) = get_cache_dir() {
            cleanup_stale_temp_files(&dir);
        }

        // Start worker threads
        for i in 0..num_workers {
            let job_rx = job_rx.clone();
            let event_tx = event_tx.clone();
            let project_sample_rate = Arc::clone(&project_sample_rate);
            let known_files = Arc::clone(&known_files);

            thread::spawn(move || {
                Self::worker_loop(i, job_rx, event_tx, project_sample_rate, known_files);
            });
        }

        let (samples_tx, samples_rx) = channel::unbounded();
        {
            let event_tx = event_tx.clone();
            let known_files = Arc::clone(&known_files);
            thread::spawn(move || Self::samples_loop(samples_rx, event_tx, known_files));
        }

        Ok(Self {
            job_tx,
            samples_tx,
            event_rx,
            project_sample_rate,
        })
    }

    /// Shared handle to the decode rate, so the OSC status thread can follow device rate
    /// changes.
    pub fn sample_rate_handle(&self) -> Arc<AtomicU32> {
        Arc::clone(&self.project_sample_rate)
    }

    /// Submit a job to decode and generate waveform
    pub fn submit_decode_and_waveform(&self, req_id: String, path: String) -> Result<()> {
        tracing::info!(request_id = %req_id, file = %path, "AFS enqueue decode job");
        self.job_tx
            .send(AfsJob::DecodeAndWaveform { req_id, path })?;
        Ok(())
    }

    /// Request `count` (at most 4096) native-rate samples of `channel` from frame
    /// `start_frame` of the file decoded under `cache_key`. Answered with
    /// `AfsEvent::SamplesData`, or `AfsEvent::Error` if the key is unknown.
    pub fn request_samples(
        &self,
        req_id: String,
        cache_key: String,
        channel: u16,
        start_frame: u64,
        count: usize,
    ) -> Result<()> {
        self.samples_tx.send(SamplesJob {
            req_id,
            cache_key,
            channel,
            start_frame,
            count: count.min(MAX_REQUEST_FRAMES),
        })?;
        Ok(())
    }

    /// Cancel a job
    pub fn cancel_job(&self, req_id: String) -> Result<()> {
        self.job_tx.send(AfsJob::Cancel { req_id })?;
        Ok(())
    }

    /// Poll for events (non-blocking)
    pub fn poll_events(&self) -> Vec<AfsEvent> {
        let mut events = Vec::new();
        while let Ok(event) = self.event_rx.try_recv() {
            events.push(event);
        }
        events
    }

    /// Worker thread main loop
    fn worker_loop(
        worker_id: usize,
        job_rx: Receiver<AfsJob>,
        event_tx: Sender<AfsEvent>,
        project_sample_rate: Arc<AtomicU32>,
        known_files: Arc<Mutex<HashMap<String, String>>>,
    ) {
        tracing::info!("Worker {} started", worker_id);

        loop {
            match job_rx.recv() {
                Ok(AfsJob::DecodeAndWaveform { req_id, path }) => {
                    tracing::debug!(
                        worker = worker_id,
                        request_id = %req_id,
                        file = %path,
                        "AFS worker processing job"
                    );
                    if let Err(e) = Self::process_decode_and_waveform(
                        &req_id,
                        &path,
                        project_sample_rate.load(Ordering::Relaxed),
                        &known_files,
                        &event_tx,
                    ) {
                        let _ = event_tx.send(AfsEvent::Error {
                            req_id,
                            code: -1,
                            message: e.to_string(),
                        });
                    }
                }
                Ok(AfsJob::Cancel { req_id }) => {
                    // Cancellation is handled by checking if job still exists
                    tracing::info!("Cancelled job {}", req_id);
                }
                Err(_) => {
                    // Channel closed, exit worker
                    break;
                }
            }
        }

        tracing::info!("Worker {} stopped", worker_id);
    }

    /// Sample thread: serves raw-sample requests in order from a per-file window cache.
    fn samples_loop(
        rx: Receiver<SamplesJob>,
        event_tx: Sender<AfsEvent>,
        known_files: Arc<Mutex<HashMap<String, String>>>,
    ) {
        let mut reader = SampleReader::new();
        while let Ok(job) = rx.recv() {
            let path = known_files.lock().unwrap().get(&job.cache_key).cloned();
            let result = match path {
                Some(path) => reader.read(
                    &job.cache_key,
                    &path,
                    job.channel as usize,
                    job.start_frame,
                    job.count,
                ),
                None => Err(anyhow::anyhow!("unknown cache key {}", job.cache_key)),
            };
            let event = match result {
                Ok(samples) => AfsEvent::SamplesData {
                    req_id: job.req_id,
                    channel: job.channel,
                    start_frame: job.start_frame,
                    samples,
                },
                Err(e) => AfsEvent::Error {
                    req_id: job.req_id,
                    code: -2,
                    message: e.to_string(),
                },
            };
            if event_tx.send(event).is_err() {
                break;
            }
        }
    }

    /// Decode the file for playback and make sure a valid peak file exists for it.
    ///
    /// Cache hit: decode PCM only. Cache miss: decode once, feeding native chunks to the
    /// `PeakBuilder` and resampled chunks to the playback buffer, then write the peak file
    /// atomically. Either way `DecodeReady` is sent first, then `WaveformReady`.
    fn process_decode_and_waveform(
        req_id: &str,
        path: &str,
        project_sample_rate: u32,
        known_files: &Mutex<HashMap<String, String>>,
        event_tx: &Sender<AfsEvent>,
    ) -> Result<()> {
        let metadata = fs::metadata(path)?;
        let src_size = metadata.len();
        let src_mtime_ns = metadata
            .modified()?
            .duration_since(SystemTime::UNIX_EPOCH)?
            .as_nanos() as u64;

        let cache_dir = get_cache_dir()?;
        fs::create_dir_all(&cache_dir)?;

        let cache_key = generate_cache_key(path, src_size, src_mtime_ns);
        let cache_path = cache_dir.join(format!("{}.{}", cache_key, CACHE_EXT));
        let cache_hit = PeakFile::is_valid(&cache_path, src_size, src_mtime_ns);
        known_files
            .lock()
            .unwrap()
            .insert(cache_key.clone(), path.to_string());

        tracing::info!(
            request_id = %req_id,
            file = %path,
            cache_key = %cache_key,
            cache_hit,
            "AFS job metadata resolved"
        );

        // The three decoder callbacks share this state; they never run concurrently.
        let builder: RefCell<Option<PeakBuilder>> = RefCell::new(None);
        let n_frames: Cell<Option<u64>> = Cell::new(None);
        let samples: RefCell<Vec<f32>> = RefCell::new(Vec::new());
        let mut last_progress = Instant::now();
        let mut native_frames = 0u64;

        let mut decoder = SymphoniaDecoder::new(path);
        let decoded_info = decoder.decode_to_f32_stream(
            project_sample_rate,
            &mut |info| {
                n_frames.set(info.n_frames);
                if !cache_hit {
                    *builder.borrow_mut() = Some(PeakBuilder::new(info.channels, info.sample_rate));
                }
                if let Some(n) = info.n_frames {
                    let resampled =
                        n as f64 * project_sample_rate as f64 / info.sample_rate.max(1) as f64;
                    samples
                        .borrow_mut()
                        .reserve((resampled as usize + 8192) * info.channels as usize);
                }
                Ok(())
            },
            &mut |chunk| {
                if let Some(b) = builder.borrow_mut().as_mut() {
                    b.push(chunk);
                }
                native_frames += chunk.first().map(|c| c.len()).unwrap_or(0) as u64;
                if let Some(total) = n_frames.get().filter(|&n| n > 0) {
                    if last_progress.elapsed() >= Duration::from_millis(100) {
                        last_progress = Instant::now();
                        let _ = event_tx.send(AfsEvent::Progress {
                            req_id: req_id.to_string(),
                            progress_0_1: (native_frames as f64 / total as f64).min(1.0) as f32,
                        });
                    }
                }
                Ok(())
            },
            &mut |chunk| {
                let num_frames = chunk[0].len();
                let mut samples = samples.borrow_mut();
                for frame_idx in 0..num_frames {
                    for ch in chunk {
                        samples.push(ch[frame_idx]);
                    }
                }
                Ok(())
            },
        )?;
        let samples = samples.into_inner();
        let builder = builder.into_inner();

        tracing::info!(
            request_id = %req_id,
            frames = decoded_info.frames,
            channels = decoded_info.channels,
            source_sample_rate = decoded_info.source_sample_rate,
            decoded_samples = samples.len(),
            "AFS decode completed"
        );

        event_tx.send(AfsEvent::DecodeReady {
            req_id: req_id.to_string(),
            cache_key: cache_key.clone(),
            channels: decoded_info.channels,
            frames: decoded_info.frames,
            sample_rate: decoded_info.sample_rate,
            duration_s: decoded_info.duration_s,
            samples,
        })?;

        if let Some(builder) = builder {
            let peaks = builder.finish();
            let tmp_path = cache_dir.join(format!(
                "{}.{}.{}.tmp",
                cache_key,
                std::process::id(),
                sanitize_for_filename(req_id)
            ));
            let written = PeakFile::write(&tmp_path, &peaks, src_size, src_mtime_ns)
                .and_then(|_| fs::rename(&tmp_path, &cache_path).map_err(Into::into));
            if let Err(e) = written {
                let _ = fs::remove_file(&tmp_path);
                return Err(e);
            }
            tracing::info!(
                request_id = %req_id,
                cache_path = %cache_path.display(),
                levels = peaks.levels.len(),
                "AFS peak file written"
            );
        }

        event_tx.send(AfsEvent::WaveformReady {
            req_id: req_id.to_string(),
            peak_file_path: cache_path.to_string_lossy().to_string(),
        })?;

        Ok(())
    }

    /// Test helper: wait for events with timeout
    #[cfg(test)]
    fn wait_for_events(&self, timeout_ms: u64) -> Vec<AfsEvent> {
        let mut events = Vec::new();
        let start = std::time::Instant::now();
        let timeout = Duration::from_millis(timeout_ms);

        while start.elapsed() < timeout {
            events.extend(self.poll_events());
            if !events.is_empty() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }

        events
    }
}

/// Request IDs look like `clip:<id>:<nanos>`; keep temp file names to safe characters.
fn sanitize_for_filename(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tests that point XDG_CACHE_HOME at a temp dir hold this, since the env is process-wide.
    static CACHE_ENV_LOCK: Mutex<()> = Mutex::new(());

    /// Test that AudioFileService can be created
    #[test]
    fn test_audio_file_service_creation() {
        let service = AudioFileService::new(2, 44100);
        assert!(service.is_ok());
    }

    /// Test cache directory resolution
    #[test]
    fn test_cache_directory() {
        // This test will work on systems with XDG_CACHE_HOME or home directory
        let cache_dir = get_cache_dir();
        match cache_dir {
            Ok(path) => {
                assert!(
                    path.ends_with("sonara/waveforms"),
                    "Cache path should end with sonara/waveforms"
                );
            }
            Err(e) => {
                // On some systems, this might fail - that's OK for testing
                println!("Cache directory not available: {}", e);
            }
        }
    }

    /// Write a 1 s stereo 16-bit WAV at 48 kHz.
    fn write_test_wav(path: &std::path::Path) {
        let sr = 48000u32;
        let frames = sr as usize;
        let mut data = Vec::with_capacity(frames * 4);
        for i in 0..frames {
            let v = ((i as f32 * 0.05).sin() * 16000.0) as i16;
            data.extend_from_slice(&v.to_le_bytes());
            data.extend_from_slice(&(-v).to_le_bytes());
        }
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&sr.to_le_bytes());
        wav.extend_from_slice(&(sr * 4).to_le_bytes());
        wav.extend_from_slice(&4u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
        wav.extend_from_slice(&data);
        fs::write(path, wav).unwrap();
    }

    /// Collect events until `WaveformReady` or `Error` arrives.
    fn run_job(service: &AudioFileService, req_id: &str, path: &str) -> Vec<AfsEvent> {
        service
            .submit_decode_and_waveform(req_id.to_string(), path.to_string())
            .unwrap();
        let mut events = Vec::new();
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(20) {
            events.extend(service.poll_events());
            if events
                .iter()
                .any(|e| matches!(e, AfsEvent::WaveformReady { .. } | AfsEvent::Error { .. }))
            {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        events
    }

    /// Decode (at a different project rate) and build peaks, then check the second run is a
    /// cache hit that reuses the same file. Uses a private XDG_CACHE_HOME.
    #[test]
    fn test_decode_and_waveform_integration() {
        let _env = CACHE_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CACHE_HOME", dir.path().join("cache"));
        let wav = dir.path().join("test.wav");
        write_test_wav(&wav);
        let wav = wav.to_string_lossy().to_string();

        let service = AudioFileService::new(1, 44100).unwrap();
        let events = run_job(&service, "req1", &wav);
        let decode_idx = events
            .iter()
            .position(|e| matches!(e, AfsEvent::DecodeReady { .. }))
            .expect("DecodeReady");
        let (ready_idx, peak_path) = events
            .iter()
            .enumerate()
            .find_map(|(i, e)| match e {
                AfsEvent::WaveformReady { peak_file_path, .. } => Some((i, peak_file_path.clone())),
                _ => None,
            })
            .expect("WaveformReady");
        assert!(decode_idx < ready_idx);
        if let AfsEvent::DecodeReady {
            sample_rate,
            channels,
            ..
        } = &events[decode_idx]
        {
            assert_eq!(*sample_rate, 44100);
            assert_eq!(*channels, 2);
        }

        let header = PeakFile::read_header(std::path::Path::new(&peak_path)).unwrap();
        assert!(header.complete);
        assert_eq!(header.source_sample_rate, 48000);
        assert_eq!(header.frames, 48000);
        let mtime = fs::metadata(&peak_path).unwrap().modified().unwrap();

        thread::sleep(Duration::from_millis(20));
        let events = run_job(&service, "req2", &wav);
        let second_path = events
            .iter()
            .find_map(|e| match e {
                AfsEvent::WaveformReady { peak_file_path, .. } => Some(peak_file_path.clone()),
                _ => None,
            })
            .expect("WaveformReady on second run");
        assert_eq!(second_path, peak_path);
        assert_eq!(
            fs::metadata(&peak_path).unwrap().modified().unwrap(),
            mtime,
            "second run should be a cache hit and not rewrite the peak file"
        );
    }

    /// After a decode registers the file, sample requests return native-rate frames by
    /// cache key; unknown keys answer with an error.
    #[test]
    fn test_request_samples() {
        let _env = CACHE_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("XDG_CACHE_HOME", dir.path().join("cache"));
        let wav = dir.path().join("samples.wav");
        write_test_wav(&wav);
        let wav = wav.to_string_lossy().to_string();

        let service = AudioFileService::new(1, 44100).unwrap();
        let events = run_job(&service, "load", &wav);
        let key = events
            .iter()
            .find_map(|e| match e {
                AfsEvent::DecodeReady { cache_key, .. } => Some(cache_key.clone()),
                _ => None,
            })
            .expect("DecodeReady");

        service
            .request_samples("s1".into(), key.clone(), 1, 1000, 8)
            .unwrap();
        service
            .request_samples("s2".into(), "nope".into(), 0, 0, 8)
            .unwrap();
        let mut events = Vec::new();
        let start = Instant::now();
        while events.len() < 2 && start.elapsed() < Duration::from_secs(10) {
            events.extend(service.poll_events());
            thread::sleep(Duration::from_millis(5));
        }
        match &events[0] {
            AfsEvent::SamplesData {
                req_id,
                channel,
                start_frame,
                samples,
            } => {
                assert_eq!((req_id.as_str(), *channel, *start_frame), ("s1", 1, 1000));
                assert_eq!(samples.len(), 8);
                // Right channel is the negated sine at 48 kHz (native rate, not 44.1 kHz).
                let expected = -(((1000.0f32 * 0.05).sin() * 16000.0) as i16) as f32 / 32768.0;
                assert!((samples[0] - expected).abs() < 1e-4);
            }
            other => panic!("expected SamplesData, got {:?}", other),
        }
        assert!(matches!(&events[1], AfsEvent::Error { req_id, .. } if req_id == "s2"));
    }

    /// Test error handling for non-existent file
    #[test]
    fn test_nonexistent_file_error() {
        let service = AudioFileService::new(1, 44100).unwrap();
        let req_id = "test_error".to_string();

        // Submit job for non-existent file
        service
            .submit_decode_and_waveform(req_id.clone(), "/nonexistent/file.wav".to_string())
            .unwrap();

        // Wait for events
        let events = service.wait_for_events(5000); // 5 second timeout

        assert!(!events.is_empty(), "Should receive at least one event");

        // Should receive an error event
        let has_error = events.iter().any(|e| matches!(e, AfsEvent::Error { .. }));
        assert!(
            has_error,
            "Should receive Error event for non-existent file"
        );
    }
}
