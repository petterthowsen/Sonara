//! Plugin Host Subprocess
//!
//! This is a separate executable that loads and hosts a single CLAP plugin.
//! It communicates with the main Sonara engine via IPC (Unix sockets + shared memory).
//!
//! **Responsibilities:**
//! - Load CLAP plugin library
//! - Initialize and activate plugin
//! - Process audio from shared memory ring buffers
//! - Handle MIDI events from shared queue
//! - Manage plugin GUI and event loop
//! - Respond to commands from engine
//!
//! **Benefits:**
//! - Crash isolation: Plugin crash doesn't kill DAW
//! - GUI isolation: Each plugin has its own event loop
//! - Resource management: Can restart individual plugins
//! - Security: Sandboxing between plugins and engine

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant};
use std::sync::{Arc, Mutex};
use std::collections::HashMap;
use tracing::{error, info, warn};
use serde::{Deserialize, Serialize};

use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use clack_extensions::gui::{PluginGui, GuiConfiguration, GuiApiType, HostGui, HostGuiImpl, GuiSize};
use clack_extensions::timer::{HostTimer, HostTimerImpl, PluginTimer};
use clack_extensions::params::{PluginParams, ParamInfoBuffer};

// Import shared memory types from the engine crate
use engine::audio::ipc::{SharedMemory, SharedMemoryLayout};

// IPC Protocol types (duplicated here for the subprocess binary)
#[derive(Debug, Clone, Serialize, Deserialize)]
enum PluginCommand {
    Initialize {
        plugin_path: PathBuf,
        plugin_id: String,
        sample_rate: f32,
        max_buffer_size: usize,
        shm_name: String,
    },
    Activate,
    Deactivate,
    StartProcessing,
    StopProcessing,
    SetParameter { param_id: u32, value: f32 },
    GetParameter { param_id: u32 },
    GetParameterInfo,
    OpenGui,
    CloseGui,
    HasGui,
    SaveState,
    LoadState { state_base64: String },
    Reset,
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
enum PluginResponse {
    InitializeSuccess {
        device_name: String,
        device_vendor: String,
        device_version: String,
        category: String,
    },
    InitializeError { error: String },
    ActivateResult { success: bool, error: Option<String> },
    DeactivateResult { success: bool, error: Option<String> },
    ProcessingStarted,
    ProcessingStopped,
    ParameterValue { param_id: u32, value: f32 },
    ParameterInfo { params: Vec<PluginParameterInfo> },
    GuiOpened,
    GuiClosed,
    HasGuiResponse { supported: bool },
    GuiError { error: String },
    StateSaved { state_base64: String },
    StateLoadResult { success: bool, error: Option<String> },
    ResetComplete,
    Error { command: String, error: String },
    ShutdownAck,
    ParameterValueChanged { param_id: u32, value: f32 },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PluginParameterInfo {
    id: u32,
    name: String,
    unit: String,
    min: f32,
    max: f32,
    default: f32,
    is_automation_safe: bool,
}

// Host implementation for subprocess with GUI support
struct SubprocessHost;

/// Shared state accessible by all plugin threads
#[derive(Clone)]
struct SubprocessHostShared {
    timers: Arc<Mutex<HashMap<clack_extensions::timer::TimerId, Timer>>>,
    next_timer_id: Arc<Mutex<u32>>,
}

impl SubprocessHostShared {
    fn new() -> Self {
        Self {
            timers: Arc::new(Mutex::new(HashMap::new())),
            next_timer_id: Arc::new(Mutex::new(0)),
        }
    }
    
    /// Tick all timers and return list of IDs that should fire
    fn tick_timers(&self) -> Vec<clack_extensions::timer::TimerId> {
        let now = Instant::now();
        let mut timers = self.timers.lock().unwrap();
        timers
            .values_mut()
            .filter_map(|timer| {
                if timer.tick(now) {
                    Some(timer.id)
                } else {
                    None
                }
            })
            .collect()
    }
}

/// A single timer instance
struct Timer {
    id: clack_extensions::timer::TimerId,
    interval: Duration,
    last_triggered: Option<Instant>,
}

impl Timer {
    fn new(id: clack_extensions::timer::TimerId, interval: Duration) -> Self {
        Self {
            id,
            interval,
            last_triggered: None,
        }
    }
    
    /// Returns true if timer should fire
    fn tick(&mut self, now: Instant) -> bool {
        match self.last_triggered {
            None => {
                self.last_triggered = Some(now);
                true
            }
            Some(last) => {
                if now.duration_since(last) >= self.interval {
                    self.last_triggered = Some(now);
                    true
                } else {
                    false
                }
            }
        }
    }
}

impl HostHandlers for SubprocessHost {
    type Shared<'s> = SubprocessHostShared;
    type MainThread<'a> = SubprocessHostMainThread<'a>;
    type AudioProcessor<'a> = ();
    
    fn declare_extensions(builder: &mut HostExtensions<Self>, _shared: &Self::Shared<'_>) {
        // Register extensions required by many plugins (e.g., DPF-based plugins)
        builder.register::<HostGui>();
        builder.register::<HostTimer>();
    }
}

/// Main thread state - holds mutable timer data
struct SubprocessHostMainThread<'a> {
    shared: &'a SubprocessHostShared,
}

impl<'a> MainThreadHandler<'a> for SubprocessHostMainThread<'a> {
    // No main thread callbacks needed
}

impl<'a> SharedHandler<'a> for SubprocessHostShared {
    fn request_restart(&self) {
        // We don't support runtime restart
        info!("Plugin requested restart (not supported)");
    }

    fn request_process(&self) {
        // We're already processing continuously
    }

    fn request_callback(&self) {
        // Main thread callbacks are called continuously in our event loop
    }
}

impl HostGuiImpl for SubprocessHostShared {
    fn resize_hints_changed(&self) {
        // We don't support resize hints
        info!("Plugin GUI resize hints changed");
    }

    fn request_resize(&self, new_size: GuiSize) -> Result<(), HostError> {
        info!("Plugin GUI requested resize to {}x{}", new_size.width, new_size.height);
        // For floating windows, the plugin manages its own window size
        Ok(())
    }

    fn request_show(&self) -> Result<(), HostError> {
        info!("Plugin GUI requested show");
        Ok(())
    }

    fn request_hide(&self) -> Result<(), HostError> {
        info!("Plugin GUI requested hide");
        Ok(())
    }

    fn closed(&self, was_destroyed: bool) {
        info!("Plugin GUI closed (destroyed: {})", was_destroyed);
    }
}

impl HostTimerImpl for SubprocessHostMainThread<'_> {
    fn register_timer(&mut self, period_ms: u32) -> Result<clack_extensions::timer::TimerId, HostError> {
        // Clamp to reasonable range (10ms minimum for performance)
        let period_ms = period_ms.max(10);
        let interval = Duration::from_millis(period_ms as u64);
        
        let mut next_id = self.shared.next_timer_id.lock().unwrap();
        *next_id += 1;
        let timer_id = clack_extensions::timer::TimerId(*next_id);
        drop(next_id);
        
        let timer = Timer::new(timer_id, interval);
        self.shared.timers.lock().unwrap().insert(timer_id, timer);
        
        info!("Registered timer {} with interval {}ms", timer_id.0, period_ms);
        Ok(timer_id)
    }

    fn unregister_timer(&mut self, timer_id: clack_extensions::timer::TimerId) -> Result<(), HostError> {
        if self.shared.timers.lock().unwrap().remove(&timer_id).is_some() {
            info!("Unregistered timer {}", timer_id.0);
            Ok(())
        } else {
            Err(HostError::Message("Unknown timer ID"))
        }
    }
}

/// Receive a file descriptor from a Unix domain socket
fn recv_fd_from_socket(socket: &std::os::unix::net::UnixStream) -> Result<i32, String> {
    use nix::sys::socket::{recvmsg, ControlMessageOwned, MsgFlags};
    use nix::cmsg_space;
    use std::io::IoSliceMut;
    use std::os::unix::io::AsRawFd;
    
    let mut data = [0u8; 1];
    let mut iov = [IoSliceMut::new(&mut data)];
    let mut cmsg_space = cmsg_space!([i32; 1]);
    
    let msg = recvmsg::<()>(
        socket.as_raw_fd(),
        &mut iov,
        Some(&mut cmsg_space),
        MsgFlags::empty(),
    ).map_err(|e| format!("Failed to receive FD: {}", e))?;
    
    // Parse control messages
    for cmsg in msg.cmsgs().map_err(|e| format!("Failed to parse control messages: {}", e))? {
        if let ControlMessageOwned::ScmRights(fds) = cmsg {
            if let Some(&fd) = fds.first() {
                return Ok(fd);
            }
        }
    }
    
    Err("No file descriptor received".to_string())
}

fn main() {
    // Initialize logging
    tracing_subscriber::fmt()
        .with_env_filter("plugin_host=debug,engine=debug")
        .with_target(false)
        .with_thread_ids(true)
        .init();

    info!("🔌 Plugin Host Subprocess starting...");

    // Parse command line arguments
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        error!("Usage: plugin_host <control_socket_port> <unix_socket_fd>");
        std::process::exit(1);
    }

    let port: u16 = args[1].parse().expect("Invalid port number");
    let unix_socket_fd: i32 = args[2].parse().expect("Invalid Unix socket FD");

    // Connect to control socket
    let socket_addr = format!("127.0.0.1:{}", port);
    info!("Connecting to control socket: {}", socket_addr);

    let stream = match TcpStream::connect(&socket_addr) {
        Ok(s) => {
            info!("✅ Connected to control socket");
            s
        }
        Err(e) => {
            error!("Failed to connect to control socket: {}", e);
            std::process::exit(1);
        }
    };

    // Run plugin host event loop
    if let Err(e) = run_plugin_host(stream, unix_socket_fd) {
        error!("Plugin host error: {}", e);
        std::process::exit(1);
    }

    info!("Plugin host subprocess exiting");
}

/// Plugin state container
struct PluginState {
    bundle: PluginBundle,
    instance: PluginInstance<SubprocessHost>,
    shared: Arc<SubprocessHostShared>,
    gui_open: bool,
    activated: bool,
    processing: bool,
    sample_rate: f32,
    max_buffer_size: usize,
    audio_processor: Option<PluginAudioProcessorEnum<SubprocessHost>>,
    shared_memory: Option<SharedMemory>,
    
    // Audio processing buffers
    input_buffers: Vec<Vec<f32>>,
    output_buffers: Vec<Vec<f32>>,
    
    // Event buffer for plugin output events (parameter changes, etc.)
    output_event_buffer: EventBuffer,
    
    // Pending parameter changes (param_id, clap_id, denormalized_value)
    pending_param_changes: Vec<(u32, ClapId, f64)>,
}

/// Process output events from the plugin (parameter changes, etc.)
fn process_output_events(state: &mut PluginState) {
    use clack_host::events::event_types::ParamValueEvent;
    
    // Iterate through events in the output buffer
    for event in state.output_event_buffer.iter() {
        // Check if this is a parameter value event
        if let Some(param_event) = event.as_event::<ParamValueEvent>() {
            let Some(clap_id) = param_event.param_id() else {
                continue;  // Skip events without valid param ID
            };
            let value = param_event.value();
            
            // Store for sending to main process
            // (param_id, clap_id, denormalized_value)
            state.pending_param_changes.push((u32::MAX, clap_id, value));
            
            info!("Plugin changed parameter (CLAP ID: {:?}) to {:.4}", clap_id, value);
        }
    }
}

/// Check if there's audio data available to process
fn has_audio_to_process(state: &PluginState) -> bool {
    let Some(ref shm) = state.shared_memory else {
        return false;
    };
    
    // Process if we have any reasonable amount of data (at least 64 samples = ~1.5ms at 44.1kHz)
    let min_samples = 64 * 2; // Stereo
    
    let input_buffer = shm.input_buffer();
    let available = input_buffer.available();
    
    // Process eagerly to avoid buffer overflow
    available >= min_samples
}

/// Process audio from shared memory through the plugin
/// Called periodically from main event loop
fn process_audio(state: &mut PluginState) {
    // Only process if we have an active processor and shared memory
    let Some(ref mut processor) = state.audio_processor else {
        return;
    };
    
    let Some(ref mut shm) = state.shared_memory else {
        return;
    };
    
    // Only process if in Started state
    let PluginAudioProcessorEnum::Started(ref mut started_processor) = processor else {
        return;
    };
    
    // Process whatever is available, up to a reasonable chunk size
    let max_chunk_size = 512.min(state.max_buffer_size);
    
    // Check how much data is available
    let mut input_buffer = shm.input_buffer();
    let available = input_buffer.available();
    
    if available < 128 {
        // Too little data, skip to avoid overhead
        return;
    }
    
    // Process up to max_chunk_size samples, but no more than what's available
    let samples_to_process = available.min(max_chunk_size * 2); // Stereo
    let chunk_size = samples_to_process / 2; // Convert back to mono samples
    
    // Read input audio from shared memory ring buffer (interleaved stereo)
    let mut interleaved_input = vec![0.0f32; samples_to_process];
    let read = input_buffer.read(&mut interleaved_input);
    drop(input_buffer); // Release borrow
    
    if read < samples_to_process {
        // Fill remainder with silence if we didn't get enough
        interleaved_input[read..].fill(0.0);
    }
    
    // Deinterleave: convert interleaved (L, R, L, R) to separate channels
    for i in 0..chunk_size {
        state.input_buffers[0][i] = interleaved_input[i * 2];     // Left
        state.input_buffers[1][i] = interleaved_input[i * 2 + 1]; // Right
    }
    
    // Clear output buffers
    for channel in &mut state.output_buffers {
        channel[..chunk_size].fill(0.0);
    }
    
    // Build CLAP audio structures (need to store ports in state for proper lifetime)
    // For now, create temporary ports each time (not ideal but works)
    let mut input_ports = AudioPorts::with_capacity(2, 1);  // 2 channels, 1 port
    let mut output_ports = AudioPorts::with_capacity(2, 1);
    
    let input_audio = input_ports.with_input_buffers([AudioPortBuffer {
        latency: 0,
        channels: AudioPortBufferType::f32_input_only(
            state.input_buffers.iter_mut()
                .map(|b| InputChannel::constant(&mut b[..chunk_size]))
        )
    }]);
    
    let mut output_audio = output_ports.with_output_buffers([AudioPortBuffer {
        latency: 0,
        channels: AudioPortBufferType::f32_output_only(
            state.output_buffers.iter_mut()
                .map(|b| &mut b[..chunk_size])
        )
    }]);
    
    // Process MIDI events (TODO: Read from shared memory MIDI queue)
    let input_events = InputEvents::empty();
    let mut output_events = OutputEvents::from_buffer(&mut state.output_event_buffer);
    
    // Process audio through plugin
    match started_processor.process(
        &input_audio,
        &mut output_audio,
        &input_events,
        &mut output_events,
        None,
        None,
    ) {
        Ok(_) => {
            // Interleave output: convert separate channels to interleaved (L, R, L, R)
            let mut interleaved_output = vec![0.0f32; samples_to_process];
            for i in 0..chunk_size {
                interleaved_output[i * 2] = state.output_buffers[0][i];     // Left
                interleaved_output[i * 2 + 1] = state.output_buffers[1][i]; // Right
            }
            
            // Write output audio to shared memory ring buffer
            let mut output_buffer = shm.output_buffer();
            let written = output_buffer.write(&interleaved_output);
            
            if written < interleaved_output.len() {
                // Output buffer is full, this might cause audio glitches
                warn!("Output buffer full: wrote {}/{} samples", written, interleaved_output.len());
            }
        }
        Err(e) => {
            warn!("Plugin processing error: {:?}", e);
        }
    }
    
    // Process output events to detect parameter changes
    // These are sent back to the main process for UI updates
    process_output_events(state);
    
    // Clear event buffer for next iteration
    state.output_event_buffer.clear();
}

/// Main plugin host event loop
/// 
/// This runs on the main thread and handles both commands and GUI callbacks.
/// We use non-blocking I/O to process commands while continuously calling
/// the plugin's main thread callback for GUI responsiveness.
fn run_plugin_host(mut stream: TcpStream, unix_socket_fd: i32) -> Result<(), Box<dyn std::error::Error>> {
    // Set socket to non-blocking mode
    stream.set_nonblocking(true)?;
    
    let mut plugin_state: Option<PluginState> = None;

    info!("📡 Listening for commands (non-blocking)...");

    // Main event loop: process commands + GUI callbacks + audio processing
    let mut line_buffer = String::new();
    let mut byte_buffer = [0u8; 1];
    
    loop {
        // Try to read commands as fast as possible (prioritize command reading)
        // Read in a tight loop until WouldBlock to minimize latency
        let mut command_received = false;
        loop {
            match stream.read(&mut byte_buffer) {
                Ok(0) => {
                    // Connection closed
                    info!("Control socket closed, shutting down");
                    return Ok(());
                }
                Ok(1) => {
                    let ch = byte_buffer[0] as char;
                    if ch == '\n' {
                        // Complete line received, process it
                        let line = line_buffer.trim();
                        
                        if !line.is_empty() {
                            info!("📨 Raw data received ({} bytes): '{}'", line.len(), line);
                            
                            // Parse command (JSON-encoded)
                            let cmd: PluginCommand = match serde_json::from_str(line) {
                                Ok(c) => c,
                                Err(e) => {
                                    warn!("Failed to parse command '{}': {}", line, e);
                                    line_buffer.clear();
                                    continue;
                                }
                            };
                            
                            info!("📥 Received command: {:?}", cmd);
                            
                            // Check for shutdown
                            if matches!(cmd, PluginCommand::Shutdown) {
                                info!("Shutdown command received");
                                
                                // Send ack
                                let resp = PluginResponse::ShutdownAck;
                                let resp_json = serde_json::to_string(&resp)?;
                                writeln!(stream, "{}", resp_json)?;
                                stream.flush()?;
                                
                                return Ok(());
                            }
                            
                            // Process command
                            let response = process_command(cmd, &mut plugin_state, unix_socket_fd);
                            
                            if let Some(resp) = response {
                                info!("📤 Sending response: {:?}", resp);
                                let resp_json = serde_json::to_string(&resp)?;
                                info!("📤 Response JSON: {}", resp_json);
                                writeln!(stream, "{}", resp_json)?;
                                stream.flush()?;
                                info!("📤 Response sent and flushed");
                            }
                            
                            command_received = true;
                        }
                        
                        // Clear buffer for next command
                        line_buffer.clear();
                        // Continue reading to check for more commands
                    } else {
                        // Accumulate characters
                        line_buffer.push(ch);
                    }
                }
                Ok(_) => unreachable!("read returned >1 for single byte buffer"),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // No more data available right now, exit read loop
                    break;
                }
                Err(e) => {
                    error!("Socket read error: {}", e);
                    return Err(Box::new(e));
                }
            }
        }
        
        // Process audio, GUI callbacks, and timers (separate from command handling)
        let mut processed_audio = false;
        if let Some(ref mut state) = plugin_state {
            // Process audio if plugin is activated and processing
            // Keep processing in a loop until input buffer is empty
            if state.activated && state.processing {
                // Process audio multiple times to keep up with real-time
                // Process aggressively to minimize latency
                for _ in 0..8 {  // Process up to 8 chunks per iteration
                    if has_audio_to_process(state) {
                        process_audio(state);
                        processed_audio = true;
                    } else {
                        break;
                    }
                }
            }
            
            // Process timers - check which ones need to fire
            let triggered_timers = state.shared.tick_timers();
            if !triggered_timers.is_empty() {
                // Get timer extension and fire callbacks
                let mut handle = state.instance.plugin_handle();
                if let Some(timer_ext) = handle.get_extension::<PluginTimer>() {
                    for timer_id in triggered_timers {
                        timer_ext.on_timer(&mut handle, timer_id);
                    }
                }
            }
            
            // Process GUI callbacks if plugin is open
            // This is the critical call that keeps plugin GUIs responsive
            if state.gui_open {
                state.instance.call_on_main_thread_callback();
                
                // Poll for parameter changes from the GUI even when not processing audio
                // This is critical: GUI parameter changes are only visible through output events,
                // but we only collect output events during process() or flush() calls
                let mut handle = state.instance.plugin_handle();
                if let Some(params_ext) = handle.get_extension::<PluginParams>() {
                    use clack_host::events::io::{InputEvents, OutputEvents};
                    
                    let input_events = InputEvents::empty();
                    let mut output_events = OutputEvents::from_buffer(&mut state.output_event_buffer);
                    
                    // Flush with empty input to collect any pending output events from GUI
                    params_ext.flush(&mut handle, &input_events, &mut output_events);
                    
                    // Process the collected output events
                    process_output_events(state);
                    state.output_event_buffer.clear();
                }
            }
            
            // Send pending parameter changes back to main process
            if !state.pending_param_changes.is_empty() {
                // Get parameter extension to map CLAP IDs to sequential param_ids
                let mut handle = state.instance.plugin_handle();
                if let Some(params_ext) = handle.get_extension::<PluginParams>() {
                    let param_count = params_ext.count(&mut handle);
                    
                    // Process each pending change
                    for (_placeholder_id, clap_id, denormalized_value) in state.pending_param_changes.drain(..) {
                        // Find sequential param_id by iterating through parameters
                        let mut param_id_opt = None;
                        let mut param_info_opt = None;
                        
                        for i in 0..param_count {
                            let mut buffer = ParamInfoBuffer::new();
                            if let Some(info) = params_ext.get_info(&mut handle, i, &mut buffer) {
                                if info.id == clap_id {
                                    param_id_opt = Some(i);
                                    param_info_opt = Some((info.min_value, info.max_value));
                                    break;
                                }
                            }
                        }
                        
                        if let (Some(param_id), Some((min_val, max_val))) = (param_id_opt, param_info_opt) {
                            // Normalize value from plugin's range to 0.0-1.0
                            let range = max_val - min_val;
                            let normalized = if range.abs() > f64::EPSILON {
                                ((denormalized_value - min_val) / range).clamp(0.0, 1.0) as f32
                            } else {
                                0.5
                            };
                            
                            // Send ParameterValueChanged response
                            let resp = PluginResponse::ParameterValueChanged {
                                param_id,
                                value: normalized,
                            };
                            
                            if let Ok(resp_json) = serde_json::to_string(&resp) {
                                if let Err(e) = writeln!(stream, "{}", resp_json) {
                                    warn!("Failed to send parameter change: {}", e);
                                } else if let Err(e) = stream.flush() {
                                    warn!("Failed to flush parameter change: {}", e);
                                } else {
                                    info!("📤 Sent ParameterValueChanged: param_id={}, value={:.4}", param_id, normalized);
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Only sleep if we didn't process audio and no command was received
        // This keeps latency low for audio processing
        if !processed_audio && !command_received {
            thread::sleep(Duration::from_millis(1)); // Short sleep (1ms) to avoid busy-waiting
        }
        // If we processed audio or a command, loop immediately
    }

    // Cleanup
    info!("Cleaning up plugin host...");

    Ok(())
}

/// Process a command and return response
fn process_command(
    cmd: PluginCommand,
    plugin_state: &mut Option<PluginState>,
    unix_socket_fd: i32,
) -> Option<PluginResponse> {
    match cmd {
        PluginCommand::Initialize { plugin_path, plugin_id, sample_rate, max_buffer_size, shm_name } => {
            info!("Initializing plugin: {} from {:?}", plugin_id, plugin_path);
            info!("Shared memory name: {}", shm_name);
            
            info!("Step 1: Loading plugin from disk...");
            let (bundle, instance, shared) = match load_plugin(&plugin_path, &plugin_id, sample_rate, max_buffer_size) {
                Ok(result) => {
                    info!("Step 2: Plugin loaded successfully, now creating shared memory...");
                    result
                }
                Err(e) => {
                    error!("Failed to load plugin: {}", e);
                    return Some(PluginResponse::InitializeError { error: e });
                }
            };
            
            // Create shared memory layout
            info!("Step 3: Creating shared memory layout (max_buffer_size={})", max_buffer_size);
            let layout = SharedMemoryLayout::new(max_buffer_size);
            
            // Receive shared memory FD from parent process via Unix socket
            info!("Step 4: Receiving shared memory FD from Unix socket (FD={})", unix_socket_fd);
            use std::os::unix::net::UnixStream;
            use std::os::unix::io::FromRawFd;
            
            let unix_sock = unsafe { UnixStream::from_raw_fd(unix_socket_fd) };
            let shared_memory = match recv_fd_from_socket(&unix_sock) {
                Ok(shm_fd) => {
                    info!("Step 5: Received shared memory FD={}, mapping it...", shm_fd);
                    match SharedMemory::from_fd(shm_fd, layout) {
                        Ok(shm) => {
                            info!("Step 6: ✅ Shared memory mapped successfully!");
                            Some(shm)
                        }
                        Err(e) => {
                            error!("Step 6: ❌ Failed to map shared memory: {}. Continuing without shared memory.", e);
                            None
                        }
                    }
                }
                Err(e) => {
                    error!("Step 5: ❌ Failed to receive shared memory FD: {}. Continuing without shared memory.", e);
                    None
                }
            };
            
            info!("Step 6: Preparing plugin state...");
            // Get plugin metadata
            let device_name = plugin_id.clone();
            let device_vendor = "Unknown".to_string();
            let device_version = "1.0".to_string();
            let category = "effect".to_string();
            
            // Allocate audio buffers (stereo)
            let input_buffers = vec![vec![0.0; max_buffer_size]; 2];
            let output_buffers = vec![vec![0.0; max_buffer_size]; 2];
            
            // Store plugin state
            *plugin_state = Some(PluginState {
                bundle,
                instance,
                shared,
                gui_open: false,
                activated: false,
                processing: false,
                sample_rate,
                max_buffer_size,
                audio_processor: None,
                shared_memory,
                input_buffers,
                output_buffers,
                output_event_buffer: EventBuffer::new(),
                pending_param_changes: Vec::new(),
            });
            
            info!("Step 7: ✅ Plugin state stored, sending InitializeSuccess response");
            Some(PluginResponse::InitializeSuccess {
                device_name,
                device_vendor,
                device_version,
                category,
            })
        }
        
        PluginCommand::OpenGui => {
            info!("📥 Received OpenGui command");
            if let Some(ref mut state) = plugin_state {
                if state.gui_open {
                    info!("GUI already open, returning GuiOpened");
                    return Some(PluginResponse::GuiOpened);
                }
                
                info!("Attempting to open GUI...");
                match open_plugin_gui(&mut state.instance) {
                    Ok(()) => {
                        state.gui_open = true;
                        info!("✅ GUI opened successfully, returning GuiOpened response");
                        Some(PluginResponse::GuiOpened)
                    }
                    Err(e) => {
                        warn!("❌ Failed to open GUI: {}", e);
                        Some(PluginResponse::GuiError { error: e })
                    }
                }
            } else {
                warn!("❌ Cannot open GUI: Plugin not initialized");
                Some(PluginResponse::GuiError {
                    error: "Plugin not initialized".to_string(),
                })
            }
        }
        
        PluginCommand::CloseGui => {
            if let Some(ref mut state) = plugin_state {
                if !state.gui_open {
                    return Some(PluginResponse::GuiClosed);
                }
                
                match close_plugin_gui(&mut state.instance) {
                    Ok(()) => {
                        state.gui_open = false;
                        info!("GUI closed successfully");
                        Some(PluginResponse::GuiClosed)
                    }
                    Err(e) => {
                        Some(PluginResponse::GuiError { error: e })
                    }
                }
            } else {
                Some(PluginResponse::GuiError {
                    error: "Plugin not initialized".to_string(),
                })
            }
        }
        
        PluginCommand::HasGui => {
            let supported = if let Some(ref mut state) = plugin_state {
                has_plugin_gui(&mut state.instance)
            } else {
                false
            };
            Some(PluginResponse::HasGuiResponse { supported })
        }
        
        PluginCommand::Shutdown => {
            // Handled in main loop
            None
        }
        
        PluginCommand::Activate => {
            if let Some(ref mut state) = plugin_state {
                if state.activated {
                    return Some(PluginResponse::ActivateResult {
                        success: true,
                        error: None,
                    });
                }
                
                info!("Activating plugin (sample_rate={}, max_buffer_size={})", 
                    state.sample_rate, state.max_buffer_size);
                
                // Activate plugin with audio configuration
                let config = PluginAudioConfiguration {
                    sample_rate: state.sample_rate as f64,
                    min_frames_count: 1,
                    max_frames_count: state.max_buffer_size as u32,
                };
                
                match state.instance.activate(|_, _| (), config) {
                    Ok(processor) => {
                        // Start processing
                        match processor.start_processing() {
                            Ok(started_processor) => {
                                // Store the processor so we can use it for audio processing
                                state.audio_processor = Some(PluginAudioProcessorEnum::Started(started_processor));
                                state.activated = true;
                                state.processing = true;
                                info!("✅ Plugin activated and processing started");
                                Some(PluginResponse::ActivateResult {
                                    success: true,
                                    error: None,
                                })
                            }
                            Err(e) => {
                                error!("Failed to start processing: {:?}", e);
                                Some(PluginResponse::ActivateResult {
                                    success: false,
                                    error: Some(format!("Failed to start processing: {:?}", e)),
                                })
                            }
                        }
                    }
                    Err(e) => {
                        error!("Failed to activate plugin: {:?}", e);
                        Some(PluginResponse::ActivateResult {
                            success: false,
                            error: Some(format!("{:?}", e)),
                        })
                    }
                }
            } else {
                Some(PluginResponse::ActivateResult {
                    success: false,
                    error: Some("Plugin not initialized".to_string()),
                })
            }
        }
        
        PluginCommand::Deactivate => {
            if let Some(ref mut state) = plugin_state {
                if !state.activated {
                    return Some(PluginResponse::DeactivateResult {
                        success: true,
                        error: None,
                    });
                }
                
                info!("Deactivating plugin");
                
                // Stop processing and deactivate properly
                if let Some(processor) = state.audio_processor.take() {
                    let stopped = match processor {
                        PluginAudioProcessorEnum::Started(started) => started.stop_processing(),
                        _ => {
                            warn!("Plugin processor in invalid state");
                            return Some(PluginResponse::DeactivateResult {
                                success: false,
                                error: Some("Plugin processor in invalid state".to_string()),
                            });
                        }
                    };
                    
                    // Deactivate the plugin
                    state.instance.deactivate(stopped);
                    state.activated = false;
                    state.processing = false;
                    
                    info!("✅ Plugin deactivated successfully");
                    Some(PluginResponse::DeactivateResult {
                        success: true,
                        error: None,
                    })
                } else {
                    // No processor to deactivate
                    state.activated = false;
                    state.processing = false;
                    Some(PluginResponse::DeactivateResult {
                        success: true,
                        error: None,
                    })
                }
            } else {
                Some(PluginResponse::DeactivateResult {
                    success: false,
                    error: Some("Plugin not initialized".to_string()),
                })
            }
        }
        
        PluginCommand::StartProcessing => {
            if let Some(ref mut state) = plugin_state {
                if !state.activated {
                    return Some(PluginResponse::Error {
                        command: "StartProcessing".to_string(),
                        error: "Plugin not activated".to_string(),
                    });
                }
                
                // Processing is started in activate() for now
                state.processing = true;
                info!("✅ Plugin processing started");
                Some(PluginResponse::ProcessingStarted)
            } else {
                Some(PluginResponse::Error {
                    command: "StartProcessing".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }
        
        PluginCommand::StopProcessing => {
            if let Some(ref mut state) = plugin_state {
                if state.processing {
                    // Processing will be stopped in deactivate() for now
                    state.processing = false;
                    info!("Plugin processing stopped");
                }
                Some(PluginResponse::ProcessingStopped)
            } else {
                Some(PluginResponse::Error {
                    command: "StopProcessing".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }
        
        PluginCommand::Reset => {
            // Reset is typically a no-op for plugins
            // Just acknowledge it
            None
        }
        
        PluginCommand::GetParameterInfo => {
            if let Some(ref mut state) = plugin_state {
                // Get plugin handle to query parameters
                let mut handle = state.instance.plugin_handle();
                
                // Try to get the params extension
                let params_ext: Option<PluginParams> = handle.get_extension();
                
                if let Some(params) = params_ext {
                    let param_count = params.count(&mut handle);
                    let mut param_infos = Vec::with_capacity(param_count as usize);
                    
                    // Query each parameter
                    for i in 0..param_count {
                        let mut buffer = ParamInfoBuffer::new();
                        
                        if let Some(clap_info) = params.get_info(&mut handle, i, &mut buffer) {
                            let name = std::str::from_utf8(clap_info.name)
                                .unwrap_or("Unknown")
                                .trim_end_matches('\0')
                                .to_string();
                            
                            let param_info = PluginParameterInfo {
                                id: i, // Use sequential index as ID
                                name,
                                unit: String::new(), // CLAP doesn't expose units separately
                                min: clap_info.min_value as f32,
                                max: clap_info.max_value as f32,
                                default: clap_info.default_value as f32,
                                is_automation_safe: clap_info.flags.contains(
                                    clack_extensions::params::ParamInfoFlags::IS_AUTOMATABLE
                                ),
                            };
                            
                            param_infos.push(param_info);
                        }
                    }
                    
                    info!("✅ Queried {} parameters from plugin", param_infos.len());
                    Some(PluginResponse::ParameterInfo { params: param_infos })
                } else {
                    info!("Plugin does not support params extension");
                    Some(PluginResponse::ParameterInfo { params: Vec::new() })
                }
            } else {
                Some(PluginResponse::Error {
                    command: "GetParameterInfo".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }
        
        PluginCommand::GetParameter { param_id } => {
            if let Some(ref mut state) = plugin_state {
                // Get plugin handle
                let mut handle = state.instance.plugin_handle();
                
                // Try to get the params extension
                let params_ext: Option<PluginParams> = handle.get_extension();
                
                if let Some(params) = params_ext {
                    // First, get parameter info to get the CLAP ID
                    let mut buffer = ParamInfoBuffer::new();
                    
                    if let Some(clap_info) = params.get_info(&mut handle, param_id, &mut buffer) {
                        let clap_id = clap_info.id;
                        
                        // Get the current value
                        if let Some(value) = params.get_value(&mut handle, clap_id) {
                            // Normalize value to 0.0-1.0 range
                            let normalized = ((value - clap_info.min_value) / 
                                             (clap_info.max_value - clap_info.min_value)) as f32;
                            
                            Some(PluginResponse::ParameterValue {
                                param_id,
                                value: normalized.clamp(0.0, 1.0),
                            })
                        } else {
                            Some(PluginResponse::Error {
                                command: "GetParameter".to_string(),
                                error: format!("Failed to get value for parameter {}", param_id),
                            })
                        }
                    } else {
                        Some(PluginResponse::Error {
                            command: "GetParameter".to_string(),
                            error: format!("Parameter {} not found", param_id),
                        })
                    }
                } else {
                    Some(PluginResponse::Error {
                        command: "GetParameter".to_string(),
                        error: "Plugin does not support params extension".to_string(),
                    })
                }
            } else {
                Some(PluginResponse::Error {
                    command: "GetParameter".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }
        
        PluginCommand::SetParameter { param_id, value } => {
            if let Some(ref mut state) = plugin_state {
                // Get plugin handle
                let mut handle = state.instance.plugin_handle();
                
                // Try to get the params extension
                let params_ext: Option<PluginParams> = handle.get_extension();
                
                if let Some(params) = params_ext {
                    // Get parameter info to denormalize the value
                    let mut buffer = ParamInfoBuffer::new();
                    
                    if let Some(clap_info) = params.get_info(&mut handle, param_id, &mut buffer) {
                        let clap_id = clap_info.id;
                        
                        // Denormalize from 0.0-1.0 to actual parameter range
                        let denormalized = clap_info.min_value + 
                            (value as f64 * (clap_info.max_value - clap_info.min_value));
                        
                        info!("Queuing parameter change: {} = {} (denormalized: {:.2})", 
                            param_id, value, denormalized);
                        
                        // Queue the parameter change to be applied in the next flush/process call
                        state.pending_param_changes.push((param_id, clap_id, denormalized));
                        
                        // Immediately flush to the plugin if not processing
                        // This ensures parameter changes are applied even when audio isn't running
                        use clack_host::events::event_types::ParamValueEvent;
                        use clack_host::events::Pckn;
                        use clack_host::utils::Cookie;
                        use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};
                        
                        let mut input_events = EventBuffer::new();
                        let event = ParamValueEvent::new(
                            0,  // Sample offset
                            clap_id,
                            Pckn::new(0u16, 0u16, 0u16, 0u32),
                            denormalized,
                            Cookie::empty()
                        );
                        input_events.push(&event);
                        
                        let mut output_events = EventBuffer::new();
                        let input_events_view = InputEvents::from_buffer(&input_events);
                        let mut output_events_view = OutputEvents::from_buffer(&mut output_events);
                        
                        // Use flush to immediately apply parameter change
                        params.flush(&mut handle, &input_events_view, &mut output_events_view);
                        
                        None // No response needed (fire-and-forget)
                    } else {
                        Some(PluginResponse::Error {
                            command: "SetParameter".to_string(),
                            error: format!("Parameter {} not found", param_id),
                        })
                    }
                } else {
                    Some(PluginResponse::Error {
                        command: "SetParameter".to_string(),
                        error: "Plugin does not support params extension".to_string(),
                    })
                }
            } else {
                Some(PluginResponse::Error {
                    command: "SetParameter".to_string(),
                    error: "Plugin not initialized".to_string(),
                })
            }
        }
        
        _ => {
            // TODO: Implement remaining commands
            warn!("Command not yet implemented: {:?}", cmd);
            Some(PluginResponse::Error {
                command: format!("{:?}", cmd),
                error: "Not implemented".to_string(),
            })
        }
    }
}

/// Load a CLAP plugin
fn load_plugin(
    plugin_path: &PathBuf,
    plugin_id: &str,
    _sample_rate: f32,
    _max_buffer_size: usize,
) -> Result<(PluginBundle, PluginInstance<SubprocessHost>, Arc<SubprocessHostShared>), String> {
    // Load bundle
    let bundle = unsafe {
        PluginBundle::load(plugin_path)
            .map_err(|e| format!("Failed to load bundle: {:?}", e))?
    };
    
    // Find plugin descriptor
    let factory = bundle.get_plugin_factory()
        .ok_or_else(|| "No plugin factory".to_string())?;
    
    let descriptor = factory.plugin_descriptors()
        .find(|d| {
            d.id()
                .and_then(|id| id.to_str().ok())
                .map(|id| id == plugin_id)
                .unwrap_or(false)
        })
        .ok_or_else(|| format!("Plugin {} not found in bundle", plugin_id))?;
    
    // Create host info
    let host_info = HostInfo::new(
        "Sonara Plugin Host",
        "Sonara Project",
        "https://thowsenmedia.itch.io/sonara",
        "0.1.0"
    ).map_err(|e| format!("Failed to create host info: {:?}", e))?;
    
    let plugin_id_cstr = descriptor.id()
        .ok_or_else(|| "Missing plugin ID".to_string())?;
    
    // Create shared state for timer and GUI support
    let shared = Arc::new(SubprocessHostShared::new());
    let shared_for_instance = Arc::clone(&shared);
    
    // Create plugin instance
    let instance = PluginInstance::<SubprocessHost>::new(
        move |_| shared_for_instance.as_ref().clone(),  // Clone the shared state for plugin
        |shared_ref| SubprocessHostMainThread { shared: shared_ref },  // Main thread state
        &bundle,
        plugin_id_cstr,
        &host_info
    ).map_err(|e| format!("Failed to create plugin instance: {:?}", e))?;
    
    info!("Plugin loaded successfully");
    Ok((bundle, instance, shared))
}

/// Open plugin GUI
fn open_plugin_gui(instance: &mut PluginInstance<SubprocessHost>) -> Result<(), String> {
    let mut handle = instance.plugin_handle();
    
    let Some(gui_ext): Option<PluginGui> = handle.get_extension() else {
        return Err("Plugin does not support GUI extension".to_string());
    };
    
    let Some(api_type) = GuiApiType::default_for_current_platform() else {
        return Err("No GUI API available for current platform".to_string());
    };
    
    let config = GuiConfiguration {
        api_type,
        is_floating: true,
    };
    
    if !gui_ext.is_api_supported(&mut handle, config) {
        return Err(format!("Plugin does not support {:?} GUI API", api_type));
    }
    
    gui_ext.create(&mut handle, config)
        .map_err(|e| format!("Failed to create GUI: {}", e))?;
    
    let title = std::ffi::CString::new("Plugin - Sonara").unwrap();
    gui_ext.suggest_title(&mut handle, &title);
    
    gui_ext.show(&mut handle)
        .map_err(|e| format!("Failed to show GUI: {}", e))?;
    
    info!("Plugin GUI opened");
    Ok(())
}

/// Close plugin GUI
fn close_plugin_gui(instance: &mut PluginInstance<SubprocessHost>) -> Result<(), String> {
    let mut handle = instance.plugin_handle();
    
    let Some(gui_ext): Option<PluginGui> = handle.get_extension() else {
        return Ok(()); // No GUI, nothing to close
    };
    
    let _ = gui_ext.hide(&mut handle);
    gui_ext.destroy(&mut handle);
    
    info!("Plugin GUI closed");
    Ok(())
}

/// Check if plugin has GUI
fn has_plugin_gui(instance: &mut PluginInstance<SubprocessHost>) -> bool {
    let handle = instance.plugin_handle();
    handle.get_extension::<PluginGui>().is_some()
}

// Note: GUI event loop is now integrated into the main loop
// The main thread continuously calls plugin.call_on_main_thread_callback()
// while processing commands in a non-blocking manner.
// This is the proper solution for CLAP plugins that require main thread processing.

