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
                            ..
                        } => stats_summary.observe(
                            *load_avg,
                            *load_peak,
                            *xruns,
                            *lock_misses,
                            *plugin_underruns,
                            *frames,
                        ),
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
                    GuiEvent::Resize {
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
                    if let Ok((_, packet)) = rosc::decoder::decode_udp(&buf[..size]) {
                        if let Err(e) =
                            self.handle_packet(packet, &command_tx, &log_writers, window_manager)
                        {
                            warn!("Error handling OSC packet: {}", e);
                        }
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
            ["gui", "open"] => {
                let process_key = device_path.to_window_key(channel_id);
                let window_handle = window_manager.create_window(process_key, 800, 600);
                command_tx.send(AudioCommand::OpenPluginGui {
                    channel_id,
                    device_path,
                    window_handle,
                })?;
            }
            ["gui", "close"] => {
                let process_key = device_path.to_window_key(channel_id);
                window_manager.destroy_window(&process_key);
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
            // Reload a crashed plugin: respawn its host and restore its state (Phase 4).
            ["reload"] => {
                command_tx.send(AudioCommand::ReloadDevice {
                    channel_id,
                    device_path,
                })?;
            }
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
                if let (
                    Some(OscType::Int(note_id)),
                    Some(OscType::Int(note)),
                    Some(OscType::Int(start_tick)),
                    Some(OscType::Int(duration)),
                    Some(OscType::Int(velocity)),
                ) = (
                    args.get(0),
                    args.get(1),
                    args.get(2),
                    args.get(3),
                    args.get(4),
                ) {
                    info!(
                        "Add note to clip {}: note_id {} note {} at tick {} duration {}",
                        id_str, note_id, note, start_tick, duration
                    );
                    command_tx.send(AudioCommand::AddNoteToClip {
                        clip_id: id_str.to_string(),
                        note_id: *note_id as u64,
                        note: *note as u8,
                        start_tick: *start_tick as i64,
                        duration_ticks: *duration as i64,
                        velocity: *velocity as u8,
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
                if let (
                    Some(OscType::Int(note_id)),
                    Some(OscType::Int(note)),
                    Some(OscType::Int(start_tick)),
                    Some(OscType::Int(duration)),
                    Some(OscType::Int(velocity)),
                ) = (
                    args.get(0),
                    args.get(1),
                    args.get(2),
                    args.get(3),
                    args.get(4),
                ) {
                    info!(
                        "Update note in clip {}: note_id {} note {} at tick {} duration {}",
                        id_str, note_id, note, start_tick, duration
                    );
                    command_tx.send(AudioCommand::UpdateClipNote {
                        clip_id: id_str.to_string(),
                        note_id: *note_id as u64,
                        note: *note as u8,
                        start_tick: *start_tick as i64,
                        duration_ticks: *duration as i64,
                        velocity: *velocity as u8,
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
                            if let Err(err) = service.submit_decode_and_waveform(
                                req_id.clone(),
                                file_path.clone(),
                                128,
                            ) {
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
            ["plugin", "save_state"] => {
                if let (Some(OscType::Int(channel_id)), Some(OscType::Int(device_position))) =
                    (args.get(0), args.get(1))
                {
                    info!(
                        "Save plugin state: channel={} device={}",
                        channel_id, device_position
                    );
                    command_tx.send(AudioCommand::SavePluginState {
                        channel_id: *channel_id as usize,
                        device_path: DevicePath::root(*device_position as usize),
                    })?;
                }
            }
            ["plugin", "load_state"] => {
                if let (
                    Some(OscType::Int(channel_id)),
                    Some(OscType::Int(device_position)),
                    Some(OscType::String(state_base64)),
                ) = (args.get(0), args.get(1), args.get(2))
                {
                    info!(
                        "Load plugin state: channel={} device={} ({} bytes)",
                        channel_id,
                        device_position,
                        state_base64.len()
                    );
                    command_tx.send(AudioCommand::LoadPluginState {
                        channel_id: *channel_id as usize,
                        device_path: DevicePath::root(*device_position as usize),
                        state_base64: state_base64.clone(),
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
                        let _ =
                            afs.submit_decode_and_waveform(req_id.clone(), abs_path.clone(), 128);
                    }
                }
            }
            ["audiofile", "waveform", "start"] => {
                if let (
                    Some(OscType::String(req_id)),
                    Some(OscType::String(abs_path)),
                    Some(OscType::Int(min_block_size)),
                ) = (args.get(0), args.get(1), args.get(2))
                {
                    info!(
                        "AudioFile waveform request: {} for {} (min_block={})",
                        req_id, abs_path, min_block_size
                    );
                    if let Ok(mut afs) = self.audio_file_service.lock() {
                        let _ = afs.submit_decode_and_waveform(
                            req_id.clone(),
                            abs_path.clone(),
                            *min_block_size as usize,
                        );
                    }
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
            EngineStatus::DeviceCrashed {
                channel_id,
                device_path,
                reason,
                stderr,
                pid,
            } => (
                device_path.to_osc_addr(channel_id, "crashed"),
                vec![
                    OscType::String(reason),
                    OscType::String(stderr),
                    OscType::Int(pid as i32),
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
            EngineStatus::PluginGuiResizeRequest { .. } => {
                // GUI resize is handled by the main loop with access to WindowManager
                // No need to send it to Godot
                return;
            }
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

                // Add all parameters inline (id, name, unit, type, syncable, min, max, default, enum_count, enum_values...)
                for param in parameters {
                    args.push(OscType::Int(param.id as i32));
                    args.push(OscType::String(param.name));
                    args.push(OscType::String(param.unit));
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
                    args.push(OscType::Int(param.enum_values.len() as i32));
                    for ev in param.enum_values {
                        args.push(OscType::String(ev));
                    }
                }

                args.push(OscType::Int(if is_container { 1 } else { 0 }));

                ("/builtin/info".to_string(), args)
            }
            EngineStatus::BuiltinDevicesComplete { count } => (
                "/builtin/complete".to_string(),
                vec![OscType::Int(count as i32)],
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
                module,
                enum_values,
            } => {
                let param_type_str = match param_type {
                    crate::audio::devices::ParamType::Float => "float",
                    crate::audio::devices::ParamType::Bool => "bool",
                    crate::audio::devices::ParamType::Enum => "enum",
                };
                // Bitmask: 1 = hidden, 2 = read-only, 4 = bypass
                let flags =
                    (is_hidden as i32) | ((is_read_only as i32) << 1) | ((is_bypass as i32) << 2);

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
            EngineStatus::PluginStateSaved {
                channel_id,
                device_path,
                state_base64,
            } => (
                "/plugin/state/saved".to_string(),
                vec![
                    OscType::Int(channel_id as i32),
                    OscType::String(device_path.to_string()),
                    OscType::String(state_base64),
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
            AfsEvent::WaveformLevel {
                req_id,
                level,
                block_size,
                num_blocks,
                file_path,
                byte_offset,
                byte_len,
            } => (
                "/audiofile/waveform/level".to_string(),
                vec![
                    OscType::String(req_id),
                    OscType::Int(level as i32),
                    OscType::Int(block_size as i32),
                    OscType::Long(num_blocks as i64),
                    OscType::String(file_path),
                    OscType::Long(byte_offset as i64),
                    OscType::Long(byte_len as i64),
                ],
            ),
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
            "/audiofile/waveform/level" => {
                if let [OscType::String(req_id), OscType::Int(level), OscType::Int(block_size), OscType::Long(num_blocks), OscType::String(file_path), OscType::Long(byte_offset), OscType::Long(byte_len)] =
                    &args[..]
                {
                    info!(
                        request_id = %req_id,
                        level,
                        block_size,
                        num_blocks,
                        file_path = %file_path,
                        byte_offset,
                        byte_len,
                        "OSC → Godot waveform level"
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

    /// Submit an AudioFileService decode for a sampler device and track the request.
    fn begin_device_sample_load(
        &self,
        channel_id: usize,
        device_path: DevicePath,
        file_path: String,
        req_id: String,
        command_tx: &Sender<AudioCommand>,
    ) -> Result<()> {
        info!(
            "Requesting sample load for channel {} device {} (req_id={}) from {}",
            channel_id, device_path, req_id, file_path
        );
        {
            let mut pending = self.pending_device_loads.lock().unwrap();
            pending.insert(
                req_id.clone(),
                PendingDevice {
                    channel_id,
                    device_path: device_path.clone(),
                    source_path: file_path.clone(),
                },
            );
        }
        command_tx.send(AudioCommand::BeginLoadDeviceSample {
            channel_id,
            device_path: device_path.clone(),
            req_id: req_id.clone(),
        })?;
        match self.audio_file_service.lock() {
            Ok(service) => {
                if let Err(err) =
                    service.submit_decode_and_waveform(req_id.clone(), file_path.clone(), 128)
                {
                    warn!(
                        "Failed to submit sample decode (req_id={}): {}",
                        req_id, err
                    );
                    self.pending_device_loads.lock().unwrap().remove(&req_id);
                    let _ = command_tx.send(AudioCommand::FailDeviceSampleLoad {
                        channel_id,
                        device_path,
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
            AfsEvent::WaveformLevel {
                req_id,
                level,
                block_size,
                num_blocks,
                ..
            } => {
                debug!(
                    request_id = %req_id,
                    level,
                    block_size,
                    num_blocks,
                    "AudioFileService waveform level ready"
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
    ) {
        let Some(started) = self.started else {
            self.reset(xruns, lock_misses, plugin_underruns);
            return;
        };
        self.samples += 1;
        self.load_sum += load_avg;
        self.load_peak = self.load_peak.max(load_peak);

        let elapsed = started.elapsed();
        if elapsed < STATS_SUMMARY_INTERVAL {
            return;
        }
        let per_min = 60.0 / elapsed.as_secs_f32();
        info!(
            "Engine stats ({:.0}s, {} frames): load avg {:.1}%, load peak {:.1}%, xruns/min {:.1}, lock misses/min {:.1}, plugin dropouts/min {:.1}",
            elapsed.as_secs_f32(),
            frames,
            self.load_sum / self.samples.max(1) as f32 * 100.0,
            self.load_peak * 100.0,
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::ipc::HostingMode;

    fn string(s: &str) -> OscType {
        OscType::String(s.to_string())
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
}
