use super::decoder::{AudioDecoder, DecodedInfo, SymphoniaDecoder};
use super::waveform_cache::{
    generate_cache_key, get_cache_dir, is_cache_valid, WaveformCacheReader, WaveformCacheWriter,
};
use anyhow::{anyhow, Result};
use crossbeam::channel::{self, Receiver, Sender};
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime};

/// Job types for the worker pool
#[derive(Debug, Clone)]
pub enum AfsJob {
    DecodeAndWaveform {
        req_id: String,
        path: String,
        min_block_size: usize,
    },
    Cancel {
        req_id: String,
    },
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
    WaveformLevel {
        req_id: String,
        level: u16,
        block_size: u32,
        num_blocks: u64,
        file_path: String,
        byte_offset: u64,
        byte_len: u64,
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
    event_rx: Receiver<AfsEvent>,
    active_jobs: Arc<Mutex<HashMap<String, thread::JoinHandle<()>>>>,
    project_sample_rate: u32,
}

impl AudioFileService {
    /// Create a new service with specified number of workers
    pub fn new(num_workers: usize, project_sample_rate: u32) -> Result<Self> {
        let (job_tx, job_rx) = channel::unbounded();
        let (event_tx, event_rx) = channel::unbounded();

        let active_jobs = Arc::new(Mutex::new(HashMap::new()));

        // Start worker threads
        for i in 0..num_workers {
            let job_rx = job_rx.clone();
            let event_tx = event_tx.clone();
            let active_jobs_clone = active_jobs.clone();

            let handle = thread::spawn(move || {
                Self::worker_loop(i, job_rx, event_tx, active_jobs_clone, project_sample_rate);
            });

            // Store worker handles (though we don't use them directly)
            active_jobs
                .lock()
                .unwrap()
                .insert(format!("worker_{}", i), handle);
        }

        Ok(Self {
            job_tx,
            event_rx,
            active_jobs,
            project_sample_rate,
        })
    }

    /// Submit a job to decode and generate waveform
    pub fn submit_decode_and_waveform(
        &self,
        req_id: String,
        path: String,
        min_block_size: usize,
    ) -> Result<()> {
        tracing::info!(
            request_id = %req_id,
            file = %path,
            min_block_size = min_block_size,
            "AFS enqueue decode job"
        );
        self.job_tx.send(AfsJob::DecodeAndWaveform {
            req_id,
            path,
            min_block_size,
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
        _active_jobs: Arc<Mutex<HashMap<String, thread::JoinHandle<()>>>>,
        project_sample_rate: u32,
    ) {
        tracing::info!("Worker {} started", worker_id);

        loop {
            match job_rx.recv() {
                Ok(AfsJob::DecodeAndWaveform {
                    req_id,
                    path,
                    min_block_size,
                }) => {
                    tracing::debug!(
                        worker = worker_id,
                        request_id = %req_id,
                        file = %path,
                        min_block_size = min_block_size,
                        "AFS worker processing job"
                    );
                    if let Err(e) = Self::process_decode_and_waveform(
                        &req_id,
                        &path,
                        min_block_size,
                        project_sample_rate,
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

    /// Process decode and waveform generation job
    fn process_decode_and_waveform(
        req_id: &str,
        path: &str,
        min_block_size: usize,
        project_sample_rate: u32,
        event_tx: &Sender<AfsEvent>,
    ) -> Result<()> {
        // Get file metadata for cache key
        let metadata = fs::metadata(path)?;
        let size = metadata.len();
        let mtime = metadata
            .modified()?
            .duration_since(SystemTime::UNIX_EPOCH)?
            .as_secs();

        let cache_dir = get_cache_dir()?;
        fs::create_dir_all(&cache_dir)?;

        let decoder_version = "symphonia-0.5";
        let cache_key = generate_cache_key(path, size, mtime, project_sample_rate, decoder_version);
        let cache_path = cache_dir.join(&cache_key);

        // Check if cache is valid
        let use_cache = cache_path.exists()
            && is_cache_valid(
                &cache_path,
                path,
                size,
                mtime,
                project_sample_rate,
                decoder_version,
            );

        tracing::info!(
            request_id = %req_id,
            file = %path,
            min_block_size = min_block_size,
            cache_hit = use_cache,
            "AFS job metadata resolved"
        );

        if use_cache {
            // Load from cache - still need to decode PCM for engine playback
            let reader = WaveformCacheReader::open(&cache_path)?;
            let header = reader.header();

            tracing::info!(
                request_id = %req_id,
                cache_key = %cache_key,
                cache_path = %cache_path.display(),
                channels = header.channels,
                frames = header.frames,
                "AFS using cached waveform, re-decoding PCM"
            );

            // Decode PCM samples (cache only stores waveform, not full audio)
            let mut decoder = SymphoniaDecoder::new(path);
            let mut interleaved_samples = Vec::new();

            let decoded_info = decoder.decode_to_f32_stream(project_sample_rate, &mut |chunk: &[Vec<f32>]| {
                // Convert planar to interleaved
                let num_frames = chunk[0].len();
                let num_channels = chunk.len();

                // Debug: Log chunk info and first few samples
                if interleaved_samples.is_empty() {
                    tracing::info!(
                        request_id = %req_id,
                        num_channels = num_channels,
                        num_frames = num_frames,
                        "AFS cached path: chunk structure"
                    );
                    if num_channels > 0 && num_frames > 0 {
                        let first_left = chunk[0].get(0).copied().unwrap_or(0.0);
                        let first_right = chunk.get(1).and_then(|ch| ch.get(0)).copied().unwrap_or(0.0);
                        tracing::info!(
                            request_id = %req_id,
                            first_left = first_left,
                            first_right = first_right,
                            "AFS cached path: first planar samples"
                        );
                    }
                }

                for frame_idx in 0..num_frames {
                    for ch in 0..num_channels {
                        interleaved_samples.push(chunk[ch][frame_idx]);
                    }
                }
                Ok(())
            })?;

            tracing::info!(
                request_id = %req_id,
                decoded_samples = interleaved_samples.len(),
                "AFS PCM decode complete"
            );

            // Emit decode ready event with samples
            event_tx.send(AfsEvent::DecodeReady {
                req_id: req_id.to_string(),
                cache_key: cache_key.clone(),
                channels: header.channels,
                frames: header.frames,
                sample_rate: header.sample_rate,
                duration_s: header.frames as f32 / header.sample_rate as f32,
                samples: interleaved_samples,
            })?;

            // Emit all waveform levels
            for (level_idx, level_meta) in reader.level_metadata().iter().enumerate() {
                let total_bytes = level_meta
                    .channel_offsets
                    .iter()
                    .map(|&offset| {
                        // Calculate bytes per channel: num_blocks * 3 * 4 (f32)
                        (level_meta.num_blocks * 12) as u64
                    })
                    .sum::<u64>();

                event_tx.send(AfsEvent::WaveformLevel {
                    req_id: req_id.to_string(),
                    level: level_idx as u16,
                    block_size: level_meta.block_size,
                    num_blocks: level_meta.num_blocks,
                    file_path: cache_path.to_string_lossy().to_string(),
                    byte_offset: level_meta.channel_offsets[0], // First channel offset
                    byte_len: total_bytes,
                })?;

                tracing::debug!(
                    request_id = %req_id,
                    level = level_idx,
                    block_size = level_meta.block_size,
                    num_blocks = level_meta.num_blocks,
                    byte_len = total_bytes,
                    "AFS emitted cached waveform level"
                );
            }

            return Ok(());
        }

        // Decode and generate new cache
        tracing::info!(
            request_id = %req_id,
            file = %path,
            project_sample_rate = project_sample_rate,
            min_block_size = min_block_size,
            "AFS decoding source audio"
        );

        Self::decode_and_generate_cache(
            req_id,
            path,
            min_block_size,
            project_sample_rate,
            &cache_path,
            event_tx,
        )
    }

    /// Decode audio and generate waveform cache
    fn decode_and_generate_cache(
        req_id: &str,
        path: &str,
        min_block_size: usize,
        project_sample_rate: u32,
        cache_path: &Path,
        event_tx: &Sender<AfsEvent>,
    ) -> Result<()> {
        let mut decoder = SymphoniaDecoder::new(path);
        let mut all_chunks = Vec::new();
        let mut interleaved_samples = Vec::new();
        let mut total_frames = 0u64;

        // Decode in chunks to build pyramid progressively
        let decoded_info = decoder.decode_to_f32_stream(project_sample_rate, &mut |chunk: &[Vec<f32>]| {
            // Store planar chunks for waveform generation
            let planar_chunk: Vec<Vec<f32>> = chunk.to_vec();

            // Convert to interleaved for engine playback
            let num_frames = chunk[0].len();
            let num_channels = chunk.len();

            // Debug: Log chunk info and first few samples
            if interleaved_samples.is_empty() {
                tracing::info!(
                    request_id = %req_id,
                    num_channels = num_channels,
                    num_frames = num_frames,
                    "AFS new decode path: chunk structure"
                );
                if num_channels > 0 && num_frames > 0 {
                    let first_left = chunk[0].get(0).copied().unwrap_or(0.0);
                    let first_right = chunk.get(1).and_then(|ch| ch.get(0)).copied().unwrap_or(0.0);
                    tracing::info!(
                        request_id = %req_id,
                        first_left = first_left,
                        first_right = first_right,
                        "AFS new decode path: first planar samples"
                    );
                }
            }

            for frame_idx in 0..num_frames {
                for ch in 0..num_channels {
                    interleaved_samples.push(chunk[ch][frame_idx]);
                }
            }
            
            all_chunks.push(planar_chunk);
            total_frames += chunk[0].len() as u64;

            // Emit progress (rough estimate)
            let _ = event_tx.send(AfsEvent::Progress {
                req_id: req_id.to_string(),
                progress_0_1: 0.5, // Placeholder progress
            });

            Ok(())
        })?;

        tracing::info!(
            request_id = %req_id,
            file = %path,
            frames = decoded_info.frames,
            channels = decoded_info.channels,
            sample_rate = decoded_info.sample_rate,
            decoded_samples = interleaved_samples.len(),
            "AFS decode completed"
        );

        // Emit decode ready with samples
        event_tx.send(AfsEvent::DecodeReady {
            req_id: req_id.to_string(),
            cache_key: cache_path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .to_string(),
            channels: decoded_info.channels,
            frames: decoded_info.frames,
            sample_rate: decoded_info.sample_rate,
            duration_s: decoded_info.duration_s,
            samples: interleaved_samples,
        })?;

        // Build multi-resolution waveform
        Self::build_waveform_pyramid(
            req_id,
            &all_chunks,
            min_block_size,
            decoded_info.channels as usize,
            decoded_info.sample_rate,
            cache_path,
            event_tx,
        )?;

        Ok(())
    }

    /// Build multi-resolution waveform pyramid
    fn build_waveform_pyramid(
        req_id: &str,
        chunks: &[Vec<Vec<f32>>],
        min_block_size: usize,
        channels: usize,
        sample_rate: u32,
        cache_path: &Path,
        event_tx: &Sender<AfsEvent>,
    ) -> Result<()> {
        if channels == 0 {
            tracing::warn!(request_id = %req_id, "AFS no channels provided for waveform build");
            return Ok(());
        }

        let min_block_size = min_block_size.max(1);

        // Concatenate decoded chunks into a single planar buffer per channel once.
        let mut concatenated = vec![Vec::new(); channels];
        for chunk in chunks {
            for ch in 0..channels {
                if let Some(channel_samples) = chunk.get(ch) {
                    concatenated[ch].extend_from_slice(channel_samples);
                }
            }
        }

        let total_frames = concatenated
            .first()
            .map(|channel| channel.len())
            .unwrap_or(0);

        let min_block_size_u32 = min_block_size as u32;
        let mut levels = Vec::new();
        let mut block_size = ((total_frames / 2048).max(min_block_size)).max(1) as u32;
        if block_size < min_block_size_u32 {
            block_size = min_block_size_u32;
        }

        loop {
            levels.push(block_size);
            if block_size == min_block_size_u32 {
                break;
            }
            block_size = (block_size / 2).max(min_block_size_u32);
            if levels.last().copied() == Some(block_size) {
                break;
            }
        }

        tracing::debug!(
            request_id = %req_id,
            total_frames = total_frames,
            channels = channels,
            level_count = levels.len(),
            min_block_size = min_block_size,
            sample_rate = sample_rate,
            "AFS building waveform pyramid"
        );

        let mut writer = WaveformCacheWriter::create(
            cache_path,
            channels as u16,
            sample_rate,
            total_frames as u64,
            levels.len() as u16,
        )?;

        const BYTES_PER_SAMPLE: u64 = 4;

        for (level_idx, &block_sz) in levels.iter().enumerate() {
            let mut channel_data = vec![Vec::new(); channels];

            for ch in 0..channels {
                let data = &concatenated[ch];
                if data.is_empty() {
                    continue;
                }

                let block_len = block_sz as usize;
                let num_blocks = (data.len() + block_len - 1) / block_len;

                for block in 0..num_blocks {
                    let start = block * block_len;
                    let end = (start + block_len).min(data.len());
                    let block_data = &data[start..end];

                    if block_data.is_empty() {
                        continue;
                    }

                    let (min_val, max_val) = block_data.iter().fold(
                        (f32::INFINITY, f32::NEG_INFINITY),
                        |(min_acc, max_acc), &sample| (min_acc.min(sample), max_acc.max(sample)),
                    );

                    let sum_squares: f32 = block_data.iter().map(|&x| x * x).sum();
                    let rms = (sum_squares / block_data.len() as f32).sqrt();

                    channel_data[ch].extend_from_slice(&[min_val, max_val, rms]);
                }
            }

            let metadata = writer.add_level(level_idx as u16, block_sz, &channel_data)?;

            let total_blocks = metadata.num_blocks;
            let byte_offset = metadata.channel_offsets.first().copied().unwrap_or(0);
            let byte_len = total_blocks * 3 * BYTES_PER_SAMPLE * channels as u64;

            event_tx.send(AfsEvent::WaveformLevel {
                req_id: req_id.to_string(),
                level: level_idx as u16,
                block_size: block_sz,
                num_blocks: total_blocks,
                file_path: cache_path.to_string_lossy().to_string(),
                byte_offset,
                byte_len,
            })?;

            tracing::debug!(
                request_id = %req_id,
                level = level_idx,
                block_size = block_sz,
                num_blocks = total_blocks,
                byte_offset,
                byte_len,
                "AFS emitted waveform level"
            );
        }

        writer.finalize()?;

        tracing::info!(
            request_id = %req_id,
            cache_path = %cache_path.display(),
            level_count = levels.len(),
            "AFS cache generation complete"
        );

        Ok(())
    }

    /// Test helper: wait for events with timeout
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Test that AudioFileService can be created
    #[test]
    fn test_audio_file_service_creation() {
        let service = AudioFileService::new(2, 44100);
        assert!(service.is_ok());
    }

    /// Test waveform cache key generation
    #[test]
    fn test_cache_key_generation() {
        let key1 = generate_cache_key("/home/test.wav", 12345, 1000, 44100, "symphonia-0.5");
        let key2 = generate_cache_key("/home/test.wav", 12345, 1000, 44100, "symphonia-0.5");
        let key3 = generate_cache_key("/home/test.wav", 12346, 1000, 44100, "symphonia-0.5");

        assert_eq!(key1, key2, "Same inputs should produce same key");
        assert_ne!(key1, key3, "Different inputs should produce different keys");
        assert!(key1.ends_with(".swf"), "Key should end with .swf extension");
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

    /// Integration test: test decode and waveform generation (requires test audio file)
    #[test]
    #[ignore] // Skip by default as it requires external test file
    fn test_decode_and_waveform_integration() {
        // This test requires a test audio file to be present
        let test_file = PathBuf::from("test_audio.wav");
        if !test_file.exists() {
            println!("Skipping integration test - test_audio.wav not found");
            return;
        }

        let service = AudioFileService::new(1, 44100).unwrap();
        let req_id = "test_integration".to_string();

        // Submit decode and waveform job
        service
            .submit_decode_and_waveform(
                req_id.clone(),
                test_file.to_string_lossy().to_string(),
                128,
            )
            .unwrap();

        // Wait for events
        let events = service.wait_for_events(10000); // 10 second timeout

        assert!(!events.is_empty(), "Should receive at least one event");

        // Check for expected event types
        let has_decode_ready = events
            .iter()
            .any(|e| matches!(e, AfsEvent::DecodeReady { .. }));
        let has_waveform_level = events
            .iter()
            .any(|e| matches!(e, AfsEvent::WaveformLevel { .. }));

        assert!(has_decode_ready, "Should receive DecodeReady event");
        assert!(has_waveform_level, "Should receive WaveformLevel event");

        println!("Integration test passed - received {} events", events.len());
    }

    /// Test error handling for non-existent file
    #[test]
    fn test_nonexistent_file_error() {
        let service = AudioFileService::new(1, 44100).unwrap();
        let req_id = "test_error".to_string();

        // Submit job for non-existent file
        service
            .submit_decode_and_waveform(req_id.clone(), "/nonexistent/file.wav".to_string(), 128)
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
