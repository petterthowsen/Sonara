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
use std::time::Duration;
use tracing::{error, info, warn};
use serde::{Deserialize, Serialize};

use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use clack_extensions::gui::{PluginGui, GuiConfiguration, GuiApiType};

// Import shared memory types from the engine crate
use engine::audio::devices::clap_host::shared_memory::SharedMemory;
use engine::audio::devices::clap_host::ipc_protocol::SharedMemoryLayout;

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

// Minimal host implementation for subprocess
struct SubprocessHost;

impl HostHandlers for SubprocessHost {
    type Shared<'s> = ();
    type MainThread<'a> = ();
    type AudioProcessor<'a> = ();
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
    let mut output_events = OutputEvents::void();
    
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
                                let resp_json = serde_json::to_string(&resp)?;
                                writeln!(stream, "{}", resp_json)?;
                                stream.flush()?;
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
        
        // Process audio and GUI callbacks (separate from command handling)
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
            
            // Process GUI callbacks if plugin is open
            if state.gui_open {
                // This is the critical call that keeps plugin GUIs responsive
                state.instance.call_on_main_thread_callback();
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
            let (bundle, instance) = match load_plugin(&plugin_path, &plugin_id, sample_rate, max_buffer_size) {
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
                gui_open: false,
                activated: false,
                processing: false,
                sample_rate,
                max_buffer_size,
                audio_processor: None,
                shared_memory,
                input_buffers,
                output_buffers,
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
            if let Some(ref mut state) = plugin_state {
                if state.gui_open {
                    return Some(PluginResponse::GuiOpened);
                }
                
                match open_plugin_gui(&mut state.instance) {
                    Ok(()) => {
                        state.gui_open = true;
                        info!("✅ GUI opened successfully");
                        Some(PluginResponse::GuiOpened)
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
) -> Result<(PluginBundle, PluginInstance<SubprocessHost>), String> {
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
        "https://github.com/sonara",
        "0.1.0"
    ).map_err(|e| format!("Failed to create host info: {:?}", e))?;
    
    let plugin_id_cstr = descriptor.id()
        .ok_or_else(|| "Missing plugin ID".to_string())?;
    
    // Create plugin instance
    let instance = PluginInstance::<SubprocessHost>::new(
        |_| (),
        |_| (),
        &bundle,
        plugin_id_cstr,
        &host_info
    ).map_err(|e| format!("Failed to create plugin instance: {:?}", e))?;
    
    info!("Plugin loaded successfully");
    Ok((bundle, instance))
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

