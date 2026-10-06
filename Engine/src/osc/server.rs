use anyhow::{Context, Result};
use crossbeam::channel::{Receiver, Sender};
use rosc::{OscMessage, OscPacket, OscType};
use std::collections::HashMap;
use std::fs::{self, File};
use std::net::{SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{debug, info, warn};

use crate::audio::automation::{AutomationPoint, AutomationPointId, AutomationTarget, CurveKind};
use crate::audio::commands::BuiltinParamInfo;
use crate::audio::devices::sampler_zones::{GroupPlayMode, ZoneRanges, ZoneSettings};
use crate::audio::devices::{parse_osc_device_addr, DevicePath};
use crate::audio::io::{AfsEvent, AudioFileService};
use crate::audio::types::ClipLoadState;
use crate::audio::{AudioCommand, EngineStatus, ProjectSettings};
use crate::window_manager::WindowManager;

/// OSC server that receives messages from Godot UI and sends status updates
pub struct OscServer {
    socket: UdpSocket,
    client_addr: Option<SocketAddr>,
    client_port: u16,
    audio_file_service: Arc<Mutex<AudioFileService>>,
    pending_clip_loads: Arc<Mutex<HashMap<String, PendingClip>>>,
    pending_device_loads: Arc<Mutex<HashMap<String, PendingDevice>>>,
}

#[derive(Clone, Debug)]
struct PendingClip {
    clip_id: String,
    source_path: String,
}

#[derive(Clone, Debug)]
struct PendingDevice {
    channel_id: usize,
    device_path: DevicePath,
    /// A Sampler multisample zone, or None for the device's own sample.
    zone_id: Option<u32>,
    source_path: String,
}

/// Shared file handles for rotating log writers (info, warn, combined)
pub struct LogWriters {
    pub info: Arc<Mutex<File>>,
    pub warn: Arc<Mutex<File>>,
    pub combined: Arc<Mutex<File>>,
}

impl OscServer {
    /// Create a new OSC server listening on the specified port
    pub fn new(port: u16, audio_file_service: Arc<Mutex<AudioFileService>>) -> Result<Self> {
        let addr = format!("127.0.0.1:{}", port);
        let socket =
            UdpSocket::bind(&addr).context(format!("Failed to bind OSC server to {}", addr))?;

        socket.set_nonblocking(true)?;

        info!("OSC server listening on {}", addr);

        Ok(Self {
            socket,
            client_addr: None,
            client_port: 7001, // Godot listens on 7001
            audio_file_service,
            pending_clip_loads: Arc::new(Mutex::new(HashMap::new())),
            pending_device_loads: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    /// Start the OSC server and process incoming messages
    pub fn run(
        mut self,
        command_tx: Sender<AudioCommand>,
        status_rx: Receiver<EngineStatus>,
        log_writers: LogWriters,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        let mut buf = [0u8; 2048];

        // Tell Godot this is a new engine process so it can resync even if heartbeats never
        // timed out (a restart is often faster than HEARTBEAT_TIMEOUT_SEC).
        match self.send_message("/status/connected", vec![OscType::Int(1)]) {
            Ok(_) => info!("Sent /status/connected (engine ready)"),
            Err(e) => warn!("Failed to send /status/connected: {}", e),
        }

        // GUI events from audio thread that need window manager access
        enum GuiEvent {
            Opened {
                channel_id: usize,
                device_path: DevicePath,
                width: u32,
                height: u32,
                floating: bool,
            },
            Resize {
                channel_id: usize,
                device_path: DevicePath,
                width: u32,
                height: u32,
            },
            Closed {
                channel_id: usize,
                device_path: DevicePath,
            },
        }

        // Channel for forwarding GUI events from status thread to main loop
        let (gui_event_tx, gui_event_rx) = std::sync::mpsc::channel();

        // Spawn status sender thread
        let socket_clone = self.socket.try_clone()?;
        let client_port = self.client_port;
        let decode_rate = self.audio_file_service.lock().unwrap().sample_rate_handle();
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

                    Self::send_status_update(&socket_clone, client_port, status);
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

        // Main receive loop
        loop {
            // Check for GUI events
            while let Ok(event) = gui_event_rx.try_recv() {
                match event {
                    // The plugin refused to embed and opened its own window: the host window
                    // it was given is unused.
                    GuiEvent::Opened {
                        channel_id,
                        device_path,
                        floating: true,
                        ..
                    } => {
                        let process_key = device_path.to_window_key(channel_id);
                        info!(
                            "Plugin GUI {} opened floating, destroying its unused host window",
                            process_key
                        );
                        window_manager.destroy_window(&process_key);
                    }
                    GuiEvent::Opened {
                        channel_id,
                        device_path,
                        width,
                        height,
                        floating: false,
                    }
                    | GuiEvent::Resize {
                        channel_id,
                        device_path,
                        width,
                        height,
                    } => {
                        let process_key = device_path.to_window_key(channel_id);
                        info!("🔄 Resizing window {} to {}x{}", process_key, width, height);
                        window_manager.resize_window(&process_key, width, height);
                        window_manager.show_window(&process_key);
                    }
                    GuiEvent::Closed {
                        channel_id,
                        device_path,
                    } => {
                        let process_key = device_path.to_window_key(channel_id);
                        info!(
                            "🗑️  Plugin confirmed GUI closed, destroying window: {}",
                            process_key
                        );
                        window_manager.destroy_window(&process_key);
                    }
                }
            }

            // Check for AudioFileService events
            let events = {
                let mut service = self.audio_file_service.lock().unwrap();
                service.poll_events()
            };
            for event in events {
                self.handle_afs_event(event, &command_tx);
            }

            // Check for window close events (user clicked X)
            while let Ok(process_key) = window_manager.close_event_rx.try_recv() {
                info!("🗑️  Window close requested by user: {}", process_key);
                if let Some((channel_id, device_path)) = DevicePath::from_window_key(&process_key) {
                    let _ = command_tx.send(AudioCommand::ClosePluginGui {
                        channel_id,
                        device_path,
                    });
                }
            }

            match self.socket.recv_from(&mut buf) {
                Ok((size, addr)) => {
                    // Remember client address for sending status updates
                    if self.client_addr.is_none() {
                        info!("OSC client connected from {}", addr);
                        self.client_addr = Some(addr);

                        // Send connection confirmation
                        let _ = self.send_message("/status/playing", vec![OscType::Int(0)]);
                    }

                    // Parse OSC packet
                    match rosc::decoder::decode_udp(&buf[..size]) {
                        Ok((_, packet)) => {
                            if let Err(e) = self.handle_packet(
                                packet,
                                &command_tx,
                                &log_writers,
                                window_manager,
                            ) {
                                warn!("Error handling OSC packet: {}", e);
                            }
                        }
                        Err(e) => warn!("Dropped undecodable OSC packet ({} bytes): {:?}", size, e),
                    }
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // No data available, process window events and sleep briefly
                    window_manager.pump_events();
                    thread::sleep(Duration::from_millis(1));
                }
                Err(e) => {
                    warn!("Error receiving OSC message: {}", e);
                }
            }
        }
    }

    /// Handle an incoming OSC packet
    fn handle_packet(
        &self,
        packet: OscPacket,
        command_tx: &Sender<AudioCommand>,
        log_writers: &LogWriters,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        match packet {
            OscPacket::Message(msg) => {
                self.handle_message(msg, command_tx, log_writers, window_manager)
            }
            OscPacket::Bundle(bundle) => {
                for packet in bundle.content {
                    self.handle_packet(packet, command_tx, log_writers, window_manager)?;
                }
                Ok(())
            }
        }
    }

    /// Rotate all log files to timestamped session files and enforce retention
    fn rotate_log_files(log_writers: &LogWriters) -> Result<()> {
        use chrono::Local;
        use std::io::Write;

        const MAX_SESSIONS: usize = 5;

        // Generate timestamp for the archived log files
        let timestamp = Local::now().format("%Y%m%d_%H%M%S");

        // Helper to rotate a single writer from last_*.txt → session_*_*.log
        fn rotate_one(
            current_path: &str,
            archived_path: &str,
            writer: &Arc<Mutex<File>>,
        ) -> Result<()> {
            // Announce rotation before swapping handles so message goes to old file
            info!("Rotating log file to {}", archived_path);

            if let Ok(mut w) = writer.lock() {
                let _ = w.flush();
                *w = File::create(format!("{}.tmp", current_path))?;
            }

            if Path::new(current_path).exists() {
                fs::rename(current_path, archived_path)?;
            }

            // Remove temp and recreate the current file
            let tmp_path = format!("{}.tmp", current_path);
            if Path::new(&tmp_path).exists() {
                fs::remove_file(&tmp_path)?;
            }

            let new_file = File::create(current_path)?;
            if let Ok(mut w) = writer.lock() {
                *w = new_file;
            }

            Ok(())
        }

        // Compose archived names
        let info_archived = format!("logs/session_{}_info.log", timestamp);
        let warn_archived = format!("logs/session_{}_warn.log", timestamp);
        let combined_archived = format!("logs/session_{}_combined.log", timestamp);

        // Rotate each log
        rotate_one("logs/last_info.log", &info_archived, &log_writers.info)?;
        rotate_one("logs/last_warn.log", &warn_archived, &log_writers.warn)?;
        rotate_one(
            "logs/last_combined.log",
            &combined_archived,
            &log_writers.combined,
        )?;

        // Enforce retention: keep last N per type
        fn enforce_retention(prefix: &str, suffix: &str) -> Result<()> {
            let mut files: Vec<_> = fs::read_dir("logs")?
                .filter_map(|e| e.ok())
                .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
                .map(|e| e.path())
                .filter(|p| {
                    if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                        name.starts_with(prefix) && name.ends_with(suffix)
                    } else {
                        false
                    }
                })
                .collect();

            files.sort(); // timestamp is in filename, ascending
            let excess = files.len().saturating_sub(MAX_SESSIONS);
            if excess > 0 {
                for p in files.into_iter().take(excess) {
                    let _ = fs::remove_file(p);
                }
            }
            Ok(())
        }

        enforce_retention("session_", "_info.log")?;
        enforce_retention("session_", "_warn.log")?;
        enforce_retention("session_", "_combined.log")?;

        info!("Log rotation complete - new session started");

        Ok(())
    }

    /// Dispatch `/channel/{id}/device/{path}/...` commands (nested `child` segments allowed).
    fn handle_device_message(
        &self,
        channel_id: usize,
        device_path: DevicePath,
        action: &[String],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        let action_refs: Vec<&str> = action.iter().map(|s| s.as_str()).collect();
        match action_refs.as_slice() {
            ["activate"] => {
                if let Some(OscType::Int(active)) = args.first() {
                    command_tx.send(AudioCommand::SetDeviceActive {
                        channel_id,
                        device_path,
                        active: *active != 0,
                    })?;
                }
            }
            ["enable"] => {
                if let Some(OscType::Int(enabled)) = args.first() {
                    command_tx.send(AudioCommand::SetDeviceEnabled {
                        channel_id,
                        device_path,
                        enabled: *enabled != 0,
                    })?;
                }
            }
            ["load_file"] => {
                if let Some(OscType::String(file_path)) = args.first() {
                    if is_audio_sample_path(file_path) {
                        let req_id = match args.get(1) {
                            Some(OscType::String(id)) if !id.is_empty() => id.clone(),
                            _ => generate_device_request_id(channel_id, &device_path),
                        };
                        self.begin_device_sample_load(
                            channel_id,
                            device_path,
                            None,
                            file_path.clone(),
                            req_id,
                            command_tx,
                        )?;
                    } else {
                        command_tx.send(AudioCommand::LoadDeviceFile {
                            channel_id,
                            device_path,
                            file_path: file_path.clone(),
                        })?;
                    }
                }
            }
            // Optional `parent_xid x y w h`: embed the host window before it is first mapped
            ["gui", "open"] => {
                let process_key = device_path.to_window_key(channel_id);
                let embed = if args.is_empty() {
                    None
                } else {
                    let embed = parse_embed_args(args, true);
                    if embed.is_none() {
                        warn!(
                            "gui/open: expected parent_xid x y w h, got {:?}; opening floating",
                            args
                        );
                    }
                    embed
                };
                let window_handle = window_manager.create_window(process_key, 800, 600, embed);
                if let (Some(_), Some((parent_xid, _))) = (window_handle, embed) {
                    self.send_gui_embedded(channel_id, &device_path, parent_xid);
                }
                command_tx.send(AudioCommand::OpenPluginGui {
                    channel_id,
                    device_path,
                    window_handle,
                })?;
            }
            // Embed the plugin's host window into a Godot window (ADR 0016)
            ["gui", "embed"] => {
                let process_key = device_path.to_window_key(channel_id);
                match parse_embed_args(args, true) {
                    Some((parent_xid, rect)) => {
                        if window_manager.embed_window(&process_key, parent_xid, rect) {
                            self.send_gui_embedded(channel_id, &device_path, parent_xid);
                        }
                    }
                    None => warn!(
                        "gui/embed: expected parent_xid x y w h [scroll_x scroll_y], got {:?}",
                        args
                    ),
                }
            }
            ["gui", "bounds"] => {
                let process_key = device_path.to_window_key(channel_id);
                match parse_embed_args(args, false) {
                    Some((_, rect)) => window_manager.set_embed_bounds(&process_key, rect),
                    None => warn!(
                        "gui/bounds: expected x y w h [scroll_x scroll_y], got {:?}",
                        args
                    ),
                }
            }
            ["gui", "unembed"] => {
                let process_key = device_path.to_window_key(channel_id);
                if window_manager.unembed_window(&process_key) {
                    self.send_gui_embedded(channel_id, &device_path, 0);
                }
            }
            ["gui", "visible"] => match args.first().and_then(osc_int) {
                Some(visible) => {
                    let visible = visible != 0;
                    let process_key = device_path.to_window_key(channel_id);
                    window_manager.set_window_visible(&process_key, visible);
                    command_tx.send(AudioCommand::SetPluginGuiVisible {
                        channel_id,
                        device_path,
                        visible,
                    })?;
                }
                None => warn!("gui/visible: expected visible:i, got {:?}", args),
            },
            ["gui", "size"] => match (
                args.first().and_then(osc_int),
                args.get(1).and_then(osc_int),
            ) {
                (Some(width), Some(height)) if width > 0 && height > 0 => {
                    command_tx.send(AudioCommand::SetPluginGuiSize {
                        channel_id,
                        device_path,
                        width: width as u32,
                        height: height as u32,
                    })?;
                }
                _ => warn!("gui/size: expected w:i h:i (positive), got {:?}", args),
            },
            ["gui", "close"] => {
                // Hide the host window and take it out of the Godot window first, so Godot can
                // free its window at once. It is destroyed once the plugin confirms the close.
                let process_key = device_path.to_window_key(channel_id);
                if window_manager.release_window(&process_key) {
                    self.send_gui_embedded(channel_id, &device_path, 0);
                }
                command_tx.send(AudioCommand::ClosePluginGui {
                    channel_id,
                    device_path,
                })?;
            }
            ["param", param_id_str] => {
                if let Ok(param_id) = param_id_str.parse::<u32>() {
                    match args.first() {
                        Some(OscType::Float(v)) => {
                            command_tx.send(AudioCommand::SetDeviceParameter {
                                channel_id,
                                device_path,
                                param_id,
                                value: crate::audio::types::ParamSetValue::Normalized(*v),
                            })?;
                        }
                        Some(OscType::Int(i)) => {
                            command_tx.send(AudioCommand::SetDeviceParameter {
                                channel_id,
                                device_path,
                                param_id,
                                value: crate::audio::types::ParamSetValue::Index(*i),
                            })?;
                        }
                        _ => {}
                    }
                }
            }
            ["modulator", ..] => {
                if let Some(cmd) =
                    parse_modulator_command(channel_id, device_path, &action_refs, args)
                {
                    command_tx.send(cmd)?;
                }
            }
            ["data", "subscribe"] => {
                if let Some(OscType::String(data_type)) = args.first() {
                    command_tx.send(AudioCommand::SubscribeDeviceData {
                        channel_id,
                        device_path,
                        data_type: data_type.clone(),
                    })?;
                }
            }
            ["data", "unsubscribe"] => {
                if let Some(OscType::String(data_type)) = args.first() {
                    command_tx.send(AudioCommand::UnsubscribeDeviceData {
                        channel_id,
                        device_path,
                        data_type: data_type.clone(),
                    })?;
                }
            }
            ["data", "configure"] => {
                let value = match args.get(2) {
                    Some(OscType::Float(v)) => Some(*v),
                    Some(OscType::Int(v)) => Some(*v as f32),
                    Some(OscType::Double(v)) => Some(*v as f32),
                    _ => None,
                };
                if let (Some(OscType::String(data_type)), Some(OscType::String(key)), Some(value)) =
                    (args.first(), args.get(1), value)
                {
                    command_tx.send(AudioCommand::ConfigureDeviceData {
                        channel_id,
                        device_path,
                        data_type: data_type.clone(),
                        key: key.clone(),
                        value,
                    })?;
                } else {
                    warn!(
                        "/data/configure expects [s:data_type, s:key, f:value]: {:?}",
                        args
                    );
                }
            }
            ["add_device"] => {
                if let Some(cmd) = parse_add_device_command(channel_id, device_path, args) {
                    command_tx.send(cmd)?;
                }
            }
            ["remove_device"] => {
                if let Some(OscType::Int(position)) = args.first() {
                    command_tx.send(AudioCommand::RemoveDeviceFromChannel {
                        channel_id,
                        parent_path: device_path,
                        position: *position as usize,
                    })?;
                }
            }
            ["move_device"] => {
                if let (Some(OscType::Int(from_pos)), Some(OscType::Int(to_pos))) =
                    (args.get(0), args.get(1))
                {
                    command_tx.send(AudioCommand::MoveDevice {
                        channel_id,
                        parent_path: device_path,
                        from_position: *from_pos as usize,
                        to_position: *to_pos as usize,
                    })?;
                }
            }
            ["get_parameters"] => {
                command_tx.send(AudioCommand::GetPluginParameters {
                    channel_id,
                    device_path,
                })?;
            }
            ["state", "get"] => {
                command_tx.send(AudioCommand::GetDeviceState {
                    channel_id,
                    device_path,
                })?;
            }
            ["state", "save"] => {
                if let Some(OscType::String(file_path)) = args.first() {
                    command_tx.send(AudioCommand::SavePluginState {
                        channel_id,
                        device_path,
                        file_path: file_path.clone(),
                    })?;
                }
            }
            ["state", "load"] => {
                if let Some(OscType::String(file_path)) = args.first() {
                    command_tx.send(AudioCommand::LoadPluginState {
                        channel_id,
                        device_path,
                        file_path: file_path.clone(),
                    })?;
                }
            }
            // Reload a crashed plugin: respawn its host and restore its state (Phase 4).
            ["reload"] => {
                command_tx.send(AudioCommand::ReloadDevice {
                    channel_id,
                    device_path,
                })?;
            }
            // Sampler multisample (spec 023)
            ["multisample"] => match args.first().and_then(osc_int) {
                Some(on) => command_tx.send(AudioCommand::SetSamplerMode {
                    channel_id,
                    device_path,
                    multisample: on != 0,
                })?,
                None => warn!("multisample needs an int, got {:?}", args),
            },
            ["zone", zid, "set"] => match (zid.parse::<u32>(), parse_zone_set(args)) {
                (Ok(zone_id), Ok(settings)) => command_tx.send(AudioCommand::SetSamplerZone {
                    channel_id,
                    device_path,
                    zone_id,
                    settings,
                })?,
                (zone_id, settings) => warn!(
                    "Bad zone/{}/set on channel {} path {}: {:?} {:?}",
                    zid,
                    channel_id,
                    device_path,
                    zone_id.err(),
                    settings.err()
                ),
            },
            ["zone", zid, "load_file"] => match (zid.parse::<u32>(), args.first()) {
                (Ok(zone_id), Some(OscType::String(file_path)))
                    if is_audio_sample_path(file_path) =>
                {
                    let req_id = match args.get(1) {
                        Some(OscType::String(id)) if !id.is_empty() => id.clone(),
                        _ => generate_device_request_id(channel_id, &device_path),
                    };
                    self.begin_device_sample_load(
                        channel_id,
                        device_path,
                        Some(zone_id),
                        file_path.clone(),
                        req_id,
                        command_tx,
                    )?;
                }
                _ => warn!(
                    "Bad zone/{}/load_file on channel {} path {}: {:?}",
                    zid, channel_id, device_path, args
                ),
            },
            ["zone", zid, "remove"] => match zid.parse::<u32>() {
                Ok(zone_id) => command_tx.send(AudioCommand::RemoveSamplerZone {
                    channel_id,
                    device_path,
                    zone_id,
                })?,
                Err(_) => warn!("Bad zone id in zone/{}/remove", zid),
            },
            ["zone_group", gid, "set"] => match (gid.parse::<u32>(), parse_zone_group_set(args)) {
                (Ok(group_id), Ok((gain, mute, solo, play_mode))) => {
                    command_tx.send(AudioCommand::SetSamplerZoneGroup {
                        channel_id,
                        device_path,
                        group_id,
                        gain,
                        mute,
                        solo,
                        play_mode,
                    })?
                }
                (group_id, group) => warn!(
                    "Bad zone_group/{}/set on channel {} path {}: {:?} {:?}",
                    gid,
                    channel_id,
                    device_path,
                    group_id.err(),
                    group.err()
                ),
            },
            ["zone_group", gid, "remove"] => match gid.parse::<u32>() {
                Ok(group_id) => command_tx.send(AudioCommand::RemoveSamplerZoneGroup {
                    channel_id,
                    device_path,
                    group_id,
                })?,
                Err(_) => warn!("Bad group id in zone_group/{}/remove", gid),
            },
            ["focus_zone"] => match args.first().and_then(osc_int) {
                Some(zone_id) => command_tx.send(AudioCommand::SetSamplerFocus {
                    channel_id,
                    device_path,
                    zone_id: zone_id.clamp(0, u32::MAX as i64) as u32,
                })?,
                None => warn!("focus_zone needs an int, got {:?}", args),
            },
            ["audition"] => match (
                args.first().and_then(osc_int),
                args.get(1).and_then(osc_int),
                args.get(2).and_then(osc_int),
            ) {
                (Some(note), Some(velocity), Some(on)) => {
                    command_tx.send(AudioCommand::AuditionDevice {
                        channel_id,
                        device_path,
                        note: note.clamp(0, 127) as u8,
                        velocity: velocity.clamp(0, 127) as u8,
                        is_note_on: on != 0,
                    })?
                }
                _ => warn!("audition needs note velocity on, got {:?}", args),
            },
            ["slot", slot_str, "volume"] => {
                if let (Ok(slot), Some(OscType::Float(volume))) =
                    (slot_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetLayerSlotVolume {
                        channel_id,
                        device_path,
                        slot,
                        volume: *volume,
                    })?;
                }
            }
            ["slot", slot_str, "mute"] => {
                if let (Ok(slot), Some(OscType::Int(mute))) =
                    (slot_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetLayerSlotMute {
                        channel_id,
                        device_path,
                        slot,
                        mute: *mute != 0,
                    })?;
                }
            }
            ["slot", slot_str, "solo"] => {
                if let (Ok(slot), Some(OscType::Int(solo))) =
                    (slot_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetLayerSlotSolo {
                        channel_id,
                        device_path,
                        slot,
                        solo: *solo != 0,
                    })?;
                }
            }
            ["slot", slot_str, "note_map"] => match (slot_str.parse::<usize>(), args.first()) {
                (Ok(slot), Some(OscType::Blob(bytes))) if bytes.len() == 128 => {
                    let mut map = Box::new([0u8; 128]);
                    map.copy_from_slice(bytes);
                    command_tx.send(AudioCommand::SetLayerSlotNoteMap {
                        channel_id,
                        device_path,
                        slot,
                        map,
                    })?;
                }
                _ => warn!(
                    "Layer note_map on channel {} path {} slot {} needs a 128-byte blob",
                    channel_id, device_path, slot_str
                ),
            },
            ["slot", slot_str, "separate_out"] => {
                if let (Ok(slot), Some(OscType::Int(separate))) =
                    (slot_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetLayerSlotSeparateOut {
                        channel_id,
                        device_path,
                        slot,
                        separate: *separate != 0,
                    })?;
                }
            }
            ["slot", slot_str, "audition"] => {
                if let (
                    Ok(slot),
                    Some(OscType::Int(note)),
                    Some(OscType::Int(velocity)),
                    Some(OscType::Int(on)),
                ) = (
                    slot_str.parse::<usize>(),
                    args.first(),
                    args.get(1),
                    args.get(2),
                ) {
                    command_tx.send(AudioCommand::AuditionLayerSlot {
                        channel_id,
                        device_path,
                        slot,
                        note: (*note).clamp(0, 127) as u8,
                        velocity: (*velocity).clamp(0, 127) as u8,
                        is_note_on: *on != 0,
                    })?;
                }
            }
            ["slot", slot_str, "note"] => {
                if let Ok(slot) = slot_str.parse::<usize>() {
                    let note = match args.first() {
                        Some(OscType::Int(n)) => Some(*n as u8),
                        Some(OscType::Float(n)) => Some(*n as u8),
                        _ => None,
                    };
                    if let Some(note) = note {
                        command_tx.send(AudioCommand::SetDrumSlotNote {
                            channel_id,
                            device_path,
                            slot,
                            note,
                        })?;
                    }
                }
            }
            ["slot", slot_str, "choke_targets"] => {
                match (slot_str.parse::<usize>(), args.first()) {
                    (Ok(slot), Some(OscType::Blob(bytes))) if bytes.len() == 16 => {
                        let mut le = [0u8; 16];
                        le.copy_from_slice(bytes);
                        command_tx.send(AudioCommand::SetDrumSlotChokeTargets {
                            channel_id,
                            device_path,
                            slot,
                            mask: u128::from_le_bytes(le),
                        })?;
                    }
                    _ => warn!(
                        "Drum choke_targets on channel {} path {} slot {} needs a 16-byte blob",
                        channel_id, device_path, slot_str
                    ),
                }
            }
            _ => {
                warn!(
                    "Unhandled device OSC action {:?} on channel {} path {}",
                    action, channel_id, device_path
                );
            }
        }
        Ok(())
    }

    /// Handle an individual OSC message
    fn handle_message(
        &self,
        msg: OscMessage,
        command_tx: &Sender<AudioCommand>,
        log_writers: &LogWriters,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        let addr = msg.addr.as_str();
        let args = &msg.args;

        // Split address into parts for path-based routing
        let parts: Vec<&str> = addr.split('/').filter(|s| !s.is_empty()).collect();

        if let Some((channel_id, device_path, action)) = parse_osc_device_addr(&parts) {
            return self.handle_device_message(
                channel_id,
                device_path,
                &action,
                args,
                command_tx,
                window_manager,
            );
        }

        // Route based on address pattern
        match parts.as_slice() {
            // Transport control
            ["transport", "play"] => {
                info!("Play");
                command_tx.send(AudioCommand::Play)?;
            }
            ["transport", "pause"] => {
                info!("Pause");
                command_tx.send(AudioCommand::Pause)?;
            }
            ["transport", "stop"] => {
                info!("Stop");
                command_tx.send(AudioCommand::Stop)?;
            }
            ["transport", "seek"] => {
                if let Some(OscType::Int(ticks)) = args.first() {
                    info!("Seek to tick {}", ticks);
                    command_tx.send(AudioCommand::Seek(*ticks as i64))?;
                }
            }
            ["transport", "tempo"] => {
                if let Some(OscType::Float(tempo)) = args.first() {
                    info!("Set tempo to {}", tempo);
                    command_tx.send(AudioCommand::SetTempo(*tempo))?;
                }
            }
            ["transport", "tempo_map"] => {
                let (points, dropped) = parse_tempo_map_args(args);
                if dropped {
                    warn!("/transport/tempo_map: ignoring malformed trailing argument");
                }
                command_tx.send(AudioCommand::SetTempoMap(points))?;
            }
            ["transport", "time_signature_map"] => {
                let (changes, dropped) = parse_time_signature_map_args(args);
                if dropped {
                    warn!(
                        "/transport/time_signature_map: dropped malformed or out-of-range entries"
                    );
                }
                command_tx.send(AudioCommand::SetTimeSignatureMap(changes))?;
            }
            ["transport", "time_signature"] => {
                if let (Some(OscType::Int(num)), Some(OscType::Int(den))) =
                    (args.get(0), args.get(1))
                {
                    info!("Set time signature to {}/{}", num, den);
                    command_tx.send(AudioCommand::SetTimeSignature(*num, *den))?;
                }
            }

            // Project setup
            ["project", "init"] => {
                if let (
                    Some(OscType::Float(tempo)),
                    Some(OscType::Int(num)),
                    Some(OscType::Int(den)),
                    Some(OscType::Int(ppq)),
                    Some(OscType::Int(sr)),
                ) = (
                    args.get(0),
                    args.get(1),
                    args.get(2),
                    args.get(3),
                    args.get(4),
                ) {
                    // Rotate log files before initializing new project
                    if let Err(e) = Self::rotate_log_files(log_writers) {
                        warn!("Failed to rotate log file: {}", e);
                    }

                    info!(
                        "Initialize project: {}bpm {}/{} PPQ={} SR={}",
                        tempo, num, den, ppq, sr
                    );
                    let settings = ProjectSettings {
                        tempo: *tempo,
                        time_numerator: *num,
                        time_denominator: *den,
                        ppq: *ppq,
                        sample_rate: *sr,
                    };
                    command_tx.send(AudioCommand::InitProject(settings))?;

                    // Send confirmation that engine is ready
                    match self.send_message("/status/connected", vec![OscType::Int(1)]) {
                        Ok(_) => info!("Sent /status/connected to Godot"),
                        Err(e) => warn!("Failed to send /status/connected: {}", e),
                    }
                } else {
                    warn!(
                        "/project/init ignored (expected f,i,i,i,i); args={:?}",
                        args
                    );
                }
            }
            ["project", "clear"] => {
                info!("Clear project");
                command_tx.send(AudioCommand::ClearProject)?;
            }

            // Channel management - path-based: /channel/{id}/{command}
            ["channel", id_str, "create"] => {
                if let (Ok(id), Some(OscType::String(name))) =
                    (id_str.parse::<usize>(), args.first())
                {
                    info!("Create channel {} ({})", id, name);
                    command_tx.send(AudioCommand::CreateChannel {
                        id,
                        name: name.clone(),
                    })?;
                }
            }
            ["channel", id_str, "remove"] => {
                if let Ok(id) = id_str.parse::<usize>() {
                    info!("Remove channel {}", id);
                    command_tx.send(AudioCommand::RemoveChannel { id })?;
                }
            }
            ["channel", id_str, "volume"] => {
                if let (Ok(id), Some(OscType::Float(db))) = (id_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetChannelVolume { id, db: *db })?;
                }
            }
            ["channel", id_str, "pan"] => {
                if let Ok(id) = id_str.parse::<usize>() {
                    // Check if we have 1 or 2 pan values
                    if let Some(OscType::Float(pan_left)) = args.get(0) {
                        let pan_right = args.get(1).and_then(|arg| {
                            if let OscType::Float(val) = arg {
                                Some(*val)
                            } else {
                                None
                            }
                        });
                        command_tx.send(AudioCommand::SetChannelPan {
                            id,
                            pan_left: *pan_left,
                            pan_right,
                        })?;
                    }
                }
            }
            ["channel", id_str, "pan_mode"] => {
                if let (Ok(id), Some(OscType::Int(mode))) = (id_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetChannelPanMode { id, mode: *mode })?;
                }
            }
            ["channel", id_str, "pan_width"] => {
                if let (Ok(id), Some(OscType::Float(width))) =
                    (id_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetChannelPanWidth { id, width: *width })?;
                }
            }
            ["channel", id_str, "mute"] => {
                if let (Ok(id), Some(OscType::Int(mute))) = (id_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetChannelMute {
                        id,
                        mute: *mute != 0,
                    })?;
                }
            }
            ["channel", id_str, "solo"] => {
                if let (Ok(id), Some(OscType::Int(solo))) = (id_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetChannelSolo {
                        id,
                        solo: *solo != 0,
                    })?;
                }
            }
            ["channel", id_str, "route"] => {
                if let (Ok(id), Some(OscType::Int(output_id))) =
                    (id_str.parse::<usize>(), args.first())
                {
                    let output = if *output_id < 0 {
                        None
                    } else {
                        Some(*output_id as usize)
                    };
                    command_tx.send(AudioCommand::SetChannelRoute {
                        id,
                        output_id: output,
                    })?;
                }
            }
            ["channel", id_str, "aux_out"] => {
                if let Ok(id) = id_str.parse::<usize>() {
                    let bus_index = args.first().and_then(|a| match a {
                        OscType::Int(v) if *v >= 0 => Some(*v as usize),
                        _ => None,
                    });
                    let target_id = args.get(1).and_then(|a| match a {
                        OscType::Int(v) if *v >= 0 => Some(*v as usize),
                        _ => None,
                    });
                    if let (Some(bus_index), Some(target_id)) = (bus_index, target_id) {
                        command_tx.send(AudioCommand::SetAuxOut {
                            id,
                            bus_index,
                            target_id,
                        })?;
                    }
                }
            }

            // MIDI routing configuration
            ["channel", id_str, "midi_input_device"] => {
                if let (Ok(id), Some(OscType::Int(device_id))) =
                    (id_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetMidiInputDevice {
                        channel_id: id,
                        device_id: *device_id,
                    })?;
                }
            }
            ["channel", id_str, "record_armed"] => {
                if let (Ok(id), Some(OscType::Int(armed))) = (id_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetRecordArmed {
                        channel_id: id,
                        armed: *armed != 0,
                    })?;
                }
            }

            // MIDI events - path-based: /channel/{id}/midi_event
            ["channel", id_str, "midi_event"] => {
                if let Ok(channel_id) = id_str.parse::<usize>() {
                    // Args: channel_id, message, midi_channel, pitch, velocity, timestamp_us
                    // Godot's timestamp is on a different clock, so the engine stamps arrival instead
                    let received_at = Instant::now();
                    if let (
                        Some(OscType::Int(_)), // channel_id (redundant, already in path)
                        Some(OscType::Int(message)),
                        Some(OscType::Int(midi_channel)),
                        Some(OscType::Int(pitch)),
                        Some(OscType::Int(velocity)),
                    ) = (
                        args.get(0),
                        args.get(1),
                        args.get(2),
                        args.get(3),
                        args.get(4),
                    ) {
                        command_tx.send(AudioCommand::MidiEvent {
                            channel_id,
                            message_type: *message as u8,
                            midi_channel: *midi_channel as u8,
                            note: *pitch as u8,
                            velocity: *velocity as u8,
                            received_at,
                        })?;
                    }
                }
            }
            ["channel", id_str, "midi_cc"] => {
                if let Ok(channel_id) = id_str.parse::<usize>() {
                    // Args: channel_id, midi_channel, cc_number, cc_value, timestamp_us
                    // Godot's timestamp is on a different clock, so the engine stamps arrival instead
                    let received_at = Instant::now();
                    if let (
                        Some(OscType::Int(_)), // channel_id (redundant)
                        Some(OscType::Int(midi_channel)),
                        Some(OscType::Int(cc_number)),
                        Some(OscType::Int(cc_value)),
                    ) = (args.get(0), args.get(1), args.get(2), args.get(3))
                    {
                        command_tx.send(AudioCommand::MidiEvent {
                            channel_id,
                            message_type: 11, // MIDI_MESSAGE_CONTROL_CHANGE
                            midi_channel: *midi_channel as u8,
                            note: *cc_number as u8,
                            velocity: *cc_value as u8,
                            received_at,
                        })?;
                    }
                }
            }

            // Send management - path-based: /channel/{id}/send/{target_id}/{command}
            ["channel", id_str, "send", target_str, "add"] => {
                if let (Ok(channel_id), Ok(target_channel_id)) =
                    (id_str.parse::<usize>(), target_str.parse::<usize>())
                {
                    // Args: amount_db (float), pre_fader (int 0/1)
                    let amount_db = args
                        .get(0)
                        .and_then(|v| match v {
                            OscType::Float(f) => Some(*f),
                            OscType::Int(i) => Some(*i as f32),
                            _ => None,
                        })
                        .unwrap_or(-12.0); // Default -12 dB

                    let pre_fader = args
                        .get(1)
                        .and_then(|v| match v {
                            OscType::Int(i) => Some(*i != 0),
                            _ => None,
                        })
                        .unwrap_or(false); // Default post-fader

                    command_tx.send(AudioCommand::AddSend {
                        channel_id,
                        target_channel_id,
                        amount_db,
                        pre_fader,
                    })?;
                }
            }
            ["channel", id_str, "send", target_str, "remove"] => {
                if let (Ok(channel_id), Ok(target_channel_id)) =
                    (id_str.parse::<usize>(), target_str.parse::<usize>())
                {
                    command_tx.send(AudioCommand::RemoveSend {
                        channel_id,
                        target_channel_id,
                    })?;
                }
            }
            ["channel", id_str, "send", target_str, "amount"] => {
                if let (Ok(channel_id), Ok(target_channel_id)) =
                    (id_str.parse::<usize>(), target_str.parse::<usize>())
                {
                    if let Some(amount_db) = args.get(0).and_then(|v| match v {
                        OscType::Float(f) => Some(*f),
                        OscType::Int(i) => Some(*i as f32),
                        _ => None,
                    }) {
                        command_tx.send(AudioCommand::SetSendAmount {
                            channel_id,
                            target_channel_id,
                            amount_db,
                        })?;
                    }
                }
            }
            ["channel", id_str, "send", target_str, "pre_fader"] => {
                if let (Ok(channel_id), Ok(target_channel_id)) =
                    (id_str.parse::<usize>(), target_str.parse::<usize>())
                {
                    if let Some(OscType::Int(pre_fader)) = args.first() {
                        command_tx.send(AudioCommand::SetSendPreFader {
                            channel_id,
                            target_channel_id,
                            pre_fader: *pre_fader != 0,
                        })?;
                    }
                }
            }
            ["channel", id_str, "send", target_str, "mute"] => {
                if let (Ok(channel_id), Ok(target_channel_id)) =
                    (id_str.parse::<usize>(), target_str.parse::<usize>())
                {
                    if let Some(OscType::Int(muted)) = args.first() {
                        command_tx.send(AudioCommand::SetSendMute {
                            channel_id,
                            target_channel_id,
                            muted: *muted != 0,
                        })?;
                    }
                }
            }

            // Track management - path-based: /track/{id}/{command}
            ["track", id_str, "create"] => {
                if let (Ok(id), Some(OscType::Int(channel_id))) =
                    (id_str.parse::<usize>(), args.first())
                {
                    info!("Create track {} -> channel {}", id, channel_id);
                    command_tx.send(AudioCommand::CreateTrack {
                        id,
                        channel_id: *channel_id as usize,
                    })?;
                }
            }
            ["track", id_str, "route"] => {
                if let (Ok(id), Some(OscType::Int(channel_id))) =
                    (id_str.parse::<usize>(), args.first())
                {
                    info!("Route track {} to channel {}", id, channel_id);
                    command_tx.send(AudioCommand::SetTrackRoute {
                        id,
                        channel_id: *channel_id as usize,
                    })?;
                }
            }

            // Automation - path-based: /track/{id}/automation/...
            ["track", id_str, "automation", "create"] => {
                if let (
                    Ok(track_id),
                    Some(OscType::String(lane_id)),
                    Some(OscType::String(target)),
                ) = (id_str.parse::<usize>(), args.get(0), args.get(1))
                {
                    match AutomationTarget::parse(target) {
                        Some(target) => {
                            info!(
                                "Create automation lane {} on track {} targeting {}",
                                lane_id, track_id, target
                            );
                            command_tx.send(AudioCommand::CreateAutomationLane {
                                track_id,
                                lane_id: lane_id.clone(),
                                target,
                            })?;
                        }
                        None => {
                            warn!(
                                "Unparseable automation target '{}' for lane {} on track {} - ignoring",
                                target, lane_id, track_id
                            );
                        }
                    }
                }
            }
            ["track", id_str, "automation", lane_id, "delete"] => {
                if let Ok(track_id) = id_str.parse::<usize>() {
                    info!("Delete automation lane {} on track {}", lane_id, track_id);
                    command_tx.send(AudioCommand::DeleteAutomationLane {
                        track_id,
                        lane_id: lane_id.to_string(),
                    })?;
                }
            }
            ["track", id_str, "automation", lane_id, "bypass"] => {
                if let (Ok(track_id), Some(OscType::Int(bypassed))) =
                    (id_str.parse::<usize>(), args.first())
                {
                    info!(
                        "Set automation lane {} on track {} bypass={}",
                        lane_id, track_id, bypassed
                    );
                    command_tx.send(AudioCommand::SetAutomationLaneBypass {
                        track_id,
                        lane_id: lane_id.to_string(),
                        bypassed: *bypassed != 0,
                    })?;
                }
            }
            ["track", id_str, "automation", lane_id, "add_point"] => {
                if let (Ok(track_id), Some(point)) =
                    (id_str.parse::<usize>(), parse_automation_point(args))
                {
                    info!(
                        "Add automation point {} to lane {} on track {}: tick={} value={}",
                        point.id, lane_id, track_id, point.tick, point.value
                    );
                    command_tx.send(AudioCommand::AddAutomationPoint {
                        track_id,
                        lane_id: lane_id.to_string(),
                        point,
                    })?;
                }
            }
            ["track", id_str, "automation", lane_id, "update_point"] => {
                if let (Ok(track_id), Some(point)) =
                    (id_str.parse::<usize>(), parse_automation_point(args))
                {
                    info!(
                        "Update automation point {} in lane {} on track {}: tick={} value={}",
                        point.id, lane_id, track_id, point.tick, point.value
                    );
                    command_tx.send(AudioCommand::UpdateAutomationPoint {
                        track_id,
                        lane_id: lane_id.to_string(),
                        point,
                    })?;
                }
            }
            ["track", id_str, "automation", lane_id, "remove_point"] => {
                if let (Ok(track_id), Some(OscType::Int(point_id))) =
                    (id_str.parse::<usize>(), args.first())
                {
                    info!(
                        "Remove automation point {} from lane {} on track {}",
                        point_id, lane_id, track_id
                    );
                    command_tx.send(AudioCommand::RemoveAutomationPoint {
                        track_id,
                        lane_id: lane_id.to_string(),
                        point_id: *point_id as AutomationPointId,
                    })?;
                }
            }
            ["track", id_str, "automation", lane_id, "clear"] => {
                if let Ok(track_id) = id_str.parse::<usize>() {
                    info!("Clear automation lane {} on track {}", lane_id, track_id);
                    command_tx.send(AudioCommand::ClearAutomationLane {
                        track_id,
                        lane_id: lane_id.to_string(),
                    })?;
                }
            }

            // Clip management - path-based: /clip/{id}/{command}
            ["clip", "create"] => {
                if let (
                    Some(OscType::String(id)),
                    Some(OscType::String(clip_type)),
                    Some(OscType::String(name)),
                ) = (args.get(0), args.get(1), args.get(2))
                {
                    info!("Create clip {} ({}) - {}", id, clip_type, name);
                    command_tx.send(AudioCommand::CreateClip {
                        id: id.clone(),
                        name: name.clone(),
                        clip_type: clip_type.clone(),
                    })?;
                }
            }
            ["clip", "delete"] => {
                if let Some(OscType::String(id)) = args.first() {
                    info!("Delete clip {}", id);
                    command_tx.send(AudioCommand::RemoveClip { id: id.clone() })?;
                }
            }
            ["clip", id_str, "add_note"] => {
                if let Some(n) = parse_clip_note_args(addr, args) {
                    info!(
                        "Add note to clip {}: note_id {} note {} at tick {} duration {} vel {} rel {}",
                        id_str, n.note_id, n.note, n.start_tick, n.duration_ticks, n.velocity, n.release
                    );
                    command_tx.send(AudioCommand::AddNoteToClip {
                        clip_id: id_str.to_string(),
                        note_id: n.note_id,
                        note: n.note,
                        start_tick: n.start_tick,
                        duration_ticks: n.duration_ticks,
                        velocity: n.velocity,
                        release: n.release,
                    })?;
                }
            }
            ["clip", id_str, "remove_note"] => {
                if let Some(OscType::Int(note_id)) = args.first() {
                    info!("Remove note from clip {}: note_id {}", id_str, note_id);
                    command_tx.send(AudioCommand::RemoveNoteFromClip {
                        clip_id: id_str.to_string(),
                        note_id: *note_id as u64,
                    })?;
                }
            }
            ["clip", id_str, "update_note"] => {
                if let Some(n) = parse_clip_note_args(addr, args) {
                    info!(
                        "Update note in clip {}: note_id {} note {} at tick {} duration {} vel {} rel {}",
                        id_str, n.note_id, n.note, n.start_tick, n.duration_ticks, n.velocity, n.release
                    );
                    command_tx.send(AudioCommand::UpdateClipNote {
                        clip_id: id_str.to_string(),
                        note_id: n.note_id,
                        note: n.note,
                        start_tick: n.start_tick,
                        duration_ticks: n.duration_ticks,
                        velocity: n.velocity,
                        release: n.release,
                    })?;
                }
            }
            ["clip", id_str, "load_audio_file"] => {
                if let (
                    Some(OscType::String(file_path)),
                    Some(OscType::Int(sample_rate)),
                    Some(OscType::Int(channels)),
                ) = (args.get(0), args.get(1), args.get(2))
                {
                    let req_id = Self::generate_clip_request_id(id_str);
                    info!(
                        "Requesting audio load for clip {} (req_id={}) from {}",
                        id_str, req_id, file_path
                    );

                    {
                        let mut pending_guard = self.pending_clip_loads.lock().unwrap();
                        pending_guard.insert(
                            req_id.clone(),
                            PendingClip {
                                clip_id: id_str.to_string(),
                                source_path: file_path.clone(),
                            },
                        );
                    }

                    command_tx.send(AudioCommand::BeginLoadAudioClip {
                        clip_id: id_str.to_string(),
                        req_id: req_id.clone(),
                        source_path: file_path.clone(),
                    })?;

                    match self.audio_file_service.lock() {
                        Ok(service) => {
                            if let Err(err) = service
                                .submit_decode_and_waveform(req_id.clone(), file_path.clone())
                            {
                                warn!(
                                    "Failed to submit decode request for clip {} (req_id={}): {}",
                                    id_str, req_id, err
                                );
                                {
                                    let mut pending_guard = self.pending_clip_loads.lock().unwrap();
                                    pending_guard.remove(&req_id);
                                }
                                let _ = command_tx.send(AudioCommand::FailAudioClipLoad {
                                    clip_id: id_str.to_string(),
                                    req_id: req_id.clone(),
                                    message: err.to_string(),
                                });
                            }
                        }
                        Err(err) => {
                            warn!(
                                "Failed to lock AudioFileService for clip {} (req_id={}): {}",
                                id_str, req_id, err
                            );
                            {
                                let mut pending_guard = self.pending_clip_loads.lock().unwrap();
                                pending_guard.remove(&req_id);
                            }
                            let _ = command_tx.send(AudioCommand::FailAudioClipLoad {
                                clip_id: id_str.to_string(),
                                req_id: req_id.clone(),
                                message: "AudioFileService unavailable".to_string(),
                            });
                        }
                    }
                } else {
                    warn!(
                        "OSC: load_audio_file missing arguments: got {} args",
                        args.len()
                    );
                }
            }

            // ClipInstance management - path-based: /track/{track_id}/instance/{command}
            ["track", track_id_str, "add_instance"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let (
                        Some(OscType::String(instance_id)),
                        Some(OscType::String(clip_id)),
                        Some(OscType::Int(start_tick)),
                        Some(OscType::Int(duration)),
                    ) = (args.get(0), args.get(1), args.get(2), args.get(3))
                    {
                        info!(
                            "Add clip instance {} to track {}: clip {} at tick {} duration {}",
                            instance_id, track_id, clip_id, start_tick, duration
                        );
                        command_tx.send(AudioCommand::CreateClipInstance {
                            track_id,
                            instance_id: instance_id.clone(),
                            clip_id: clip_id.clone(),
                            start_tick: *start_tick as i64,
                            duration_ticks: *duration as i64,
                        })?;
                    }
                }
            }
            ["track", track_id_str, "remove_instance"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let Some(OscType::String(instance_id)) = args.first() {
                        info!(
                            "Remove clip instance {} from track {}",
                            instance_id, track_id
                        );
                        command_tx.send(AudioCommand::RemoveClipInstance {
                            track_id,
                            instance_id: instance_id.clone(),
                        })?;
                    }
                }
            }
            ["track", track_id_str, "instance", instance_id_str, "set_position"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let (
                        Some(OscType::Int(start_tick)),
                        Some(OscType::Int(duration)),
                        Some(OscType::Int(clip_offset)),
                    ) = (args.get(0), args.get(1), args.get(2))
                    {
                        info!(
                            "Set instance {} position: start {} duration {} offset {}",
                            instance_id_str, start_tick, duration, clip_offset
                        );
                        command_tx.send(AudioCommand::UpdateClipInstancePosition {
                            track_id,
                            instance_id: instance_id_str.to_string(),
                            start_tick: *start_tick as i64,
                            duration_ticks: *duration as i64,
                            clip_offset: *clip_offset as i64,
                        })?;
                    }
                }
            }
            ["track", track_id_str, "instance", instance_id_str, "set_transpose"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let Some(OscType::Int(semitones)) = args.first() {
                        info!(
                            "Set instance {} transpose: {} semitones",
                            instance_id_str, semitones
                        );
                        command_tx.send(AudioCommand::UpdateClipInstanceTranspose {
                            track_id,
                            instance_id: instance_id_str.to_string(),
                            transpose: *semitones as i8,
                        })?;
                    }
                }
            }
            ["track", track_id_str, "instance", instance_id_str, "set_gain"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let Some(OscType::Float(db)) = args.first() {
                        info!("Set instance {} gain: {} dB", instance_id_str, db);
                        command_tx.send(AudioCommand::UpdateClipInstanceGain {
                            track_id,
                            instance_id: instance_id_str.to_string(),
                            gain_db: *db,
                        })?;
                    }
                }
            }
            ["track", track_id_str, "instance", instance_id_str, "set_mute"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let Some(OscType::Int(muted)) = args.first() {
                        info!("Set instance {} mute: {}", instance_id_str, muted);
                        command_tx.send(AudioCommand::UpdateClipInstanceMute {
                            track_id,
                            instance_id: instance_id_str.to_string(),
                            muted: *muted != 0,
                        })?;
                    }
                }
            }
            ["track", track_id_str, "instance", instance_id_str, "set_loop"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let (
                        Some(OscType::Int(enabled)),
                        Some(OscType::Int(start_tick)),
                        Some(OscType::Int(length)),
                    ) = (args.get(0), args.get(1), args.get(2))
                    {
                        info!(
                            "Set instance {} loop: enabled={} start={} length={}",
                            instance_id_str, enabled, start_tick, length
                        );
                        command_tx.send(AudioCommand::UpdateClipInstanceLoop {
                            track_id,
                            instance_id: instance_id_str.to_string(),
                            enabled: *enabled != 0,
                            start_tick: *start_tick as i64,
                            length_ticks: *length as i64,
                        })?;
                    }
                }
            }
            ["track", track_id_str, "instance", instance_id_str, "set_reverse"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let Some(OscType::Int(reverse)) = args.first() {
                        info!("Set instance {} reverse: {}", instance_id_str, reverse);
                        command_tx.send(AudioCommand::UpdateClipInstanceReverse {
                            track_id,
                            instance_id: instance_id_str.to_string(),
                            reverse: *reverse != 0,
                        })?;
                    }
                }
            }

            // Device management - path-based: /channel/{id}/add_device
            ["channel", channel_id_str, "add_device"] => {
                if let (
                    Ok(channel_id),
                    Some(OscType::String(device_id)),
                    Some(OscType::Int(position)),
                ) = (channel_id_str.parse::<usize>(), args.get(0), args.get(1))
                {
                    // Optional active and enabled parameters (default to true if not provided)
                    let active = args
                        .get(2)
                        .and_then(|arg| {
                            if let OscType::Int(v) = arg {
                                Some(*v != 0)
                            } else {
                                None
                            }
                        })
                        .unwrap_or(true);
                    let enabled = args
                        .get(3)
                        .and_then(|arg| {
                            if let OscType::Int(v) = arg {
                                Some(*v != 0)
                            } else {
                                None
                            }
                        })
                        .unwrap_or(true);
                    // Device type parameter (builtin, clap, lv2, vst3)
                    let device_type = args
                        .get(4)
                        .and_then(|arg| {
                            if let OscType::String(t) = arg {
                                Some(t.clone())
                            } else {
                                None
                            }
                        })
                        .unwrap_or_else(|| "builtin".to_string());
                    // Device file parameter (path to plugin, empty for built-ins)
                    let device_file = args
                        .get(5)
                        .and_then(|arg| {
                            if let OscType::String(f) = arg {
                                Some(f.clone())
                            } else {
                                None
                            }
                        })
                        .unwrap_or_default();

                    info!("Add device {} (type={}) to channel {} at position {} [active={}, enabled={}]", 
                        device_id, device_type, channel_id, position, active, enabled);
                    command_tx.send(AudioCommand::AddDeviceToChannel {
                        channel_id,
                        parent_path: DevicePath::default(),
                        device_id: device_id.clone(),
                        device_type,
                        device_file,
                        position: *position,
                        active,
                        enabled,
                    })?;
                }
            }
            ["channel", channel_id_str, "remove_device"] => {
                if let (Ok(channel_id), Some(OscType::Int(position))) =
                    (channel_id_str.parse::<usize>(), args.first())
                {
                    info!(
                        "Remove device from channel {} at position {}",
                        channel_id, position
                    );
                    command_tx.send(AudioCommand::RemoveDeviceFromChannel {
                        channel_id,
                        parent_path: DevicePath::default(),
                        position: *position as usize,
                    })?;
                }
            }
            ["channel", channel_id_str, "move_device"] => {
                if let (Ok(channel_id), Some(OscType::Int(from_pos)), Some(OscType::Int(to_pos))) =
                    (channel_id_str.parse::<usize>(), args.get(0), args.get(1))
                {
                    info!(
                        "Move device in channel {} from position {} to position {}",
                        channel_id, from_pos, to_pos
                    );
                    command_tx.send(AudioCommand::MoveDevice {
                        channel_id,
                        parent_path: DevicePath::default(),
                        from_position: *from_pos as usize,
                        to_position: *to_pos as usize,
                    })?;
                }
            }
            ["channel", channel_id_str, "clear_devices"] => {
                if let Ok(channel_id) = channel_id_str.parse::<usize>() {
                    info!("Clear all devices from channel {}", channel_id);
                    command_tx.send(AudioCommand::ClearChannelDevices { channel_id })?;
                }
            }
            // Plugin management - path-based: /plugin/{command}
            // /plugin/scan [path:String]* — with no args, the engine uses its built-in
            // default search paths (and CLAP_PATH, if set).
            ["plugin", "scan"] => {
                let paths: Vec<PathBuf> = args
                    .iter()
                    .filter_map(|a| match a {
                        OscType::String(s) => Some(PathBuf::from(s)),
                        _ => None,
                    })
                    .collect();
                info!("Scan plugins: {} configured path(s)", paths.len());
                command_tx.send(AudioCommand::ScanPlugins { paths })?;
            }
            // /plugins/hosting <mode:s> [plugin_id:s mode:s]* — how plugins are grouped into
            // host processes, plus per-plugin overrides (Phase 5).
            ["plugins", "hosting"] => match parse_hosting_policy(args) {
                Ok(policy) => {
                    info!(
                        "Plugin hosting: {} ({} override(s))",
                        policy.mode.name(),
                        policy.overrides.len()
                    );
                    command_tx.send(AudioCommand::SetPluginHosting { policy })?;
                }
                Err(e) => warn!("Ignoring /plugins/hosting: {}", e),
            },
            ["builtin", "request"] => {
                info!("Request builtin devices");
                command_tx.send(AudioCommand::AdvertiseBuiltinDevices)?;
            }
            // Audio device settings (Phase 7)
            ["audio", "devices", "request"] => {
                command_tx.send(AudioCommand::RequestAudioDevices)?;
            }
            ["audio", "config", "request"] => {
                command_tx.send(AudioCommand::RequestAudioConfig)?;
            }
            // /audio/config/set <device:s> <rate:i> <buffer:i> — device "" is the default.
            ["render", "start"] => match parse_render_start(args) {
                Ok(job) => command_tx.send(AudioCommand::StartRender(job))?,
                Err(e) => {
                    warn!("Rejecting /render/start: {}", e);
                    let job_id = match args.first() {
                        Some(OscType::String(id)) => id.clone(),
                        _ => String::new(),
                    };
                    Self::send_status_update(
                        &self.socket,
                        self.client_port,
                        EngineStatus::RenderFailed {
                            job_id,
                            error: format!("invalid /render/start: {}", e),
                        },
                    );
                }
            },
            ["render", "analyze"] => match parse_render_analyze(args) {
                Ok(job) => command_tx.send(AudioCommand::StartRender(job))?,
                Err(e) => {
                    warn!("Rejecting /render/analyze: {}", e);
                    let job_id = match args.first() {
                        Some(OscType::String(id)) => id.clone(),
                        _ => String::new(),
                    };
                    Self::send_status_update(
                        &self.socket,
                        self.client_port,
                        EngineStatus::RenderFailed {
                            job_id,
                            error: format!("invalid /render/analyze: {}", e),
                        },
                    );
                }
            },
            ["render", "cancel"] => match args.first() {
                Some(OscType::String(job_id)) => command_tx.send(AudioCommand::CancelRender {
                    job_id: job_id.clone(),
                })?,
                _ => warn!("Ignoring /render/cancel without a job id"),
            },
            ["audio", "config", "set"] => match parse_audio_config(args) {
                Ok(command) => command_tx.send(command)?,
                Err(e) => warn!("Ignoring /audio/config/set: {}", e),
            },
            ["plugin", "get_parameters"] => {
                if let (Some(OscType::Int(channel_id)), Some(OscType::Int(device_position))) =
                    (args.get(0), args.get(1))
                {
                    info!(
                        "Get plugin parameters: channel={} device={}",
                        channel_id, device_position
                    );
                    command_tx.send(AudioCommand::GetPluginParameters {
                        channel_id: *channel_id as usize,
                        device_path: DevicePath::root(*device_position as usize),
                    })?;
                }
            }
            // AudioFile service routes
            ["audiofile", "decode"] => {
                if let (Some(OscType::String(req_id)), Some(OscType::String(abs_path))) =
                    (args.get(0), args.get(1))
                {
                    info!("AudioFile decode request: {} for {}", req_id, abs_path);
                    if let Ok(mut afs) = self.audio_file_service.lock() {
                        let _ = afs.submit_decode_and_waveform(req_id.clone(), abs_path.clone());
                    }
                }
            }
            ["audiofile", "waveform", "start"] => {
                if let (Some(OscType::String(req_id)), Some(OscType::String(abs_path))) =
                    (args.get(0), args.get(1))
                {
                    info!("AudioFile waveform request: {} for {}", req_id, abs_path);
                    if let Ok(mut afs) = self.audio_file_service.lock() {
                        let _ = afs.submit_decode_and_waveform(req_id.clone(), abs_path.clone());
                    }
                }
            }
            ["audiofile", "samples"] => {
                // s:req_id s:cache_key i:channel i|h:start_frame i:count
                let as_u64 = |a: Option<&OscType>| match a {
                    Some(OscType::Int(v)) if *v >= 0 => Some(*v as u64),
                    Some(OscType::Long(v)) if *v >= 0 => Some(*v as u64),
                    _ => None,
                };
                if let (
                    Some(OscType::String(req_id)),
                    Some(OscType::String(cache_key)),
                    Some(channel),
                    Some(start_frame),
                    Some(count),
                ) = (
                    args.get(0),
                    args.get(1),
                    as_u64(args.get(2)),
                    as_u64(args.get(3)),
                    as_u64(args.get(4)),
                ) {
                    debug!(
                        request_id = %req_id,
                        cache_key = %cache_key,
                        channel,
                        start_frame,
                        count,
                        "AudioFile samples request"
                    );
                    if let Ok(afs) = self.audio_file_service.lock() {
                        let _ = afs.request_samples(
                            req_id.clone(),
                            cache_key.clone(),
                            channel as u16,
                            start_frame,
                            count as usize,
                        );
                    }
                } else {
                    warn!("/audiofile/samples: bad arguments {:?}", args);
                }
            }
            ["audiofile", "waveform", "cancel"] => {
                if let Some(OscType::String(req_id)) = args.first() {
                    info!("AudioFile cancel request: {}", req_id);
                    if let Ok(mut afs) = self.audio_file_service.lock() {
                        let _ = afs.cancel_job(req_id.clone());
                    }
                }
            }

            _ => {
                warn!("Unknown OSC address: {}", addr);
            }
        }

        Ok(())
    }

    /// Send a status update to the client
    fn send_status_update(socket: &UdpSocket, client_port: u16, status: EngineStatus) {
        let is_param_change = status.is_param_change();
        let (addr, args) = match status {
            EngineStatus::PlayheadUpdate(ticks) => (
                "/status/playhead".to_string(),
                vec![OscType::Int(ticks as i32)],
            ),
            EngineStatus::PlayingStateChanged(playing) => (
                "/status/playing".to_string(),
                vec![OscType::Int(if playing { 1 } else { 0 })],
            ),
            EngineStatus::RenderProgress { job_id, fraction } => (
                "/render/progress".to_string(),
                vec![OscType::String(job_id), OscType::Float(fraction)],
            ),
            EngineStatus::RenderDone { job_id, outputs } => {
                let mut args = vec![OscType::String(job_id)];
                args.extend(
                    outputs
                        .into_iter()
                        .map(|path| OscType::String(path.to_string_lossy().into_owned())),
                );
                ("/render/done".to_string(), args)
            }
            EngineStatus::RenderFailed { job_id, error } => (
                "/render/failed".to_string(),
                vec![OscType::String(job_id), OscType::String(error)],
            ),
            EngineStatus::ChannelPeaks {
                id,
                peak_left,
                peak_right,
                rms_left,
                rms_right,
            } => {
                // New path-based format: /channel/{id}/peak [peak_left, peak_right, rms_left, rms_right]
                (
                    format!("/channel/{}/peak", id),
                    vec![
                        OscType::Float(peak_left),
                        OscType::Float(peak_right),
                        OscType::Float(rms_left),
                        OscType::Float(rms_right),
                    ],
                )
            }
            EngineStatus::ClipLoadStateChanged {
                clip_id,
                state,
                source_path,
                cache_key,
                sample_rate,
                channels,
            } => {
                let (state_label, req_id, message) = match state {
                    ClipLoadState::Unloaded => {
                        ("unloaded".to_string(), String::new(), String::new())
                    }
                    ClipLoadState::Loading { req_id } => {
                        ("loading".to_string(), req_id, String::new())
                    }
                    ClipLoadState::Ready { req_id } => ("ready".to_string(), req_id, String::new()),
                    ClipLoadState::Failed { req_id, message } => {
                        ("failed".to_string(), req_id.unwrap_or_default(), message)
                    }
                };

                (
                    format!("/clip/{}/load_state", clip_id),
                    vec![
                        OscType::String(state_label),
                        OscType::String(req_id),
                        OscType::String(source_path.unwrap_or_default()),
                        OscType::String(cache_key.unwrap_or_default()),
                        OscType::Int(sample_rate.unwrap_or(0) as i32),
                        OscType::Int(channels.unwrap_or(0) as i32),
                        OscType::String(message),
                    ],
                )
            }
            EngineStatus::DeviceActiveChanged {
                channel_id,
                device_path,
                active,
            } => (
                device_path.to_osc_addr(channel_id, "active"),
                vec![OscType::Int(if active { 1 } else { 0 })],
            ),
            EngineStatus::DeviceEnabledChanged {
                channel_id,
                device_path,
                enabled,
            } => (
                device_path.to_osc_addr(channel_id, "enabled"),
                vec![OscType::Int(if enabled { 1 } else { 0 })],
            ),
            EngineStatus::DeviceReady { .. } => {
                // DeviceReady is handled internally (triggers parameter re-send)
                // No need to send it to Godot
                return;
            }
            EngineStatus::DeviceLoadingStateChanged {
                channel_id,
                device_path,
                state,
            } => (
                device_path.to_osc_addr(channel_id, "loading_state"),
                vec![OscType::String(state)],
            ),
            EngineStatus::SamplerZoneLoadingState {
                channel_id,
                device_path,
                zone_id,
                state,
            } => (
                device_path.to_osc_addr(channel_id, &format!("zone/{zone_id}/loading_state")),
                vec![OscType::String(state)],
            ),
            EngineStatus::DeviceCrashed {
                channel_id,
                device_path,
                reason,
                stderr,
                pid,
                log_path,
            } => (
                device_path.to_osc_addr(channel_id, "crashed"),
                vec![
                    OscType::String(reason),
                    OscType::String(stderr),
                    OscType::Int(pid as i32),
                    OscType::String(log_path),
                ],
            ),
            EngineStatus::PluginStats {
                channel_id,
                device_path,
                load_avg,
                load_peak,
                process_avg_us,
                process_max_us,
                blocks,
                deadline_misses,
                total_misses,
                struggling,
            } => (
                device_path.to_osc_addr(channel_id, "stats"),
                vec![
                    OscType::Float(load_avg),
                    OscType::Float(load_peak),
                    OscType::Float(process_avg_us),
                    OscType::Float(process_max_us),
                    OscType::Int(osc_count(blocks)),
                    OscType::Int(osc_count(deadline_misses)),
                    OscType::Int(osc_count(total_misses)),
                    OscType::Int(struggling as i32),
                ],
            ),
            EngineStatus::PluginHost {
                channel_id,
                device_path,
                mode,
                host_key,
                pid,
            } => (
                device_path.to_osc_addr(channel_id, "host"),
                vec![
                    OscType::String(mode),
                    OscType::String(host_key),
                    OscType::Int(pid as i32),
                ],
            ),
            EngineStatus::PluginGuiOpened {
                channel_id,
                device_path,
                width,
                height,
                resizable,
                floating,
            } => (
                device_path.to_osc_addr(channel_id, "gui/opened"),
                vec![
                    OscType::Int(width as i32),
                    OscType::Int(height as i32),
                    OscType::Int(resizable as i32),
                    OscType::Int(floating as i32),
                ],
            ),
            // The main loop also resizes a floating host window; Godot needs the size to lay out
            // an embedded GUI.
            EngineStatus::PluginGuiResizeRequest {
                channel_id,
                device_path,
                width,
                height,
            } => (
                device_path.to_osc_addr(channel_id, "gui/size"),
                vec![OscType::Int(width as i32), OscType::Int(height as i32)],
            ),
            EngineStatus::PluginGuiClosed {
                channel_id,
                device_path,
            } => (device_path.to_osc_addr(channel_id, "gui/closed"), vec![]),
            EngineStatus::PluginScanComplete { count } => (
                "/plugin/scan_complete".to_string(),
                vec![OscType::Int(count as i32)],
            ),
            EngineStatus::PluginInfo {
                id,
                name,
                vendor,
                version,
                category,
                description,
                path,
                features,
            } => {
                tracing::info!("📨 Sending plugin info: {} ({})", name, id);
                let mut args = vec![
                    OscType::String(id.clone()),
                    OscType::String(name),
                    OscType::String(vendor),
                    OscType::String(version),
                    OscType::String(category),
                ];
                // Add description if present, otherwise send empty string
                args.push(OscType::String(description.unwrap_or_default()));
                // Add path
                args.push(OscType::String(path));
                // Add feature tags, joined with commas
                args.push(OscType::String(features.join(",")));
                ("/plugin/info".to_string(), args)
            }
            EngineStatus::BuiltinDeviceInfo {
                id,
                name,
                category,
                description,
                accepts_midi,
                audio_in_channels,
                audio_out_channels,
                supports_file_loading,
                file_extensions,
                file_type_description,
                is_container,
                parameters,
                default_modulators,
            } => {
                tracing::info!("📨 Sending builtin device info: {} ({})", name, id);

                // Send device basic info
                let mut args = vec![
                    OscType::String(id.clone()),
                    OscType::String(name),
                    OscType::String(category),
                    OscType::String(description),
                    OscType::Int(if accepts_midi { 1 } else { 0 }),
                    OscType::Int(audio_in_channels as i32),
                    OscType::Int(audio_out_channels as i32),
                    OscType::Int(if supports_file_loading { 1 } else { 0 }),
                    OscType::String(file_type_description),
                    OscType::Int(file_extensions.len() as i32),
                ];

                for ext in file_extensions {
                    args.push(OscType::String(ext));
                }

                args.push(OscType::Int(parameters.len() as i32));

                // Add all parameters inline (id, name, unit, type, syncable, min, max, default,
                // is_log, skew, enum_count, enum_values..., module, automatable, modulatable)
                for param in &parameters {
                    push_param_args(&mut args, param);
                }

                args.push(OscType::Int(if is_container { 1 } else { 0 }));

                // Default modulators: count, then (kind, name, params, routes) each.
                args.push(OscType::Int(default_modulators.len() as i32));
                for modulator in &default_modulators {
                    args.push(OscType::String(modulator.kind.id().to_string()));
                    args.push(OscType::String(modulator.name.clone()));
                    args.push(OscType::Int(modulator.params.len() as i32));
                    for (param_id, value) in &modulator.params {
                        args.push(OscType::Int(*param_id as i32));
                        args.push(OscType::Float(*value));
                    }
                    args.push(OscType::Int(modulator.routes.len() as i32));
                    for (target, amount) in &modulator.routes {
                        args.push(OscType::String(target.clone()));
                        args.push(OscType::Float(*amount));
                    }
                }

                ("/builtin/info".to_string(), args)
            }
            EngineStatus::BuiltinDevicesComplete { count } => (
                "/builtin/complete".to_string(),
                vec![OscType::Int(count as i32)],
            ),
            EngineStatus::AudioDeviceInfo(device) => {
                let mut args = vec![
                    OscType::String(device.name),
                    OscType::Int(device.is_default as i32),
                    OscType::Int(device.min_period as i32),
                    OscType::Int(device.max_period as i32),
                    OscType::Int(device.channels as i32),
                ];
                args.extend(
                    device
                        .sample_rates
                        .iter()
                        .map(|&rate| OscType::Int(rate as i32)),
                );
                ("/audio/device".to_string(), args)
            }
            EngineStatus::AudioDevicesComplete { count } => (
                "/audio/devices/complete".to_string(),
                vec![OscType::Int(count as i32)],
            ),
            EngineStatus::AudioConfig(report) => {
                ("/audio/config".to_string(), audio_config_args(report))
            }
            EngineStatus::AudioConfigChanged { sample_rate } => (
                "/audio/config/changed".to_string(),
                vec![OscType::Int(sample_rate as i32)],
            ),
            EngineStatus::PluginParameterInfo {
                channel_id,
                device_path,
                param_id,
                name,
                min,
                max,
                default,
                group,
                param_type,
                is_hidden,
                is_read_only,
                is_bypass,
                is_modulatable,
                module,
                enum_values,
                unit,
                display,
            } => {
                let param_type_str = match param_type {
                    crate::audio::devices::ParamType::Float => "float",
                    crate::audio::devices::ParamType::Bool => "bool",
                    crate::audio::devices::ParamType::Enum => "enum",
                };
                // Bitmask: 1 = hidden, 2 = read-only, 4 = bypass, 8 = modulatable
                let flags = (is_hidden as i32)
                    | ((is_read_only as i32) << 1)
                    | ((is_bypass as i32) << 2)
                    | ((is_modulatable as i32) << 3);

                let mut args = vec![
                    OscType::Int(param_id as i32),
                    OscType::String(name),
                    OscType::Float(min),
                    OscType::Float(max),
                    OscType::Float(default),
                    OscType::String(group),
                    OscType::String(param_type_str.to_string()),
                    OscType::Int(flags),
                    OscType::String(module),
                    OscType::Int(enum_values.len() as i32),
                ];
                for ev in enum_values {
                    args.push(OscType::String(ev));
                }
                args.push(OscType::String(unit));
                args.push(OscType::Int(display.len() as i32));
                args.extend(display.into_iter().map(OscType::Float));

                (device_path.to_osc_addr(channel_id, "param/info"), args)
            }
            EngineStatus::PluginParameterCount {
                channel_id,
                device_path,
                count,
            } => (
                device_path.to_osc_addr(channel_id, "param/count"),
                vec![OscType::Int(count as i32)],
            ),
            EngineStatus::SfzKeyInfo {
                channel_id,
                device_path,
                keys,
                ranges,
            } => (
                device_path.to_osc_addr(channel_id, "keys/info"),
                sfz_key_info_args(&keys, &ranges),
            ),
            EngineStatus::PluginStateSaved {
                channel_id,
                device_path,
                file_path,
                size,
            } => (
                device_path.to_osc_addr(channel_id, "state/saved"),
                vec![
                    OscType::String(file_path),
                    OscType::Int(size.clamp(-1, i32::MAX as i64) as i32),
                ],
            ),
            EngineStatus::PluginParameterValueChanged {
                channel_id,
                device_path,
                param_id,
                value,
            } => {
                let addr =
                    device_path.to_osc_addr(channel_id, &format!("param/{}/value", param_id));
                info!("📡 Sending OSC: {} [{}]", addr, value);
                (addr, vec![OscType::Float(value)])
            }
            EngineStatus::ModulatorAdded {
                channel_id,
                device_path,
                mod_id,
                kind,
            } => (
                device_path.to_osc_addr(channel_id, "modulator/add"),
                vec![OscType::Int(mod_id as i32), OscType::String(kind)],
            ),
            EngineStatus::ModulatorRemoved {
                channel_id,
                device_path,
                mod_id,
            } => (
                device_path.to_osc_addr(channel_id, &format!("modulator/{mod_id}/remove")),
                vec![OscType::Int(mod_id as i32)],
            ),
            EngineStatus::ModulatorParamChanged {
                channel_id,
                device_path,
                mod_id,
                param_id,
                value,
            } => (
                device_path.to_osc_addr(
                    channel_id,
                    &format!("modulator/{mod_id}/param/{param_id}/value"),
                ),
                vec![OscType::Float(value)],
            ),
            EngineStatus::ModulatorRouteChanged {
                channel_id,
                device_path,
                mod_id,
                target,
                amount,
            } => (
                device_path.to_osc_addr(channel_id, &format!("modulator/{mod_id}/route/set")),
                vec![OscType::String(target), OscType::Float(amount)],
            ),
            EngineStatus::ModulatorsCleared {
                channel_id,
                device_path,
            } => (
                device_path.to_osc_addr(channel_id, "modulator/clear"),
                vec![],
            ),
            EngineStatus::ModulatorKindsInfo { count } => (
                "/builtin/modulator_info".to_string(),
                vec![OscType::Int(count as i32)],
            ),
            EngineStatus::ModulatorKindInfo {
                id,
                name,
                bipolar,
                params,
            } => {
                let mut args = vec![
                    OscType::String(id),
                    OscType::String(name),
                    OscType::Int(if bipolar { 1 } else { 0 }),
                    OscType::Int(params.len() as i32),
                ];
                for param in &params {
                    push_param_args(&mut args, param);
                }
                ("/builtin/modulator_kind".to_string(), args)
            }
            EngineStatus::ModulatorKindsComplete { count } => (
                "/builtin/modulator_complete".to_string(),
                vec![OscType::Int(count as i32)],
            ),
            EngineStatus::LogMessage { level, message } => (
                "/log".to_string(),
                vec![OscType::String(level), OscType::String(message)],
            ),
            EngineStatus::EngineStats {
                load_avg,
                load_peak,
                xruns,
                lock_misses,
                callbacks,
                frames,
                plugin_underruns,
                ..
            } => (
                "/status/engine_stats".to_string(),
                vec![
                    OscType::Float(load_avg),
                    OscType::Float(load_peak),
                    OscType::Int(osc_count(xruns)),
                    OscType::Int(osc_count(lock_misses)),
                    OscType::Int(osc_count(callbacks)),
                    OscType::Int(frames as i32),
                    OscType::Int(osc_count(plugin_underruns)),
                ],
            ),
            EngineStatus::DeviceData {
                channel_id,
                device_path,
                data_type,
                data,
            } => (
                device_path.to_osc_addr(channel_id, "data"),
                vec![OscType::String(data_type), OscType::Blob(data)],
            ),
            EngineStatus::DeviceSleepStatus {
                channel_id,
                device_path,
                is_sleeping,
            } => (
                device_path.to_osc_addr(channel_id, "sleep"),
                vec![OscType::Int(if is_sleeping { 1 } else { 0 })],
            ),
        };

        let msg = OscMessage { addr, args };

        let packet = OscPacket::Message(msg);
        if let Ok(buf) = rosc::encoder::encode(&packet) {
            let client_addr = format!("127.0.0.1:{}", client_port);
            if let Ok(addr) = client_addr.parse::<SocketAddr>() {
                match socket.send_to(&buf, addr) {
                    Ok(bytes) => {
                        // Only log param changes for debugging
                        if is_param_change {
                            info!("📡 OSC sent: {} bytes to {}", bytes, addr);
                        }
                    }
                    Err(e) => warn!("Failed to send OSC: {}", e),
                }
            }
        }
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

    fn generate_clip_request_id(clip_id: &str) -> String {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        format!("clip:{}:{}", clip_id, now)
    }

    /// Submit an AudioFileService decode for a sampler device (or one of its zones) and track
    /// the request.
    fn begin_device_sample_load(
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

    fn handle_afs_event(&mut self, event: AfsEvent, command_tx: &Sender<AudioCommand>) {
        match event.clone() {
            AfsEvent::DecodeReady {
                req_id,
                cache_key,
                channels,
                sample_rate,
                samples,
                ..
            } => {
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

    /// Send a message to the client
    /// `{device}/gui/embedded parent_xid`: the host window is now in `parent_xid` (0 = out of
    /// any Godot window). Godot waits for it before hiding or freeing a window the plugin was in:
    /// Godot destroys a native window's X window when it hides it, and every child with it.
    fn send_gui_embedded(&self, channel_id: usize, device_path: &DevicePath, parent_xid: u64) {
        let addr = device_path.to_osc_addr(channel_id, "gui/embedded");
        // X11 XIDs are 29 bits, so an Int carries them
        if let Err(e) = self.send_message(&addr, vec![OscType::Int(parent_xid as i32)]) {
            warn!("Failed to send {}: {}", addr, e);
        }
    }

    fn send_message(&self, addr: &str, args: Vec<OscType>) -> Result<()> {
        let msg = OscMessage {
            addr: addr.to_string(),
            args,
        };

        let packet = OscPacket::Message(msg);
        let buf = rosc::encoder::encode(&packet)?;

        let client_addr = format!("127.0.0.1:{}", self.client_port);
        let addr = client_addr.parse::<SocketAddr>()?;
        self.socket.send_to(&buf, addr)?;

        Ok(())
    }
}

/// Parse `/add_device` arguments shared by channel-root and nested container paths.
fn parse_add_device_command(
    channel_id: usize,
    parent_path: DevicePath,
    args: &[OscType],
) -> Option<AudioCommand> {
    let device_id = match args.first() {
        Some(OscType::String(s)) => s.clone(),
        _ => return None,
    };
    let position = match args.get(1) {
        Some(OscType::Int(p)) => *p,
        _ => return None,
    };
    let active = args
        .get(2)
        .and_then(|arg| {
            if let OscType::Int(v) = arg {
                Some(*v != 0)
            } else {
                None
            }
        })
        .unwrap_or(true);
    let enabled = args
        .get(3)
        .and_then(|arg| {
            if let OscType::Int(v) = arg {
                Some(*v != 0)
            } else {
                None
            }
        })
        .unwrap_or(true);
    let device_type = args
        .get(4)
        .and_then(|arg| {
            if let OscType::String(t) = arg {
                Some(t.clone())
            } else {
                None
            }
        })
        .unwrap_or_else(|| "builtin".to_string());
    let device_file = args
        .get(5)
        .and_then(|arg| {
            if let OscType::String(f) = arg {
                Some(f.clone())
            } else {
                None
            }
        })
        .unwrap_or_default();
    Some(AudioCommand::AddDeviceToChannel {
        channel_id,
        parent_path,
        device_id,
        device_type,
        device_file,
        position,
        active,
        enabled,
    })
}

/// True when `path` is a PCM sample the Sampler can load (not an SFZ).
fn is_audio_sample_path(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    lower.ends_with(".wav") || lower.ends_with(".mp3") || lower.ends_with(".ogg")
}

/// Stable-enough request id when Godot does not supply one.
fn generate_device_request_id(channel_id: usize, device_path: &DevicePath) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!("device:{}:{}:{}", channel_id, device_path, now)
}

/// Parse the shared `i:point_id, i:tick, f:value, s:curve, f:tension` argument list used by
/// `/track/{id}/automation/{lane_id}/add_point` and `.../update_point`.
/// Parse `/transport/tempo_map` args (`i:tick, f:bpm` pairs). The flag is true when a trailing
/// or mistyped value was dropped.
/// Arguments of `/clip/{id}/add_note` and `/clip/{id}/update_note`.
#[derive(Debug, PartialEq)]
struct ClipNoteArgs {
    note_id: u64,
    note: u8,
    start_tick: i64,
    duration_ticks: i64,
    velocity: f32,
    release: f32,
}

/// Parse `i:note_id i:note i:start_tick i:duration f:vel f:rel`. Any other shape (an old Godot
/// build still sending an int velocity, say) logs a warning instead of being dropped silently.
fn parse_clip_note_args(addr: &str, args: &[OscType]) -> Option<ClipNoteArgs> {
    if let [OscType::Int(note_id), OscType::Int(note), OscType::Int(start_tick), OscType::Int(duration), OscType::Float(velocity), OscType::Float(release)] =
        args
    {
        return Some(ClipNoteArgs {
            note_id: *note_id as u64,
            note: (*note).clamp(0, 127) as u8,
            start_tick: *start_tick as i64,
            duration_ticks: *duration as i64,
            velocity: velocity.clamp(0.0, 1.0),
            release: release.clamp(0.0, 1.0),
        });
    }
    warn!(
        "{}: expected args (i i i i f f), got ({})",
        addr,
        osc_arg_types(args)
    );
    None
}

/// An integer arg; Godot may send ints as `h` or `f` depending on how they were built.
fn osc_int(arg: &OscType) -> Option<i64> {
    match arg {
        OscType::Int(i) => Some(*i as i64),
        OscType::Long(l) => Some(*l),
        OscType::Float(f) => Some(*f as i64),
        _ => None,
    }
}

fn osc_float(arg: &OscType) -> Option<f32> {
    match arg {
        OscType::Float(f) => Some(*f),
        OscType::Double(d) => Some(*d as f32),
        OscType::Int(i) => Some(*i as f32),
        OscType::Long(l) => Some(*l as f32),
        _ => None,
    }
}

/// Argument count of `zone/{zid}/set`.
const ZONE_SET_ARGS: usize = 19;

/// Parse `zone/{zid}/set`: `key_lo key_hi vel_lo vel_hi root tune gain start end reverse
/// loop_mode loop_start loop_end crossfade key_fade_lo key_fade_hi vel_fade_lo vel_fade_hi
/// group_id` (see `docs/subsystems/osc-protocol.md`). Ranges are clamped and ordered, the rest
/// clamped into range.
fn parse_zone_set(args: &[OscType]) -> Result<ZoneSettings, String> {
    if args.len() < ZONE_SET_ARGS {
        return Err(format!(
            "expected {} args, got {}",
            ZONE_SET_ARGS,
            args.len()
        ));
    }
    let int = |i: usize| {
        osc_int(&args[i])
            .map(|v| v.clamp(i32::MIN as i64, i32::MAX as i64) as i32)
            .ok_or_else(|| format!("arg {} is not a number: {:?}", i, args[i]))
    };
    let float = |i: usize| {
        osc_float(&args[i]).ok_or_else(|| format!("arg {} is not a number: {:?}", i, args[i]))
    };
    Ok(ZoneSettings {
        ranges: ZoneRanges::new(
            (int(0)?, int(1)?),
            (int(2)?, int(3)?),
            (int(14)?, int(15)?),
            (int(16)?, int(17)?),
        ),
        root: int(4)?.clamp(0, 127) as u8,
        tune: float(5)?,
        gain: float(6)?,
        start: float(7)?,
        end: float(8)?,
        reverse: int(9)? != 0,
        loop_mode: int(10)?.clamp(0, 2) as u8,
        loop_start: float(11)?,
        loop_end: float(12)?,
        crossfade: float(13)?,
        group_id: int(18)?.max(0) as u32,
    }
    .sanitized())
}

/// Parse `zone_group/{gid}/set`: `gain mute solo play_mode`.
fn parse_zone_group_set(args: &[OscType]) -> Result<(f32, bool, bool, GroupPlayMode), String> {
    match (
        args.first().and_then(osc_float),
        args.get(1).and_then(osc_int),
        args.get(2).and_then(osc_int),
        args.get(3).and_then(osc_int),
    ) {
        (Some(gain), Some(mute), Some(solo), Some(mode)) => Ok((
            gain,
            mute != 0,
            solo != 0,
            GroupPlayMode::from_index(mode as i32),
        )),
        _ => Err(format!("expected gain mute solo play_mode, got {:?}", args)),
    }
}

/// Parse plugin GUI embed args: `[parent_xid] x y w h [scroll_x scroll_y]` (all ints), with the
/// parent XID only when `with_xid`. The XID is 0 without it. None for a short list, a
/// non-numeric arg or a non-positive XID; width and height are at least 1.
fn parse_embed_args(
    args: &[OscType],
    with_xid: bool,
) -> Option<(u64, crate::window_manager::EmbedRect)> {
    let ints = args.iter().map(osc_int).collect::<Option<Vec<i64>>>()?;
    let (xid, rest) = if with_xid {
        let (&xid, rest) = ints.split_first()?;
        if xid <= 0 {
            return None;
        }
        (xid as u64, rest)
    } else {
        (0, &ints[..])
    };
    let [x, y, w, h, ref scroll @ ..] = *rest else {
        return None;
    };
    let rect = crate::window_manager::EmbedRect {
        x: x as i32,
        y: y as i32,
        width: w.max(1) as u32,
        height: h.max(1) as u32,
        scroll_x: scroll.first().copied().unwrap_or(0) as i32,
        scroll_y: scroll.get(1).copied().unwrap_or(0) as i32,
    };
    Some((xid, rect))
}

/// OSC type tags of `args` separated by spaces (`"i i f"`), for warnings.
fn osc_arg_types(args: &[OscType]) -> String {
    args.iter()
        .map(|arg| match arg {
            OscType::Int(_) => "i",
            OscType::Float(_) => "f",
            OscType::String(_) => "s",
            OscType::Blob(_) => "b",
            OscType::Long(_) => "h",
            OscType::Double(_) => "d",
            OscType::Bool(true) => "T",
            OscType::Bool(false) => "F",
            _ => "?",
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn parse_tempo_map_args(args: &[OscType]) -> (Vec<(i64, f32)>, bool) {
    let mut points = Vec::with_capacity(args.len() / 2);
    let mut dropped = args.len() % 2 == 1;
    for pair in args.chunks_exact(2) {
        match (&pair[0], &pair[1]) {
            (OscType::Int(tick), OscType::Float(bpm)) => points.push((*tick as i64, *bpm)),
            _ => dropped = true,
        }
    }
    (points, dropped)
}

/// Parse `/transport/time_signature_map` args (`i:bar, i:numerator, i:denominator` triples).
/// Out-of-range triples are dropped, duplicate bars keep the last, bar order is kept. The flag is
/// true when anything was dropped.
fn parse_time_signature_map_args(args: &[OscType]) -> (Vec<(u32, u16, u16)>, bool) {
    let mut changes: Vec<(u32, u16, u16)> = Vec::with_capacity(args.len() / 3);
    let mut dropped = args.len() % 3 != 0;
    for triple in args.chunks_exact(3) {
        let (OscType::Int(bar), OscType::Int(num), OscType::Int(den)) =
            (&triple[0], &triple[1], &triple[2])
        else {
            dropped = true;
            continue;
        };
        let in_range =
            *bar >= 2 && (1..=32).contains(num) && matches!(*den, 1 | 2 | 4 | 8 | 16 | 32);
        if !in_range {
            dropped = true;
            continue;
        }
        let entry = (*bar as u32, *num as u16, *den as u16);
        match changes.iter_mut().find(|c| c.0 == entry.0) {
            Some(existing) => *existing = entry,
            None => changes.push(entry),
        }
    }
    (changes, dropped)
}

fn parse_automation_point(args: &[OscType]) -> Option<AutomationPoint> {
    let (
        Some(OscType::Int(point_id)),
        Some(OscType::Int(tick)),
        Some(OscType::Float(value)),
        Some(OscType::String(curve)),
    ) = (args.get(0), args.get(1), args.get(2), args.get(3))
    else {
        warn!("Malformed automation point arguments: {:?}", args);
        return None;
    };
    // Tension is optional on the wire; phase-1 Godot always sends 0.0.
    let tension = match args.get(4) {
        Some(OscType::Float(t)) => *t,
        _ => 0.0,
    };
    Some(AutomationPoint::new(
        *point_id as AutomationPointId,
        *tick as i64,
        *value,
        CurveKind::parse(curve),
        tension,
    ))
}

/// Parse `/plugins/hosting <mode:s> [plugin_id:s mode:s]*` into a hosting policy. An unknown
/// override mode is skipped with a warning; an unknown global mode rejects the message.
fn parse_hosting_policy(args: &[OscType]) -> Result<crate::audio::ipc::HostingPolicy, String> {
    use crate::audio::ipc::{HostingMode, HostingPolicy};

    let mode = match args.first() {
        Some(OscType::String(name)) => {
            HostingMode::parse(name).ok_or_else(|| format!("unknown hosting mode '{}'", name))?
        }
        _ => return Err("expected the hosting mode as the first argument".to_string()),
    };
    let mut policy = HostingPolicy {
        mode,
        ..Default::default()
    };
    for pair in args[1..].chunks(2) {
        let [OscType::String(plugin_id), OscType::String(name)] = pair else {
            return Err("overrides must be (plugin_id:s, mode:s) pairs".to_string());
        };
        match HostingMode::parse(name) {
            Some(mode) => {
                policy.overrides.insert(plugin_id.clone(), mode);
            }
            None => warn!(
                "Ignoring hosting override for {}: unknown mode '{}'",
                plugin_id, name
            ),
        }
    }
    Ok(policy)
}

/// Parse `/render/start <job_id:s> <start_tick:i> <end_tick:i> <tail_seconds:f>
/// <until_silent:i> <master_path:s> <bit_depth:i> <sample_rate:i> <block_frames:i>
/// [<channel_id:i> <stem_path:s>]*`. An empty master path writes no master; a sample rate or
/// block size of 0 uses the default. The job itself is validated by the render worker.
fn parse_render_start(args: &[OscType]) -> Result<crate::audio::render::RenderJob, String> {
    use crate::audio::render::{RenderJob, RenderTail, WavFormat, DEFAULT_BLOCK_FRAMES};

    let tick = |arg: &OscType| match arg {
        OscType::Int(value) => Some(*value as i64),
        OscType::Long(value) => Some(*value),
        _ => None,
    };
    let [OscType::String(job_id), start, end, OscType::Float(tail_seconds), OscType::Int(until_silent), OscType::String(master), OscType::Int(bit_depth), OscType::Int(sample_rate), OscType::Int(block_frames), stems @ ..] =
        args
    else {
        return Err(format!(
            "expected (job_id:s, start_tick:i, end_tick:i, tail_seconds:f, until_silent:i, \
             master_path:s, bit_depth:i, sample_rate:i, block_frames:i, [channel_id:i, \
             stem_path:s]*), got {:?}",
            args
        ));
    };
    let (Some(start_tick), Some(end_tick)) = (tick(start), tick(end)) else {
        return Err("start_tick and end_tick must be integers".to_string());
    };
    if job_id.is_empty() {
        return Err("the job id is empty".to_string());
    }
    let mut job = RenderJob::new(job_id.clone(), start_tick, end_tick);
    job.tail = if *until_silent != 0 {
        RenderTail::UntilSilent {
            max_seconds: *tail_seconds,
        }
    } else {
        RenderTail::Seconds(*tail_seconds)
    };
    job.outputs.format = WavFormat::from_bits(*bit_depth)
        .ok_or_else(|| format!("bit depth {} isn't 16, 24 or 32", bit_depth))?;
    job.outputs.master = (!master.is_empty()).then(|| master.into());
    job.sample_rate = (*sample_rate).max(0) as u32;
    job.block_frames = if *block_frames > 0 {
        *block_frames as usize
    } else {
        DEFAULT_BLOCK_FRAMES
    };
    for pair in stems.chunks(2) {
        let [OscType::Int(channel_id), OscType::String(path)] = pair else {
            return Err("stems must be (channel_id:i, stem_path:s) pairs".to_string());
        };
        if *channel_id <= 0 {
            return Err(format!("invalid stem channel {}", channel_id));
        }
        job.outputs.stems.push((*channel_id as usize, path.into()));
    }
    Ok(job)
}

/// Parse `/render/analyze <job_id:s> <start_tick:i> <end_tick:i> <resolution:s> <pre_roll_ticks:i>
/// <result_path:s> <all_channels:i> [<channel_id:i>]*`. Resolution is "bar" or "beat"; a
/// negative pre-roll renders from tick 0. The master is always analyzed, plus every channel when
/// `all_channels` is non-zero, else the listed ones. Writes no WAV; `/render/done` carries the
/// result path.
fn parse_render_analyze(args: &[OscType]) -> Result<crate::audio::render::RenderJob, String> {
    use crate::audio::analysis::Resolution;
    use crate::audio::render::{AnalysisSpec, AnalysisTaps, PreRoll, RenderJob};

    let tick = |arg: &OscType| match arg {
        OscType::Int(value) => Some(*value as i64),
        OscType::Long(value) => Some(*value),
        _ => None,
    };
    let [OscType::String(job_id), start, end, OscType::String(resolution), pre_roll, OscType::String(path), OscType::Int(all), channels @ ..] =
        args
    else {
        return Err(format!(
            "expected (job_id:s, start_tick:i, end_tick:i, resolution:s, pre_roll_ticks:i, \
             result_path:s, all_channels:i, [channel_id:i]*), got {:?}",
            args
        ));
    };
    let (Some(start_tick), Some(end_tick), Some(pre_roll)) =
        (tick(start), tick(end), tick(pre_roll))
    else {
        return Err("start_tick, end_tick and pre_roll_ticks must be integers".to_string());
    };
    if job_id.is_empty() {
        return Err("the job id is empty".to_string());
    }
    let resolution = match resolution.as_str() {
        "bar" => Resolution::Bar,
        "beat" => Resolution::Beat,
        other => return Err(format!("resolution '{}' isn't bar or beat", other)),
    };
    let taps = if *all != 0 {
        AnalysisTaps::All
    } else {
        let mut ids = Vec::with_capacity(channels.len());
        for arg in channels {
            match arg {
                OscType::Int(id) if *id > 0 => ids.push(*id as usize),
                other => return Err(format!("invalid channel id {:?}", other)),
            }
        }
        AnalysisTaps::Channels(ids)
    };
    let mut job = RenderJob::new(job_id.clone(), start_tick, end_tick);
    job.analysis = Some(AnalysisSpec {
        taps,
        resolution,
        pre_roll: if pre_roll < 0 {
            PreRoll::FromStart
        } else {
            PreRoll::Ticks(pre_roll)
        },
        path: path.into(),
    });
    Ok(job)
}

/// Parse `/audio/config/set <device:s> <rate:i> <buffer:i>`.
fn parse_audio_config(args: &[OscType]) -> Result<AudioCommand, String> {
    match args {
        [OscType::String(device), OscType::Int(rate), OscType::Int(buffer), ..]
            if *rate >= 0 && *buffer > 0 =>
        {
            Ok(AudioCommand::SetAudioConfig {
                device: device.clone(),
                sample_rate: *rate as u32,
                period_frames: *buffer as u32,
            })
        }
        _ => Err(format!(
            "expected (device:s, rate:i, buffer:i), got {:?}",
            args
        )),
    }
}

/// `/audio/config` arguments: the running stream (device "" and zeros when none could be
/// opened), then the request, the PipeWire graph and the two warning texts.
fn audio_config_args(report: crate::audio::commands::AudioConfigReport) -> Vec<OscType> {
    let active = report.active;
    let (device, is_default, rate, period, latency, pairs) = match &active {
        Some(a) => (
            a.device.clone(),
            a.is_default_device,
            a.sample_rate,
            a.period_frames,
            a.latency_ms(),
            a.output_pairs(),
        ),
        None => (String::new(), false, 0, 0, 0.0, 0),
    };
    vec![
        OscType::String(device),
        OscType::Int(rate as i32),
        OscType::Int(period as i32),
        OscType::Float(latency),
        OscType::Int(pairs as i32),
        OscType::Int(is_default as i32),
        OscType::String(report.requested.device),
        OscType::Int(report.requested.sample_rate as i32),
        OscType::Int(report.requested.period_frames as i32),
        OscType::Int(report.graph_quantum as i32),
        OscType::Int(report.graph_rate as i32),
        OscType::String(report.mismatch),
        OscType::String(report.notice),
    ]
}

/// Clamp a running counter into an OSC int32 argument.
fn osc_count(count: u64) -> i32 {
    count.min(i32::MAX as u64) as i32
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

/// Append one parameter's typed descriptor to a `/builtin/*` message.
fn push_param_args(args: &mut Vec<OscType>, param: &BuiltinParamInfo) {
    args.push(OscType::Int(param.id as i32));
    args.push(OscType::String(param.name.clone()));
    args.push(OscType::String(param.unit.clone()));
    let ty_str = match param.param_type {
        crate::audio::devices::ParamType::Float => "float",
        crate::audio::devices::ParamType::Bool => "bool",
        crate::audio::devices::ParamType::Enum => "enum",
    };
    args.push(OscType::String(ty_str.to_string()));
    args.push(OscType::Int(if param.syncable { 1 } else { 0 }));
    args.push(OscType::Float(param.min));
    args.push(OscType::Float(param.max));
    args.push(OscType::Float(param.default));
    args.push(OscType::Int(if param.is_logarithmic { 1 } else { 0 }));
    args.push(OscType::Float(param.skew));
    args.push(OscType::Int(param.enum_values.len() as i32));
    for ev in &param.enum_values {
        args.push(OscType::String(ev.clone()));
    }
    args.push(OscType::String(param.module.clone()));
    args.push(OscType::Int(if param.is_automation_safe { 1 } else { 0 }));
    args.push(OscType::Int(if param.is_modulatable { 1 } else { 0 }));
}

/// `{device}/modulator/...` commands:
/// - `modulator/add [i:mod_id, s:kind]`
/// - `modulator/clear`
/// - `modulator/{mod_id}/remove`
/// - `modulator/{mod_id}/param/{id}/value [f:norm]`
/// - `modulator/{mod_id}/route/set [s:target, f:amount]`
fn parse_modulator_command(
    channel_id: usize,
    device_path: DevicePath,
    action: &[&str],
    args: &[OscType],
) -> Option<AudioCommand> {
    match action {
        ["modulator", "add"] => match (args.first(), args.get(1)) {
            (Some(OscType::Int(mod_id)), Some(OscType::String(kind))) => u8::try_from(*mod_id)
                .ok()
                .map(|mod_id| AudioCommand::AddModulator {
                    channel_id,
                    device_path,
                    mod_id,
                    kind: kind.clone(),
                }),
            _ => None,
        },
        ["modulator", "clear"] => Some(AudioCommand::ClearModulators {
            channel_id,
            device_path,
        }),
        ["modulator", mod_id, "remove"] => {
            mod_id
                .parse::<u8>()
                .ok()
                .map(|mod_id| AudioCommand::RemoveModulator {
                    channel_id,
                    device_path,
                    mod_id,
                })
        }
        ["modulator", mod_id, "param", param_id, "value"] => {
            match (mod_id.parse::<u8>(), param_id.parse::<u32>(), args.first()) {
                (Ok(mod_id), Ok(param_id), Some(OscType::Float(value))) => {
                    Some(AudioCommand::SetModulatorParameter {
                        channel_id,
                        device_path,
                        mod_id,
                        param_id,
                        value: *value,
                    })
                }
                _ => {
                    warn!(
                        "Ignoring modulator/{mod_id}/param/{param_id}/value: expected one float \
                         (normalized), got {args:?}"
                    );
                    None
                }
            }
        }
        ["modulator", mod_id, "route", "set"] => {
            match (mod_id.parse::<u8>(), args.first(), args.get(1)) {
                (Ok(mod_id), Some(OscType::String(target)), Some(OscType::Float(amount))) => {
                    Some(AudioCommand::SetModulatorRoute {
                        channel_id,
                        device_path,
                        mod_id,
                        target: target.clone(),
                        amount: *amount,
                    })
                }
                _ => None,
            }
        }
        _ => None,
    }
}

/// Args for `.../keys/info`: the key count, `(key, is_keyswitch, label)` per key, then the range
/// count and `(lo, hi)` per playable range.
fn sfz_key_info_args(keys: &[(u8, bool, String)], ranges: &[(u8, u8)]) -> Vec<OscType> {
    let mut args = Vec::with_capacity(2 + keys.len() * 3 + ranges.len() * 2);
    args.push(OscType::Int(keys.len() as i32));
    for (key, is_keyswitch, label) in keys {
        args.push(OscType::Int(*key as i32));
        args.push(OscType::Int(*is_keyswitch as i32));
        args.push(OscType::String(label.clone()));
    }
    args.push(OscType::Int(ranges.len() as i32));
    for (lo, hi) in ranges {
        args.push(OscType::Int(*lo as i32));
        args.push(OscType::Int(*hi as i32));
    }
    args
}

#[cfg(test)]
mod tests {
    use crate::window_manager::EmbedRect;

    fn rect(x: i32, y: i32, width: u32, height: u32, sx: i32, sy: i32) -> EmbedRect {
        EmbedRect {
            x,
            y,
            width,
            height,
            scroll_x: sx,
            scroll_y: sy,
        }
    }

    #[test]
    fn parse_embed_args_with_xid() {
        use rosc::OscType::*;
        let parsed = super::parse_embed_args(
            &[Int(0x3a00007), Int(10), Int(20), Int(920), Int(345)],
            true,
        );
        assert_eq!(parsed, Some((0x3a00007, rect(10, 20, 920, 345, 0, 0))));
        // Long and float args, plus scroll
        let parsed = super::parse_embed_args(
            &[
                Long(77),
                Float(1.0),
                Int(2),
                Int(300),
                Long(200),
                Int(40),
                Float(5.0),
            ],
            true,
        );
        assert_eq!(parsed, Some((77, rect(1, 2, 300, 200, 40, 5))));
        // Only scroll_x given
        let parsed =
            super::parse_embed_args(&[Int(5), Int(0), Int(0), Int(10), Int(10), Int(3)], true);
        assert_eq!(parsed, Some((5, rect(0, 0, 10, 10, 3, 0))));
    }

    #[test]
    fn parse_embed_args_without_xid() {
        use rosc::OscType::*;
        let parsed =
            super::parse_embed_args(&[Int(4), Int(8), Int(0), Int(-3), Int(12), Int(6)], false);
        // Width and height are at least 1
        assert_eq!(parsed, Some((0, rect(4, 8, 1, 1, 12, 6))));
    }

    #[test]
    fn parse_embed_args_rejects_bad_input() {
        use rosc::OscType::*;
        // Short lists
        assert_eq!(super::parse_embed_args(&[], true), None);
        assert_eq!(
            super::parse_embed_args(&[Int(1), Int(0), Int(0), Int(10)], true),
            None
        );
        assert_eq!(
            super::parse_embed_args(&[Int(0), Int(0), Int(10)], false),
            None
        );
        // Non-numeric arg
        assert_eq!(
            super::parse_embed_args(
                &[Int(1), Int(0), String("x".into()), Int(10), Int(10)],
                true
            ),
            None
        );
        // No parent window
        assert_eq!(
            super::parse_embed_args(&[Int(0), Int(0), Int(0), Int(10), Int(10)], true),
            None
        );
    }

    /// rosc 0.10 demanded 4 padding bytes after a blob already on a 4-byte boundary, so every
    /// 16-byte Drum Machine choke mask was dropped as undecodable.
    #[test]
    fn decodes_word_aligned_blob() {
        use rosc::{OscPacket, OscType};
        let mut packet = b"/b\0\0,b\0\0".to_vec();
        packet.extend_from_slice(&16u32.to_be_bytes());
        packet.extend_from_slice(&[7u8; 16]);
        let (_, decoded) = rosc::decoder::decode_udp(&packet).expect("blob decodes");
        let OscPacket::Message(msg) = decoded else {
            panic!("expected a message");
        };
        assert_eq!(msg.args, vec![OscType::Blob(vec![7u8; 16])]);
    }

    fn zone_args(values: [f32; 19]) -> Vec<rosc::OscType> {
        use rosc::OscType;
        // Ints where Godot sends ints (see parse_zone_set).
        const FLOATS: [usize; 7] = [5, 6, 7, 8, 11, 12, 13];
        values
            .iter()
            .enumerate()
            .map(|(i, v)| {
                if FLOATS.contains(&i) {
                    OscType::Float(*v)
                } else {
                    OscType::Int(*v as i32)
                }
            })
            .collect()
    }

    #[test]
    fn zone_osc_parses_nineteen_args() {
        use crate::audio::devices::sampler_zones::ZoneRanges;
        let args = zone_args([
            48.0, 62.0, 1.0, 64.0, 60.0, -1.5, 0.8, 0.1, 0.9, 1.0, 2.0, 0.3, 0.6, 0.25, 2.0, 3.0,
            0.0, 10.0, 4.0,
        ]);
        let s = super::parse_zone_set(&args).unwrap();
        assert_eq!(
            s.ranges,
            ZoneRanges::new((48, 62), (1, 64), (2, 3), (0, 10))
        );
        assert_eq!(s.root, 60);
        assert_eq!((s.tune, s.gain, s.start, s.end), (-1.5, 0.8, 0.1, 0.9));
        assert!(s.reverse);
        assert_eq!(s.loop_mode, 2);
        assert_eq!((s.loop_start, s.loop_end, s.crossfade), (0.3, 0.6, 0.25));
        assert_eq!(s.group_id, 4);
    }

    #[test]
    fn zone_osc_clamps_and_orders() {
        let args = zone_args([
            90.0, 300.0, 127.0, 0.0, 200.0, 99.0, -2.0, -1.0, 2.0, 0.0, 9.0, 0.0, 1.0, 5.0, 0.0,
            0.0, 0.0, 0.0, -3.0,
        ]);
        let s = super::parse_zone_set(&args).unwrap();
        assert_eq!((s.ranges.key_lo, s.ranges.key_hi), (90, 127));
        assert_eq!((s.ranges.vel_lo, s.ranges.vel_hi), (1, 127));
        assert_eq!(s.root, 127);
        assert_eq!((s.tune, s.gain, s.start, s.end), (48.0, 0.0, 0.0, 1.0));
        assert_eq!((s.loop_mode, s.crossfade, s.group_id), (2, 1.0, 0));
    }

    #[test]
    fn zone_osc_rejects_short_and_bad_args() {
        use rosc::OscType;
        let mut args = zone_args([0.0; 19]);
        assert!(super::parse_zone_set(&args[..18]).is_err());
        args[3] = OscType::String("loud".into());
        assert!(super::parse_zone_set(&args).is_err());
        let group = [
            OscType::Float(0.5),
            OscType::Int(0),
            OscType::Int(1),
            OscType::Int(1),
        ];
        let (gain, mute, solo, mode) = super::parse_zone_group_set(&group).unwrap();
        assert_eq!((gain, mute, solo), (0.5, false, true));
        assert_eq!(
            mode,
            crate::audio::devices::sampler_zones::GroupPlayMode::RoundRobin
        );
        assert!(super::parse_zone_group_set(&group[..3]).is_err());
    }

    #[test]
    fn sfz_key_info_args_layout() {
        use rosc::OscType;
        let args = super::sfz_key_info_args(
            &[(24, true, "Sustain".into()), (60, false, "Open".into())],
            &[(36, 72), (80, 90)],
        );
        assert_eq!(
            args,
            vec![
                OscType::Int(2),
                OscType::Int(24),
                OscType::Int(1),
                OscType::String("Sustain".into()),
                OscType::Int(60),
                OscType::Int(0),
                OscType::String("Open".into()),
                OscType::Int(2),
                OscType::Int(36),
                OscType::Int(72),
                OscType::Int(80),
                OscType::Int(90),
            ]
        );
        // An empty list is still a message, so Godot clears stale labels and ranges.
        assert_eq!(
            super::sfz_key_info_args(&[], &[]),
            vec![OscType::Int(0), OscType::Int(0)]
        );
    }

    use super::*;
    use crate::audio::ipc::HostingMode;

    fn string(s: &str) -> OscType {
        OscType::String(s.to_string())
    }

    #[test]
    fn render_analyze_parses() {
        use crate::audio::analysis::Resolution;
        use crate::audio::render::{AnalysisTaps, PreRoll};
        let mut args = vec![
            string("a1"),
            OscType::Int(3840),
            OscType::Int(7680),
            string("beat"),
            OscType::Int(-1),
            string("/tmp/a.json"),
            OscType::Int(0),
            OscType::Int(3),
            OscType::Int(4),
        ];
        let job = parse_render_analyze(&args).unwrap();
        let spec = job.analysis.as_ref().unwrap();
        assert_eq!((job.start_tick, job.end_tick), (3840, 7680));
        assert_eq!(spec.resolution, Resolution::Beat);
        assert_eq!(spec.pre_roll, PreRoll::FromStart);
        assert_eq!(spec.taps, AnalysisTaps::Channels(vec![3, 4]));
        assert_eq!(spec.path, std::path::PathBuf::from("/tmp/a.json"));
        assert_eq!(job.render_start_tick(), 0);
        assert!(job.validate(48_000).is_ok());

        args[4] = OscType::Int(960);
        args[6] = OscType::Int(1);
        let job = parse_render_analyze(&args).unwrap();
        assert_eq!(job.analysis.as_ref().unwrap().taps, AnalysisTaps::All);
        assert_eq!(job.render_start_tick(), 2880);

        args[3] = string("minute");
        assert!(parse_render_analyze(&args).is_err());
        assert!(parse_render_analyze(&args[..5]).is_err());
    }

    #[test]
    fn render_start_parses() {
        use crate::audio::render::{RenderTail, WavFormat};
        let mut args = vec![
            string("job1"),
            OscType::Int(0),
            OscType::Long(7680),
            OscType::Float(4.0),
            OscType::Int(1),
            string("/tmp/mix.wav"),
            OscType::Int(24),
            OscType::Int(0),
            OscType::Int(0),
            OscType::Int(3),
            string("/tmp/bass.wav"),
        ];
        let job = parse_render_start(&args).unwrap();
        assert_eq!(job.job_id, "job1");
        assert_eq!((job.start_tick, job.end_tick), (0, 7680));
        assert_eq!(job.tail, RenderTail::UntilSilent { max_seconds: 4.0 });
        assert_eq!(job.outputs.format, WavFormat::Int24);
        assert_eq!(job.outputs.master.as_deref(), Some("/tmp/mix.wav".as_ref()));
        assert_eq!(job.outputs.stems, vec![(3, "/tmp/bass.wav".into())]);
        assert_eq!(job.block_frames, crate::audio::render::DEFAULT_BLOCK_FRAMES);

        // No master, fixed tail
        args[4] = OscType::Int(0);
        args[5] = string("");
        let job = parse_render_start(&args).unwrap();
        assert_eq!(job.tail, RenderTail::Seconds(4.0));
        assert!(job.outputs.master.is_none());

        args[6] = OscType::Int(8);
        assert!(parse_render_start(&args).unwrap_err().contains("bit depth"));
        args[6] = OscType::Int(16);
        args.pop();
        assert!(parse_render_start(&args).unwrap_err().contains("pairs"));
        assert!(parse_render_start(&args[..4]).is_err());
    }

    #[test]
    fn modulator_commands_parse() {
        let path = DevicePath::root(0);
        let add = [OscType::Int(2), string("lfo")];
        match parse_modulator_command(2, path, &["modulator", "add"], &add) {
            Some(AudioCommand::AddModulator {
                channel_id: 2,
                mod_id: 2,
                kind,
                ..
            }) => assert_eq!(kind, "lfo"),
            other => panic!("unexpected: {:?}", other.is_some()),
        }
        assert!(matches!(
            parse_modulator_command(2, path, &["modulator", "clear"], &[]),
            Some(AudioCommand::ClearModulators { channel_id: 2, .. })
        ));
        assert!(matches!(
            parse_modulator_command(2, path, &["modulator", "3", "remove"], &[]),
            Some(AudioCommand::RemoveModulator { mod_id: 3, .. })
        ));
        match parse_modulator_command(
            2,
            path,
            &["modulator", "3", "param", "10", "value"],
            &[OscType::Float(0.4)],
        ) {
            Some(AudioCommand::SetModulatorParameter {
                mod_id: 3,
                param_id: 10,
                value,
                ..
            }) => assert_eq!(value, 0.4),
            other => panic!("unexpected: {:?}", other.is_some()),
        }
        match parse_modulator_command(
            2,
            path,
            &["modulator", "3", "route", "set"],
            &[string("param/2"), OscType::Float(-0.5)],
        ) {
            Some(AudioCommand::SetModulatorRoute {
                mod_id: 3,
                target,
                amount,
                ..
            }) => {
                assert_eq!(target, "param/2");
                assert_eq!(amount, -0.5);
            }
            other => panic!("unexpected: {:?}", other.is_some()),
        }
        // Wrong argument types, an out-of-range id and an unknown action are all dropped.
        let bad = [string("lfo"), OscType::Int(2)];
        assert!(parse_modulator_command(2, path, &["modulator", "add"], &bad).is_none());
        let big = [OscType::Int(300), string("lfo")];
        assert!(parse_modulator_command(2, path, &["modulator", "add"], &big).is_none());
        assert!(parse_modulator_command(2, path, &["modulator", "bogus"], &[]).is_none());
        // The old mod/* addresses are gone.
        assert!(parse_modulator_command(2, path, &["mod", "set"], &add).is_none());
    }

    #[test]
    fn clip_note_args_parse_floats_and_reject_old_shape() {
        let args = vec![
            OscType::Int(3),
            OscType::Int(60),
            OscType::Int(0),
            OscType::Int(480),
            OscType::Float(0.5039),
            OscType::Float(0.25),
        ];
        assert_eq!(
            parse_clip_note_args("/clip/x/add_note", &args),
            Some(ClipNoteArgs {
                note_id: 3,
                note: 60,
                start_tick: 0,
                duration_ticks: 480,
                velocity: 0.5039,
                release: 0.25,
            })
        );

        let old = vec![
            OscType::Int(1),
            OscType::Int(60),
            OscType::Int(0),
            OscType::Int(480),
            OscType::Int(100),
        ];
        assert_eq!(parse_clip_note_args("/clip/x/add_note", &old), None);
        assert_eq!(osc_arg_types(&old), "i i i i i");
    }

    #[test]
    fn tempo_map_args_parse_pairs() {
        let (points, dropped) = parse_tempo_map_args(&[
            OscType::Int(0),
            OscType::Float(120.0),
            OscType::Int(3840),
            OscType::Float(60.0),
        ]);
        assert_eq!(points, vec![(0, 120.0), (3840, 60.0)]);
        assert!(!dropped);

        let (empty, dropped) = parse_tempo_map_args(&[]);
        assert!(empty.is_empty() && !dropped);

        let (points, dropped) =
            parse_tempo_map_args(&[OscType::Int(0), OscType::Float(90.0), OscType::Int(5)]);
        assert_eq!(points, vec![(0, 90.0)]);
        assert!(dropped);
    }

    #[test]
    fn parse_time_signature_map_args_filters() {
        let ints = |v: &[i32]| v.iter().map(|i| OscType::Int(*i)).collect::<Vec<_>>();
        let (c, dropped) = parse_time_signature_map_args(&ints(&[3, 7, 8, 5, 3, 4]));
        assert_eq!(c, vec![(3, 7, 8), (5, 3, 4)]);
        assert!(!dropped);

        let (c, dropped) =
            parse_time_signature_map_args(&ints(&[1, 3, 4, 4, 0, 4, 4, 4, 3, 6, 33, 4]));
        assert!(c.is_empty() && dropped);

        let (c, _) = parse_time_signature_map_args(&ints(&[3, 7, 8, 3, 5, 4]));
        assert_eq!(c, vec![(3, 5, 4)]);

        let (c, dropped) = parse_time_signature_map_args(&[]);
        assert!(c.is_empty() && !dropped);
    }

    #[test]
    fn hosting_policy_parses_mode_and_overrides() {
        let policy = parse_hosting_policy(&[
            string("by_plugin"),
            string("crashy.synth"),
            string("individually"),
            string("other.fx"),
            string("bogus"),
        ])
        .unwrap();
        assert_eq!(policy.mode, HostingMode::ByPlugin);
        assert_eq!(
            policy.overrides.get("crashy.synth"),
            Some(&HostingMode::Individually)
        );
        assert!(!policy.overrides.contains_key("other.fx"));
    }

    #[test]
    fn hosting_policy_rejects_bad_messages() {
        assert!(parse_hosting_policy(&[]).is_err());
        assert!(parse_hosting_policy(&[string("within_engine")]).is_err());
        assert!(parse_hosting_policy(&[string("together"), string("dangling.id")]).is_err());
    }

    #[test]
    fn audio_config_set_parses_device_rate_and_buffer() {
        match parse_audio_config(&[
            string("hw:CARD=USB"),
            OscType::Int(44_100),
            OscType::Int(256),
        ]) {
            Ok(AudioCommand::SetAudioConfig {
                device,
                sample_rate,
                period_frames,
            }) => {
                assert_eq!(device, "hw:CARD=USB");
                assert_eq!(sample_rate, 44_100);
                assert_eq!(period_frames, 256);
            }
            other => panic!("unexpected {:?}", other),
        }
        assert!(parse_audio_config(&[string(""), OscType::Int(48_000)]).is_err());
        assert!(parse_audio_config(&[string(""), OscType::Int(48_000), OscType::Int(0)]).is_err());
        assert!(parse_audio_config(&[OscType::Int(1), OscType::Int(2), OscType::Int(3)]).is_err());
    }

    #[test]
    fn audio_config_reports_zeros_while_no_stream_runs() {
        use crate::audio::commands::AudioConfigReport;
        let args = audio_config_args(AudioConfigReport {
            notice: "No audio output could be opened.".into(),
            ..Default::default()
        });
        assert_eq!(args.len(), 13);
        assert_eq!(args[0], string(""));
        assert_eq!(args[1], OscType::Int(0));
        assert_eq!(args[4], OscType::Int(0));
        assert_eq!(args[12], string("No audio output could be opened."));
    }
}
