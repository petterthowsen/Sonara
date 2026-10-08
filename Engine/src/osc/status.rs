//! The status thread: forwards `EngineStatus` to Godot, sends the heartbeat and folds the engine
//! stats into one log line per minute.

use crossbeam::channel::Receiver;
use rosc::{OscMessage, OscPacket, OscType};
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::AtomicU32;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tracing::info;

use super::gui::GuiEvent;
use super::server::OscServer;
use crate::audio::EngineStatus;

/// Spawn the status sender thread. It forwards plugin GUI events to the main loop through
/// `gui_event_tx`, follows audio config changes for the decode rate, and sends a heartbeat once
/// a second.
pub(super) fn spawn(
    socket_clone: UdpSocket,
    client_port: u16,
    decode_rate: Arc<AtomicU32>,
    status_rx: Receiver<EngineStatus>,
    gui_event_tx: std::sync::mpsc::Sender<GuiEvent>,
) {
    thread::spawn(move || {
        use std::time::Instant;
        let mut last_heartbeat = Instant::now();
        let heartbeat_interval = Duration::from_secs(1);
        let mut stats_summary = EngineStatsSummary::default();

        loop {
            if let Ok(status) = status_rx.recv_timeout(Duration::from_millis(10)) {
                // Forward GUI events to main loop
                match &status {
                    EngineStatus::EngineStats {
                        load_avg,
                        load_peak,
                        xruns,
                        lock_misses,
                        frames,
                        plugin_underruns,
                        frames_min,
                        frames_max,
                        peak_frames,
                        ..
                    } => stats_summary.observe(
                        *load_avg,
                        *load_peak,
                        *xruns,
                        *lock_misses,
                        *plugin_underruns,
                        *frames,
                        (*frames_min, *frames_max, *peak_frames),
                    ),
                    EngineStatus::PluginGuiOpened {
                        channel_id,
                        device_path,
                        width,
                        height,
                        floating,
                        ..
                    } => {
                        let _ = gui_event_tx.send(GuiEvent::Opened {
                            channel_id: *channel_id,
                            device_path: device_path.clone(),
                            width: *width,
                            height: *height,
                            floating: *floating,
                        });
                    }
                    EngineStatus::PluginGuiResizeRequest {
                        channel_id,
                        device_path,
                        width,
                        height,
                    } => {
                        let _ = gui_event_tx.send(GuiEvent::Resize {
                            channel_id: *channel_id,
                            device_path: device_path.clone(),
                            width: *width,
                            height: *height,
                        });
                    }
                    EngineStatus::PluginGuiClosed {
                        channel_id,
                        device_path,
                    } => {
                        let _ = gui_event_tx.send(GuiEvent::Closed {
                            channel_id: *channel_id,
                            device_path: device_path.clone(),
                        });
                    }
                    // Decode at the new rate before Godot hears about it and reloads.
                    EngineStatus::AudioConfigChanged { sample_rate } => {
                        decode_rate.store(*sample_rate, std::sync::atomic::Ordering::Relaxed);
                        info!("Audio files now decode to {} Hz", sample_rate);
                    }
                    _ => {}
                }

                OscServer::send_status_update(&socket_clone, client_port, status);
            }

            // Send periodic heartbeat
            if last_heartbeat.elapsed() >= heartbeat_interval {
                let addr = format!("127.0.0.1:{}", client_port);
                if let Ok(target) = addr.parse::<SocketAddr>() {
                    let msg = rosc::encoder::encode(&OscPacket::Message(OscMessage {
                        addr: "/status/heartbeat".to_string(),
                        args: vec![OscType::Int(1)],
                    }))
                    .unwrap_or_default();
                    let _ = socket_clone.send_to(&msg, target);
                }
                last_heartbeat = Instant::now();
            }
        }
    });
}

/// How often `EngineStatsSummary` logs.
const STATS_SUMMARY_INTERVAL: Duration = Duration::from_secs(60);

/// Folds the 2 Hz `EngineStats` into one info log line per minute, in the units of the
/// Measurements table in `docs/engine-stability-plan.md`.
#[derive(Default)]
struct EngineStatsSummary {
    started: Option<std::time::Instant>,
    samples: u32,
    load_sum: f32,
    load_peak: f32,
    /// Frames in the block that set `load_peak`.
    peak_frames: u32,
    frames_min: u32,
    frames_max: u32,
    xruns_at_start: u64,
    lock_misses_at_start: u64,
    plugin_underruns_at_start: u64,
}

impl EngineStatsSummary {
    fn observe(
        &mut self,
        load_avg: f32,
        load_peak: f32,
        xruns: u64,
        lock_misses: u64,
        plugin_underruns: u64,
        frames: u32,
        (frames_min, frames_max, peak_frames): (u32, u32, u32),
    ) {
        let Some(started) = self.started else {
            self.reset(xruns, lock_misses, plugin_underruns);
            return;
        };
        self.samples += 1;
        self.load_sum += load_avg;
        if load_peak > self.load_peak {
            self.load_peak = load_peak;
            self.peak_frames = peak_frames;
        }
        self.frames_min = if self.samples == 1 {
            frames_min
        } else {
            self.frames_min.min(frames_min)
        };
        self.frames_max = self.frames_max.max(frames_max);

        let elapsed = started.elapsed();
        if elapsed < STATS_SUMMARY_INTERVAL {
            return;
        }
        let per_min = 60.0 / elapsed.as_secs_f32();
        info!(
            "Engine stats ({:.0}s, {} frames, blocks {}-{}): load avg {:.1}%, load peak {:.1}% (in a {}-frame block), xruns/min {:.1}, lock misses/min {:.1}, plugin dropouts/min {:.1}",
            elapsed.as_secs_f32(),
            frames,
            self.frames_min,
            self.frames_max,
            self.load_sum / self.samples.max(1) as f32 * 100.0,
            self.load_peak * 100.0,
            self.peak_frames,
            xruns.saturating_sub(self.xruns_at_start) as f32 * per_min,
            lock_misses.saturating_sub(self.lock_misses_at_start) as f32 * per_min,
            plugin_underruns.saturating_sub(self.plugin_underruns_at_start) as f32 * per_min,
        );
        self.reset(xruns, lock_misses, plugin_underruns);
    }

    fn reset(&mut self, xruns: u64, lock_misses: u64, plugin_underruns: u64) {
        *self = Self {
            started: Some(std::time::Instant::now()),
            xruns_at_start: xruns,
            lock_misses_at_start: lock_misses,
            plugin_underruns_at_start: plugin_underruns,
            ..Self::default()
        };
    }
}
