//! Audio file service glue: pending clip and sampler loads, AudioFileService events and their
//! OSC messages.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::{OscMessage, OscPacket, OscType};
use std::net::{SocketAddr, UdpSocket};
use tracing::{debug, info, warn};

use super::server::OscServer;
use crate::audio::devices::DevicePath;
use crate::audio::io::AfsEvent;
use crate::audio::AudioCommand;

#[derive(Clone, Debug)]
pub(super) struct PendingClip {
    pub(super) clip_id: String,
    pub(super) source_path: String,
}

#[derive(Clone, Debug)]
pub(super) struct PendingDevice {
    pub(super) channel_id: usize,
    pub(super) device_path: DevicePath,
    /// A Sampler multisample zone, or None for the device's own sample.
    pub(super) zone_id: Option<u32>,
    pub(super) source_path: String,
}

/// Request ids of browser preview decodes start with this, so their results are routed to the
/// preview player instead of a clip or sampler.
const PREVIEW_REQ_PREFIX: &str = "preview:";

/// What the OSC thread knows about the browser preview (spec 037): the decode in flight and the
/// file whose PCM the engine holds, so playing the same file again needs no decode.
#[derive(Default)]
pub(super) struct PreviewTracker {
    /// Request id and path of the newest decode, until its result arrives.
    pending: Option<(String, String)>,
    /// Path of the PCM handed to the engine, until another play replaces it.
    loaded: Option<String>,
    counter: u64,
}

impl OscServer {
    /// `/preview/play`: play `path` from `start_s`, decoding it first unless the engine already
    /// holds its PCM. A newer play replaces the decode in flight (its result becomes stale).
    pub(super) fn play_preview(
        &self,
        path: String,
        start_s: f32,
        command_tx: &Sender<AudioCommand>,
    ) -> Result<()> {
        let req_id = {
            let mut preview = self.preview.lock().unwrap();
            if preview.loaded.as_deref() == Some(path.as_str()) {
                preview.pending = None;
                drop(preview);
                command_tx.send(AudioCommand::PlayLoadedPreview { path, start_s })?;
                return Ok(());
            }
            preview.counter += 1;
            let req_id = format!("{}{}", PREVIEW_REQ_PREFIX, preview.counter);
            preview.pending = Some((req_id.clone(), path.clone()));
            preview.loaded = None;
            req_id
        };
        command_tx.send(AudioCommand::BeginPreview {
            req_id: req_id.clone(),
            path: path.clone(),
            start_s,
        })?;
        let submitted = match self.audio_file_service.lock() {
            Ok(service) => service
                .submit_decode_and_waveform(req_id.clone(), path)
                .map_err(|err| err.to_string()),
            Err(err) => Err(err.to_string()),
        };
        if let Err(message) = submitted {
            warn!(
                "Failed to submit preview decode (req_id={}): {}",
                req_id, message
            );
            self.preview.lock().unwrap().pending = None;
            command_tx.send(AudioCommand::FailPreview { req_id, message })?;
        }
        Ok(())
    }

    /// `/preview/stop`: a decode still in flight is dropped when it arrives.
    pub(super) fn stop_preview(&self, command_tx: &Sender<AudioCommand>) -> Result<()> {
        self.preview.lock().unwrap().pending = None;
        command_tx.send(AudioCommand::StopPreview)?;
        Ok(())
    }

    /// A finished preview decode goes to the player if it is still the newest request.
    fn forward_preview_decode(
        &self,
        req_id: String,
        samples: Vec<f32>,
        sample_rate: u32,
        channels: usize,
        command_tx: &Sender<AudioCommand>,
    ) {
        let path = {
            let mut preview = self.preview.lock().unwrap();
            match preview.pending.take() {
                Some((pending_id, path)) if pending_id == req_id => {
                    preview.loaded = Some(path.clone());
                    path
                }
                other => {
                    preview.pending = other;
                    debug!(request_id = %req_id, "Dropping stale preview decode");
                    return;
                }
            }
        };
        info!(request_id = %req_id, path = %path, sample_count = samples.len(), "Preview decode ready");
        let _ = command_tx.send(AudioCommand::LoadPreview {
            req_id,
            samples,
            sample_rate,
            channels,
        });
    }

    /// Send AudioFileService event to the client
    fn send_afs_event(socket: &UdpSocket, client_port: u16, event: AfsEvent) {
        let (addr, args) = match event {
            AfsEvent::DecodeReady {
                req_id,
                cache_key,
                channels,
                frames,
                sample_rate,
                duration_s,
                samples, // Don't send samples over OSC (too large), just metadata
            } => (
                "/audiofile/decode/ready".to_string(),
                vec![
                    OscType::String(req_id),
                    OscType::String(cache_key),
                    OscType::Int(channels as i32),
                    OscType::Long(frames as i64),
                    OscType::Int(sample_rate as i32),
                    OscType::Float(duration_s),
                    OscType::Int(samples.len() as i32), // Send sample count for verification
                ],
            ),
            AfsEvent::WaveformReady {
                req_id,
                peak_file_path,
            } => (
                "/audiofile/waveform/ready".to_string(),
                vec![OscType::String(req_id), OscType::String(peak_file_path)],
            ),
            AfsEvent::SamplesData {
                req_id,
                channel,
                start_frame,
                samples,
            } => {
                let blob: Vec<u8> = samples.iter().flat_map(|v| v.to_le_bytes()).collect();
                (
                    "/audiofile/samples/data".to_string(),
                    vec![
                        OscType::String(req_id),
                        OscType::Int(channel as i32),
                        OscType::Long(start_frame as i64),
                        OscType::Blob(blob),
                    ],
                )
            }
            AfsEvent::Progress {
                req_id,
                progress_0_1,
            } => (
                "/audiofile/progress".to_string(),
                vec![OscType::String(req_id), OscType::Float(progress_0_1)],
            ),
            AfsEvent::Error {
                req_id,
                code,
                message,
            } => (
                "/audiofile/error".to_string(),
                vec![
                    OscType::String(req_id),
                    OscType::Int(code as i32),
                    OscType::String(message),
                ],
            ),
        };

        match &addr[..] {
            "/audiofile/decode/ready" => {
                if let [OscType::String(req_id), OscType::String(cache_key), OscType::Int(channels), OscType::Long(frames), OscType::Int(sample_rate), OscType::Float(duration_s), OscType::Int(sample_count)] =
                    &args[..]
                {
                    info!(
                        request_id = %req_id,
                        cache_key = %cache_key,
                        channels,
                        frames,
                        sample_rate,
                        duration = duration_s,
                        sample_count,
                        "OSC → Godot decode ready"
                    );
                }
            }
            "/audiofile/waveform/ready" => {
                if let [OscType::String(req_id), OscType::String(peak_file_path)] = &args[..] {
                    info!(
                        request_id = %req_id,
                        peak_file_path = %peak_file_path,
                        "OSC → Godot waveform ready"
                    );
                }
            }
            "/audiofile/progress" => {
                if let [OscType::String(req_id), OscType::Float(progress)] = &args[..] {
                    debug!(
                        request_id = %req_id,
                        progress,
                        "OSC → Godot progress"
                    );
                }
            }
            "/audiofile/error" => {
                if let [OscType::String(req_id), OscType::Int(code), OscType::String(message)] =
                    &args[..]
                {
                    warn!(
                        request_id = %req_id,
                        code,
                        message = %message,
                        "OSC → Godot error"
                    );
                }
            }
            _ => {}
        }

        let msg = OscMessage { addr, args };
        let packet = OscPacket::Message(msg);
        if let Ok(buf) = rosc::encoder::encode(&packet) {
            let client_addr = format!("127.0.0.1:{}", client_port);
            if let Ok(addr) = client_addr.parse::<SocketAddr>() {
                let _ = socket.send_to(&buf, addr);
            }
        }
    }

    pub(super) fn generate_clip_request_id(clip_id: &str) -> String {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        format!("clip:{}:{}", clip_id, now)
    }

    /// Submit an AudioFileService decode for a sampler device (or one of its zones) and track
    /// the request.
    pub(super) fn begin_device_sample_load(
        &self,
        channel_id: usize,
        device_path: DevicePath,
        zone_id: Option<u32>,
        file_path: String,
        req_id: String,
        command_tx: &Sender<AudioCommand>,
    ) -> Result<()> {
        info!(
            "Requesting sample load for channel {} device {} zone {:?} (req_id={}) from {}",
            channel_id, device_path, zone_id, req_id, file_path
        );
        {
            let mut pending = self.pending_device_loads.lock().unwrap();
            pending.insert(
                req_id.clone(),
                PendingDevice {
                    channel_id,
                    device_path: device_path.clone(),
                    zone_id,
                    source_path: file_path.clone(),
                },
            );
        }
        command_tx.send(AudioCommand::BeginLoadDeviceSample {
            channel_id,
            device_path: device_path.clone(),
            zone_id,
            req_id: req_id.clone(),
        })?;
        match self.audio_file_service.lock() {
            Ok(service) => {
                if let Err(err) =
                    service.submit_decode_and_waveform(req_id.clone(), file_path.clone())
                {
                    warn!(
                        "Failed to submit sample decode (req_id={}): {}",
                        req_id, err
                    );
                    self.pending_device_loads.lock().unwrap().remove(&req_id);
                    let _ = command_tx.send(AudioCommand::FailDeviceSampleLoad {
                        channel_id,
                        device_path,
                        zone_id,
                        req_id,
                        message: err.to_string(),
                    });
                }
            }
            Err(err) => {
                warn!("Failed to lock AudioFileService: {}", err);
                self.pending_device_loads.lock().unwrap().remove(&req_id);
                let _ = command_tx.send(AudioCommand::FailDeviceSampleLoad {
                    channel_id,
                    device_path,
                    zone_id,
                    req_id,
                    message: "AudioFileService unavailable".to_string(),
                });
            }
        }
        Ok(())
    }

    pub(super) fn handle_afs_event(&mut self, event: AfsEvent, command_tx: &Sender<AudioCommand>) {
        match event.clone() {
            AfsEvent::DecodeReady {
                req_id,
                cache_key,
                channels,
                sample_rate,
                samples,
                ..
            } => {
                if req_id.starts_with(PREVIEW_REQ_PREFIX) {
                    self.forward_preview_decode(
                        req_id,
                        samples,
                        sample_rate,
                        channels as usize,
                        command_tx,
                    );
                    Self::send_afs_event(&self.socket, self.client_port, event);
                    return;
                }
                let pending = {
                    let pending_guard = self.pending_clip_loads.lock().unwrap();
                    pending_guard.get(&req_id).cloned()
                };

                if let Some(pending_clip) = pending {
                    info!(
                        clip = %pending_clip.clip_id,
                        request_id = %req_id,
                        sample_rate,
                        channels,
                        sample_count = samples.len(),
                        "AudioFileService decode ready with samples"
                    );

                    // Samples already decoded by AFS worker thread - send directly to engine!
                    let command = AudioCommand::LoadAudioClip {
                        clip_id: pending_clip.clip_id.clone(),
                        req_id: req_id.clone(),
                        source_path: pending_clip.source_path.clone(),
                        cache_key: Some(cache_key.clone()),
                        samples,
                        sample_rate,
                        channels: channels as usize,
                    };

                    if let Err(err) = command_tx.send(command) {
                        warn!(
                            "Failed to forward LoadAudioClip command for {}: {}",
                            pending_clip.clip_id, err
                        );
                    }

                    let mut pending_guard = self.pending_clip_loads.lock().unwrap();
                    pending_guard.remove(&req_id);
                } else if let Some(pending_device) = {
                    let pending_guard = self.pending_device_loads.lock().unwrap();
                    pending_guard.get(&req_id).cloned()
                } {
                    info!(
                        channel = pending_device.channel_id,
                        device = %pending_device.device_path,
                        path = %pending_device.source_path,
                        request_id = %req_id,
                        sample_count = samples.len(),
                        "AudioFileService decode ready for sampler"
                    );
                    let command = AudioCommand::LoadDeviceSample {
                        channel_id: pending_device.channel_id,
                        device_path: pending_device.device_path,
                        zone_id: pending_device.zone_id,
                        req_id: req_id.clone(),
                        samples,
                        sample_rate,
                        channels: channels as usize,
                    };
                    if let Err(err) = command_tx.send(command) {
                        warn!("Failed to forward LoadDeviceSample: {}", err);
                    }
                    self.pending_device_loads.lock().unwrap().remove(&req_id);
                }
            }
            AfsEvent::WaveformReady {
                req_id,
                peak_file_path,
            } => {
                info!(
                    request_id = %req_id,
                    peak_file_path = %peak_file_path,
                    "AudioFileService waveform ready"
                );
            }
            AfsEvent::Progress {
                req_id,
                progress_0_1,
            } => {
                debug!(
                    request_id = %req_id,
                    progress = progress_0_1,
                    "AudioFileService progress"
                );
            }
            AfsEvent::Error {
                req_id, message, ..
            } => {
                if req_id.starts_with(PREVIEW_REQ_PREFIX) {
                    let was_pending = {
                        let mut preview = self.preview.lock().unwrap();
                        let current = preview
                            .pending
                            .as_ref()
                            .is_some_and(|(id, _)| *id == req_id);
                        if current {
                            preview.pending = None;
                        }
                        current
                    };
                    if was_pending {
                        let _ = command_tx.send(AudioCommand::FailPreview { req_id, message });
                    }
                    Self::send_afs_event(&self.socket, self.client_port, event);
                    return;
                }
                if let Some(pending_clip) = {
                    let pending_guard = self.pending_clip_loads.lock().unwrap();
                    pending_guard.get(&req_id).cloned()
                } {
                    warn!(
                        "AudioFileService error for clip {} (req_id={}): {}",
                        pending_clip.clip_id, req_id, message
                    );
                    let command = AudioCommand::FailAudioClipLoad {
                        clip_id: pending_clip.clip_id.clone(),
                        req_id: req_id.clone(),
                        message: message.clone(),
                    };
                    let _ = command_tx.send(command);
                    let mut pending_guard = self.pending_clip_loads.lock().unwrap();
                    pending_guard.remove(&req_id);
                } else if let Some(pending_device) = {
                    let pending_guard = self.pending_device_loads.lock().unwrap();
                    pending_guard.get(&req_id).cloned()
                } {
                    warn!(
                        "AudioFileService error for sampler channel {} path {} (req_id={}): {}",
                        pending_device.channel_id, pending_device.device_path, req_id, message
                    );
                    let _ = command_tx.send(AudioCommand::FailDeviceSampleLoad {
                        channel_id: pending_device.channel_id,
                        device_path: pending_device.device_path,
                        zone_id: pending_device.zone_id,
                        req_id: req_id.clone(),
                        message: message.clone(),
                    });
                    self.pending_device_loads.lock().unwrap().remove(&req_id);
                }
            }
            _ => {}
        }

        Self::send_afs_event(&self.socket, self.client_port, event);
    }
}

/// True when `path` is a PCM sample the Sampler can load (not an SFZ).
pub(super) fn is_audio_sample_path(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with(".wav") || lower.ends_with(".mp3") || lower.ends_with(".ogg")
}

/// Stable-enough request id when Godot does not supply one.
pub(super) fn generate_device_request_id(channel_id: usize, device_path: &DevicePath) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("device:{}:{}:{}", channel_id, device_path, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::io::AudioFileService;
    use std::sync::{Arc, Mutex};

    fn server() -> OscServer {
        OscServer::new(0, Arc::new(Mutex::new(AudioFileService::idle()))).expect("bind")
    }

    fn requests(rx: &crossbeam::channel::Receiver<AudioCommand>) -> Vec<AudioCommand> {
        rx.try_iter().collect()
    }

    #[test]
    fn a_decode_result_for_the_newest_preview_request_reaches_the_player() {
        let server = server();
        let (tx, rx) = crossbeam::channel::unbounded();
        server.play_preview("/s/a.wav".into(), 0.0, &tx).unwrap();
        let AudioCommand::BeginPreview { req_id, .. } = requests(&rx).remove(0) else {
            panic!("a play begins a preview");
        };
        server.forward_preview_decode(req_id.clone(), vec![0.0; 8], 48_000, 2, &tx);
        assert!(matches!(
            requests(&rx).as_slice(),
            [AudioCommand::LoadPreview { req_id: id, channels: 2, .. }] if *id == req_id
        ));
        // The same file again plays from memory without a decode.
        server.play_preview("/s/a.wav".into(), 0.5, &tx).unwrap();
        assert!(matches!(
            requests(&rx).as_slice(),
            [AudioCommand::PlayLoadedPreview { path, start_s }] if path == "/s/a.wav" && *start_s == 0.5
        ));
    }

    #[test]
    fn a_stale_or_stopped_preview_decode_is_dropped() {
        let server = server();
        let (tx, rx) = crossbeam::channel::unbounded();
        server.play_preview("/s/a.wav".into(), 0.0, &tx).unwrap();
        server.play_preview("/s/b.wav".into(), 0.0, &tx).unwrap();
        let begins = requests(&rx);
        let AudioCommand::BeginPreview { req_id: first, .. } = &begins[0] else {
            panic!("first begin");
        };
        let AudioCommand::BeginPreview { req_id: second, .. } = &begins[1] else {
            panic!("second begin");
        };
        server.forward_preview_decode(first.clone(), vec![0.0; 8], 48_000, 2, &tx);
        assert!(requests(&rx).is_empty(), "the replaced request is stale");
        server.stop_preview(&tx).unwrap();
        requests(&rx);
        server.forward_preview_decode(second.clone(), vec![0.0; 8], 48_000, 2, &tx);
        assert!(requests(&rx).is_empty(), "a stopped request is dropped");
    }
}
