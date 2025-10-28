use anyhow::{Context, Result};
use crossbeam::channel::{Receiver, Sender};
use rosc::{OscMessage, OscPacket, OscType};
use std::fs::File;
use std::net::{SocketAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tracing::{info, warn};

use crate::audio::{AudioCommand, EngineStatus, ProjectSettings};
use crate::audio::io::load_wav_file;
use crate::window_manager::WindowManager;

/// OSC server that receives messages from Godot UI and sends status updates
pub struct OscServer {
    socket: UdpSocket,
    client_addr: Option<SocketAddr>,
    client_port: u16,
}

impl OscServer {
    /// Create a new OSC server listening on the specified port
    pub fn new(port: u16) -> Result<Self> {
        let addr = format!("127.0.0.1:{}", port);
        let socket = UdpSocket::bind(&addr)
            .context(format!("Failed to bind OSC server to {}", addr))?;
        
        socket.set_nonblocking(true)?;
        
        info!("OSC server listening on {}", addr);
        
        Ok(Self {
            socket,
            client_addr: None,
            client_port: 7001, // Godot listens on 7001
        })
    }

    /// Start the OSC server and process incoming messages
    pub fn run(
        mut self,
        command_tx: Sender<AudioCommand>,
        status_rx: Receiver<EngineStatus>,
        log_writer: Arc<Mutex<File>>,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        let mut buf = [0u8; 2048];
        
        // GUI events from audio thread that need window manager access
        enum GuiEvent {
            Resize { channel_id: usize, device_position: usize, width: u32, height: u32 },
            Closed { channel_id: usize, device_position: usize },
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
            
            loop {
                if let Ok(status) = status_rx.recv_timeout(Duration::from_millis(10)) {
                    // Forward GUI events to main loop
                    match &status {
                        EngineStatus::PluginGuiResizeRequest { channel_id, device_position, width, height } => {
                            let _ = gui_event_tx.send(GuiEvent::Resize {
                                channel_id: *channel_id,
                                device_position: *device_position,
                                width: *width,
                                height: *height,
                            });
                        }
                        EngineStatus::PluginGuiClosed { channel_id, device_position } => {
                            let _ = gui_event_tx.send(GuiEvent::Closed {
                                channel_id: *channel_id,
                                device_position: *device_position,
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
                        })).unwrap_or_default();
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
                    GuiEvent::Resize { channel_id, device_position, width, height } => {
                        let process_key = format!("plugin_{}_{}", channel_id, device_position);
                        info!("🔄 Resizing window {} to {}x{}", process_key, width, height);
                        window_manager.resize_window(&process_key, width, height);
                        // Show the window now that it's the right size
                        window_manager.show_window(&process_key);
                    }
                    GuiEvent::Closed { channel_id, device_position } => {
                        let process_key = format!("plugin_{}_{}", channel_id, device_position);
                        info!("🗑️  Plugin confirmed GUI closed, destroying window: {}", process_key);
                        window_manager.destroy_window(&process_key);
                    }
                }
            }
            
            // Check for window close events (user clicked X)
            while let Ok(process_key) = window_manager.close_event_rx.try_recv() {
                info!("🗑️  Window close requested by user: {}", process_key);
                // Parse channel_id and device_position from process_key (format: "plugin_3_0")
                if let Some(parts) = process_key.strip_prefix("plugin_") {
                    let parts: Vec<&str> = parts.split('_').collect();
                    if parts.len() == 2 {
                        if let (Ok(channel_id), Ok(device_position)) = (parts[0].parse::<usize>(), parts[1].parse::<usize>()) {
                            // Send CloseGui command to cleanup plugin state
                            // Window will be destroyed when we receive PluginGuiClosed status
                            let _ = command_tx.send(AudioCommand::ClosePluginGui {
                                channel_id,
                                device_position,
                            });
                        }
                    }
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
                        if let Err(e) = self.handle_packet(packet, &command_tx, &log_writer, window_manager) {
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
    fn handle_packet(&self, packet: OscPacket, command_tx: &Sender<AudioCommand>, log_writer: &Arc<Mutex<File>>, window_manager: &mut WindowManager) -> Result<()> {
        match packet {
            OscPacket::Message(msg) => self.handle_message(msg, command_tx, log_writer, window_manager),
            OscPacket::Bundle(bundle) => {
                for packet in bundle.content {
                    self.handle_packet(packet, command_tx, log_writer, window_manager)?;
                }
                Ok(())
            }
        }
    }

    /// Rotate the log file by renaming the current engine.log to a timestamped file
    fn rotate_log_file(log_writer: &Arc<Mutex<File>>) -> Result<()> {
        use chrono::Local;
        use std::io::Write;

        // Generate timestamp for the archived log file
        let timestamp = Local::now().format("%Y%m%d_%H%M%S");
        let archived_name = format!("logs/engine_{}.log", timestamp);

        // Log the rotation event BEFORE rotating (so it goes to the old file)
        info!("Rotating log file to {}", archived_name);

        // Strategy:
        // 1. Lock the mutex and get mutable access to the File
        // 2. Flush and drop the old file
        // 3. Rename the old engine.log file on disk
        // 4. Create a new engine.log and put it in the mutex

        if let Ok(mut writer) = log_writer.lock() {
            // Flush any pending writes to the old file
            let _ = writer.flush();

            // Drop the old file by replacing it with a temporary dummy file
            // This closes the file descriptor to engine.log
            *writer = File::create("logs/engine.log.tmp")?;
        }

        // Now that the old file is closed, we can rename it
        if std::path::Path::new("logs/engine.log").exists() {
            std::fs::rename("logs/engine.log", &archived_name)?;
        }

        // Clean up the temporary file
        if std::path::Path::new("logs/engine.log.tmp").exists() {
            std::fs::remove_file("logs/engine.log.tmp")?;
        }

        // Create the new engine.log file and swap it into the mutex
        let new_file = File::create("logs/engine.log")?;

        if let Ok(mut writer) = log_writer.lock() {
            *writer = new_file;
        }

        // Log to the NEW file
        info!("Log rotation complete - new session started");

        Ok(())
    }

    /// Handle an individual OSC message
    fn handle_message(&self, msg: OscMessage, command_tx: &Sender<AudioCommand>, log_writer: &Arc<Mutex<File>>, window_manager: &mut WindowManager) -> Result<()> {
        let addr = msg.addr.as_str();
        let args = &msg.args;

        // Split address into parts for path-based routing
        let parts: Vec<&str> = addr.split('/').filter(|s| !s.is_empty()).collect();

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
                    (args.get(0), args.get(1)) {
                    info!("Set time signature to {}/{}", num, den);
                    command_tx.send(AudioCommand::SetTimeSignature(*num, *den))?;
                }
            }

            // Project setup
            ["project", "init"] => {
                if let (Some(OscType::Float(tempo)), Some(OscType::Int(num)),
                        Some(OscType::Int(den)), Some(OscType::Int(ppq)),
                        Some(OscType::Int(sr))) =
                    (args.get(0), args.get(1), args.get(2), args.get(3), args.get(4)) {
                    // Rotate log file before initializing new project
                    if let Err(e) = Self::rotate_log_file(log_writer) {
                        warn!("Failed to rotate log file: {}", e);
                    }

                    info!("Initialize project: {}bpm {}/{} PPQ={} SR={}", tempo, num, den, ppq, sr);
                    let settings = ProjectSettings {
                        tempo: *tempo,
                        time_numerator: *num,
                        time_denominator: *den,
                        ppq: *ppq,
                        sample_rate: *sr,
                    };
                    command_tx.send(AudioCommand::InitProject(settings))?;
                    
                    // Send confirmation that engine is ready
                    let _ = self.send_message("/status/connected", vec![OscType::Int(1)]);
                }
            }
            ["project", "clear"] => {
                info!("Clear project");
                command_tx.send(AudioCommand::ClearProject)?;
            }

            // Channel management - path-based: /channel/{id}/{command}
            ["channel", id_str, "create"] => {
                if let (Ok(id), Some(OscType::String(name))) = (id_str.parse::<usize>(), args.first()) {
                    info!("Create channel {} ({})", id, name);
                    command_tx.send(AudioCommand::CreateChannel { id, name: name.clone() })?;
                }
            }
            ["channel", id_str, "volume"] => {
                if let (Ok(id), Some(OscType::Float(db))) = (id_str.parse::<usize>(), args.first()) {
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
                        command_tx.send(AudioCommand::SetChannelPan { id, pan_left: *pan_left, pan_right })?;
                    }
                }
            }
            ["channel", id_str, "pan_mode"] => {
                if let (Ok(id), Some(OscType::Int(mode))) = (id_str.parse::<usize>(), args.first()) {
                    command_tx.send(AudioCommand::SetChannelPanMode { id, mode: *mode })?;
                }
            }
            ["channel", id_str, "mute"] => {
                if let (Ok(id), Some(OscType::Int(mute))) = (id_str.parse::<usize>(), args.first()) {
                    command_tx.send(AudioCommand::SetChannelMute { id, mute: *mute != 0 })?;
                }
            }
            ["channel", id_str, "solo"] => {
                if let (Ok(id), Some(OscType::Int(solo))) = (id_str.parse::<usize>(), args.first()) {
                    command_tx.send(AudioCommand::SetChannelSolo { id, solo: *solo != 0 })?;
                }
            }
            ["channel", id_str, "route"] => {
                if let (Ok(id), Some(OscType::Int(output_id))) = (id_str.parse::<usize>(), args.first()) {
                    let output = if *output_id < 0 { None } else { Some(*output_id as usize) };
                    command_tx.send(AudioCommand::SetChannelRoute { id, output_id: output })?;
                }
            }

            // Track management - path-based: /track/{id}/{command}
            ["track", id_str, "create"] => {
                if let (Ok(id), Some(OscType::Int(channel_id))) = (id_str.parse::<usize>(), args.first()) {
                    info!("Create track {} -> channel {}", id, channel_id);
                    command_tx.send(AudioCommand::CreateTrack {
                        id,
                        channel_id: *channel_id as usize
                    })?;
                }
            }
            ["track", id_str, "route"] => {
                if let (Ok(id), Some(OscType::Int(channel_id))) = (id_str.parse::<usize>(), args.first()) {
                    info!("Route track {} to channel {}", id, channel_id);
                    command_tx.send(AudioCommand::SetTrackRoute {
                        id,
                        channel_id: *channel_id as usize
                    })?;
                }
            }

            // Clip management - path-based: /clip/{id}/{command}
            ["clip", "create"] => {
                if let (Some(OscType::String(id)), Some(OscType::String(clip_type)),
                        Some(OscType::String(name))) =
                    (args.get(0), args.get(1), args.get(2)) {
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
                    command_tx.send(AudioCommand::RemoveClip {
                        id: id.clone(),
                    })?;
                }
            }
            ["clip", id_str, "add_note"] => {
                if let (Some(OscType::Int(note_id)), Some(OscType::Int(note)),
                        Some(OscType::Int(start_tick)), Some(OscType::Int(duration)),
                        Some(OscType::Int(velocity))) =
                    (args.get(0), args.get(1), args.get(2), args.get(3), args.get(4)) {
                    info!("Add note to clip {}: note_id {} note {} at tick {} duration {}",
                          id_str, note_id, note, start_tick, duration);
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
                if let (Some(OscType::Int(note_id)), Some(OscType::Int(note)),
                        Some(OscType::Int(start_tick)), Some(OscType::Int(duration)),
                        Some(OscType::Int(velocity))) =
                    (args.get(0), args.get(1), args.get(2), args.get(3), args.get(4)) {
                    info!("Update note in clip {}: note_id {} note {} at tick {} duration {}",
                          id_str, note_id, note, start_tick, duration);
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
                if let (Some(OscType::String(file_path)), Some(OscType::Int(sample_rate)),
                        Some(OscType::Int(channels))) =
                    (args.get(0), args.get(1), args.get(2)) {
                    info!("Load audio file into clip {}: {} at {} Hz, {} channels",
                          id_str, file_path, sample_rate, channels);

                    // Load WAV file
                    match load_wav_file(file_path) {
                        Ok(samples) => {
                            info!("Loaded {} samples from {}", samples.len(), file_path);
                            command_tx.send(AudioCommand::LoadAudioClip {
                                clip_id: id_str.to_string(),
                                samples,
                                sample_rate: *sample_rate as u32,
                                channels: *channels as usize,
                            })?;
                        }
                        Err(e) => {
                            warn!("Failed to load audio file {}: {}", file_path, e);
                            command_tx.send(AudioCommand::LoadAudioClip {
                                clip_id: id_str.to_string(),
                                samples: Vec::new(),
                                sample_rate: *sample_rate as u32,
                                channels: *channels as usize,
                            })?;
                        }
                    }
                } else {
                    warn!("OSC: load_audio_file missing arguments: got {} args", args.len());
                }
            }

            // ClipInstance management - path-based: /track/{track_id}/instance/{command}
            ["track", track_id_str, "add_instance"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let (Some(OscType::String(instance_id)), Some(OscType::String(clip_id)),
                            Some(OscType::Int(start_tick)), Some(OscType::Int(duration))) =
                        (args.get(0), args.get(1), args.get(2), args.get(3)) {
                        info!("Add clip instance {} to track {}: clip {} at tick {} duration {}",
                              instance_id, track_id, clip_id, start_tick, duration);
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
                        info!("Remove clip instance {} from track {}", instance_id, track_id);
                        command_tx.send(AudioCommand::RemoveClipInstance {
                            track_id,
                            instance_id: instance_id.clone(),
                        })?;
                    }
                }
            }
            ["track", track_id_str, "instance", instance_id_str, "set_position"] => {
                if let Ok(track_id) = track_id_str.parse::<usize>() {
                    if let (Some(OscType::Int(start_tick)), Some(OscType::Int(duration)), Some(OscType::Int(clip_offset))) =
                        (args.get(0), args.get(1), args.get(2)) {
                        info!("Set instance {} position: start {} duration {} offset {}", instance_id_str, start_tick, duration, clip_offset);
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
                        info!("Set instance {} transpose: {} semitones", instance_id_str, semitones);
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
                    if let (Some(OscType::Int(enabled)), Some(OscType::Int(start_tick)),
                            Some(OscType::Int(length))) =
                        (args.get(0), args.get(1), args.get(2)) {
                        info!("Set instance {} loop: enabled={} start={} length={}",
                              instance_id_str, enabled, start_tick, length);
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
                if let (Ok(channel_id), Some(OscType::String(device_id)), Some(OscType::Int(position))) =
                    (channel_id_str.parse::<usize>(), args.get(0), args.get(1)) {
                    // Optional active and enabled parameters (default to true if not provided)
                    let active = args.get(2)
                        .and_then(|arg| if let OscType::Int(v) = arg { Some(*v != 0) } else { None })
                        .unwrap_or(true);
                    let enabled = args.get(3)
                        .and_then(|arg| if let OscType::Int(v) = arg { Some(*v != 0) } else { None })
                        .unwrap_or(true);
                    
                    info!("Add device {} to channel {} at position {} [active={}, enabled={}]", 
                        device_id, channel_id, position, active, enabled);
                    command_tx.send(AudioCommand::AddDeviceToChannel {
                        channel_id,
                        device_id: device_id.clone(),
                        position: *position,
                        active,
                        enabled,
                    })?;
                }
            }
            ["channel", channel_id_str, "device", device_pos_str, "activate"] => {
                if let (Ok(channel_id), Ok(device_position), Some(OscType::Int(active))) =
                    (channel_id_str.parse::<usize>(), device_pos_str.parse::<usize>(), args.first()) {
                    info!("Set device active state: channel={} device={} active={}",
                          channel_id, device_position, *active != 0);
                    command_tx.send(AudioCommand::SetDeviceActive {
                        channel_id,
                        device_position,
                        active: *active != 0,
                    })?;
                }
            }
            ["channel", channel_id_str, "device", device_pos_str, "enable"] => {
                if let (Ok(channel_id), Ok(device_position), Some(OscType::Int(enabled))) =
                    (channel_id_str.parse::<usize>(), device_pos_str.parse::<usize>(), args.first()) {
                    info!("Set device enabled state: channel={} device={} enabled={}",
                          channel_id, device_position, *enabled != 0);
                    command_tx.send(AudioCommand::SetDeviceEnabled {
                        channel_id,
                        device_position,
                        enabled: *enabled != 0,
                    })?;
                }
            }
            ["channel", channel_id_str, "device", device_pos_str, "load_file"] => {
                if let (Ok(channel_id), Ok(device_position), Some(OscType::String(file_path))) =
                    (channel_id_str.parse::<usize>(), device_pos_str.parse::<usize>(), args.first()) {
                    info!("Load file into device: channel={} device={} path={}",
                          channel_id, device_position, file_path);
                    command_tx.send(AudioCommand::LoadDeviceFile {
                        channel_id,
                        device_position,
                        file_path: file_path.clone(),
                    })?;
                }
            }
            ["channel", channel_id_str, "device", device_pos_str, "gui", "open"] => {
                if let (Ok(channel_id), Ok(device_position)) =
                    (channel_id_str.parse::<usize>(), device_pos_str.parse::<usize>()) {
                    info!("Open plugin GUI: channel={} device={}", channel_id, device_position);

                    // Create window for embedded plugin GUI (blocks until created)
                    let process_key = format!("plugin_{}_{}", channel_id, device_position);
                    let window_handle = window_manager.create_window(process_key.clone(), 800, 600);

                    if window_handle.is_none() {
                        warn!("⚠️  Failed to create window for plugin GUI, falling back to floating mode");
                    }

                    command_tx.send(AudioCommand::OpenPluginGui {
                        channel_id,
                        device_position,
                        window_handle,
                    })?;
                }
            }
            ["channel", channel_id_str, "device", device_pos_str, "gui", "close"] => {
                if let (Ok(channel_id), Ok(device_position)) =
                    (channel_id_str.parse::<usize>(), device_pos_str.parse::<usize>()) {
                    info!("Close plugin GUI: channel={} device={}", channel_id, device_position);

                    // Destroy window
                    let process_key = format!("plugin_{}_{}", channel_id, device_position);
                    window_manager.destroy_window(&process_key);

                    command_tx.send(AudioCommand::ClosePluginGui {
                        channel_id,
                        device_position,
                    })?;
                }
            }
            ["channel", channel_id_str, "remove_device"] => {
                if let (Ok(channel_id), Some(OscType::Int(position))) =
                    (channel_id_str.parse::<usize>(), args.first()) {
                    info!("Remove device from channel {} at position {}", channel_id, position);
                    command_tx.send(AudioCommand::RemoveDeviceFromChannel {
                        channel_id,
                        position: *position as usize,
                    })?;
                }
            }
            ["channel", channel_id_str, "clear_devices"] => {
                if let Ok(channel_id) = channel_id_str.parse::<usize>() {
                    info!("Clear all devices from channel {}", channel_id);
                    command_tx.send(AudioCommand::ClearChannelDevices { channel_id })?;
                }
            }
            ["channel", channel_id_str, "device", device_pos_str, "param", param_id_str] => {
                if let (Ok(channel_id), Ok(device_position), Ok(param_id), Some(OscType::Float(value))) =
                    (channel_id_str.parse::<usize>(), device_pos_str.parse::<usize>(),
                     param_id_str.parse::<u32>(), args.first()) {
                    info!("Set device parameter: channel={} device={} param={} value={}",
                          channel_id, device_position, param_id, value);
                    command_tx.send(AudioCommand::SetDeviceParameter {
                        channel_id,
                        device_position,
                        param_id,
                        value: *value,
                    })?;
                }
            }

            // Plugin management - path-based: /plugin/{command}
            ["plugin", "scan"] => {
                info!("Scan plugins");
                command_tx.send(AudioCommand::ScanPlugins)?;
            }
            ["plugin", "get_parameters"] => {
                if let (Some(OscType::Int(channel_id)), Some(OscType::Int(device_position))) =
                    (args.get(0), args.get(1)) {
                    info!("Get plugin parameters: channel={} device={}", channel_id, device_position);
                    command_tx.send(AudioCommand::GetPluginParameters {
                        channel_id: *channel_id as usize,
                        device_position: *device_position as usize,
                    })?;
                }
            }
            ["plugin", "save_state"] => {
                if let (Some(OscType::Int(channel_id)), Some(OscType::Int(device_position))) =
                    (args.get(0), args.get(1)) {
                    info!("Save plugin state: channel={} device={}", channel_id, device_position);
                    command_tx.send(AudioCommand::SavePluginState {
                        channel_id: *channel_id as usize,
                        device_position: *device_position as usize,
                    })?;
                }
            }
            ["plugin", "load_state"] => {
                if let (Some(OscType::Int(channel_id)), Some(OscType::Int(device_position)),
                        Some(OscType::String(state_base64))) =
                    (args.get(0), args.get(1), args.get(2)) {
                    info!("Load plugin state: channel={} device={} ({} bytes)",
                          channel_id, device_position, state_base64.len());
                    command_tx.send(AudioCommand::LoadPluginState {
                        channel_id: *channel_id as usize,
                        device_position: *device_position as usize,
                        state_base64: state_base64.clone(),
                    })?;
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
            EngineStatus::PlayheadUpdate(ticks) => {
                ("/status/playhead".to_string(), vec![OscType::Int(ticks as i32)])
            }
            EngineStatus::PlayingStateChanged(playing) => {
                ("/status/playing".to_string(), vec![OscType::Int(if playing { 1 } else { 0 })])
            }
            EngineStatus::ChannelPeaks { id, peak_left, peak_right } => {
                // New path-based format: /channel/{id}/peak [peak_left, peak_right]
                (format!("/channel/{}/peak", id), vec![
                    OscType::Float(peak_left),
                    OscType::Float(peak_right),
                ])
            }
            EngineStatus::DeviceActiveChanged { channel_id, device_position, active } => {
                (format!("/channel/{}/device/{}/active", channel_id, device_position), vec![
                    OscType::Int(if active { 1 } else { 0 })
                ])
            }
            EngineStatus::DeviceEnabledChanged { channel_id, device_position, enabled } => {
                (format!("/channel/{}/device/{}/enabled", channel_id, device_position), vec![
                    OscType::Int(if enabled { 1 } else { 0 })
                ])
            }
            EngineStatus::DeviceReady { .. } => {
                // DeviceReady is handled internally (triggers parameter re-send)
                // No need to send it to Godot
                return;
            }
            EngineStatus::PluginGuiResizeRequest { .. } => {
                // GUI resize is handled by the main loop with access to WindowManager
                // No need to send it to Godot  
                return;
            }
            EngineStatus::PluginGuiClosed { .. } => {
                // GUI close is handled by the main loop with access to WindowManager
                // No need to send it to Godot
                return;
            }
            EngineStatus::PluginScanComplete { count } => {
                ("/plugin/scan_complete".to_string(), vec![OscType::Int(count as i32)])
            }
            EngineStatus::PluginInfo { id, name, vendor, version, category, description } => {
                let mut args = vec![
                    OscType::String(id),
                    OscType::String(name),
                    OscType::String(vendor),
                    OscType::String(version),
                    OscType::String(category),
                ];
                // Add description if present, otherwise send empty string
                args.push(OscType::String(description.unwrap_or_default()));
                ("/plugin/info".to_string(), args)
            }
            EngineStatus::PluginParameterInfo { channel_id, device_position, param_id, name, min, max, default } => {
                (format!("/channel/{}/device/{}/param/info", channel_id, device_position), vec![
                    OscType::Int(param_id as i32),
                    OscType::String(name),
                    OscType::Float(min),
                    OscType::Float(max),
                    OscType::Float(default),
                ])
            }
            EngineStatus::PluginParameterCount { channel_id, device_position, count } => {
                (format!("/channel/{}/device/{}/param/count", channel_id, device_position), vec![
                    OscType::Int(count as i32),
                ])
            }
            EngineStatus::PluginStateSaved { channel_id, device_position, state_base64 } => {
                ("/plugin/state/saved".to_string(), vec![
                    OscType::Int(channel_id as i32),
                    OscType::Int(device_position as i32),
                    OscType::String(state_base64),
                ])
            }
            EngineStatus::PluginParameterValueChanged { channel_id, device_position, param_id, value } => {
                let addr = format!("/channel/{}/device/{}/param/{}/value", channel_id, device_position, param_id);
                info!("📡 Sending OSC: {} [{}]", addr, value);
                (addr, vec![OscType::Float(value)])
            }
            EngineStatus::LogMessage { level, message } => {
                ("/log".to_string(), vec![
                    OscType::String(level),
                    OscType::String(message),
                ])
            }
        };

        let msg = OscMessage {
            addr,
            args,
        };

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
