# Plugin Hosting Architecture

## Overview

Sonara implements **subprocess-based CLAP plugin hosting** for crash isolation, GUI support, and security. Each plugin runs in its own process and communicates with the main engine via IPC (Inter-Process Communication).

## Recent Changes (October 2024)

### ✅ Plugin Parameter Control Implemented
- **Feature**: Full parameter get/set/query functionality for CLAP plugins
- **Implementation**:
  - `GetParameterInfo` command queries all parameters from plugin via CLAP params extension
  - `GetParameter` retrieves current normalized values (0.0-1.0)
  - `SetParameter` sets parameter values with immediate flush (works even when audio stopped)
  - Parameters cached in `SubprocessClapAdapter` for fast access
  - Automatic normalization to 0.0-1.0 range (consistent with builtin devices)
- **Race Condition Fix**:
  - **Issue**: Godot would query parameters before background thread finished caching them
  - **Solution**: Added `DeviceReady` command sent when plugin finishes loading
  - Engine automatically re-sends parameter info to Godot when ready
- **Result**: All plugin parameters now appear in Godot UI and are fully controllable

### ✅ Plugin GUI Support Fixed  
- **Issue**: DPF-based plugins crashed with `hostGui != nullptr` and `hostTimer != nullptr` assertions
- **Root Cause**: Minimal `SubprocessHost` implementation missing required CLAP extensions
- **Solution**:
  - Added `HostGui` extension with `HostGuiImpl` trait on `SubprocessHostShared`
  - Added `HostTimer` extension with `HostTimerImpl` trait on `SubprocessHostMainThread`
  - Integrated timer processing into main event loop (fires callbacks every ~1ms)
  - Fixed GUI command routing in `commands.rs` to recognize `SubprocessClapAdapter`
- **Result**: Plugin GUIs now open successfully in floating windows with proper animations

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     Main Engine Process                      │
│                                                               │
│  ┌────────────────┐         ┌──────────────────┐            │
│  │ Audio Thread   │◄────────┤ Command Channel  │            │
│  │ (Real-time)    │         │ (Crossbeam MPMC) │            │
│  └────────┬───────┘         └────────▲─────────┘            │
│           │                          │                       │
│           │ process_block()          │ OSC Commands          │
│           ▼                          │                       │
│  ┌────────────────────┐     ┌───────┴────────┐             │
│  │ SubprocessClap     │     │ OSC Server      │             │
│  │ Adapter            │     │ (Port 7000)     │             │
│  └────────┬───────────┘     └─────────────────┘             │
│           │                                                  │
│           │ Shared Memory (Audio/MIDI Ring Buffers)         │
│           ▼                                                  │
│  ┌─────────────────────────────────────────────┐            │
│  │         Shared Memory (memfd_create)        │            │
│  │  ┌─────────────┐  ┌─────────────┐          │            │
│  │  │Input Buffer │  │Output Buffer│          │            │
│  │  │(Ring)       │  │(Ring)       │          │            │
│  │  └─────────────┘  └─────────────┘          │            │
│  │  ┌─────────────┐                            │            │
│  │  │MIDI Queue   │                            │            │
│  │  └─────────────┘                            │            │
│  └─────────────────────────────────────────────┘            │
│           ▲                                                  │
└───────────┼──────────────────────────────────────────────────┘
            │
            │ FD passed via SCM_RIGHTS
            │ Commands via TCP socket
            │
┌───────────┼──────────────────────────────────────────────────┐
│           │          Plugin Subprocess                       │
│           │                                                  │
│  ┌────────▼───────────┐                                     │
│  │  Shared Memory     │                                     │
│  │  (mmap from FD)    │                                     │
│  └────────┬───────────┘                                     │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────────┐      ┌──────────────┐             │
│  │  Event Loop         │◄─────┤ TCP Socket   │             │
│  │  - Process audio    │      │ (Commands)   │             │
│  │  - Process commands │      └──────────────┘             │
│  │  - GUI callbacks    │                                    │
│  └─────────┬───────────┘                                    │
│            │                                                 │
│            ▼                                                 │
│  ┌─────────────────────┐                                    │
│  │  CLAP Plugin        │                                    │
│  │  (via clack)        │                                    │
│  └─────────────────────┘                                    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Key Components

### 1. Process Manager (`process_manager.rs`)

**Responsibilities:**
- Spawning plugin host subprocesses
- Managing TCP control sockets
- Creating and passing shared memory file descriptors
- Monitoring subprocess health

**Key Implementation Details:**

```rust
// Spawning sequence:
1. Create TCP listener on unique port (9000+)
2. Create Unix socket pair for FD passing
3. Spawn subprocess with:
   - TCP port as arg 1
   - Unix socket FD (3) as arg 2
4. In child pre_exec:
   - dup2() Unix socket to FD 3
   - Clear FD_CLOEXEC flag
5. Create shared memory (memfd_create)
6. Send shared memory FD via Unix socket (SCM_RIGHTS)
7. Wait for subprocess TCP connection
8. Send Initialize command via TCP
```

### 2. Subprocess Adapter (`subprocess_adapter.rs`)

**Responsibilities:**
- Interfacing with the audio engine's device system
- Managing plugin loading state (async initialization)
- Reading/writing shared memory ring buffers
- Non-blocking command sending
- GUI control (open/close/has_gui methods)

**Key Features:**
- **Async Loading**: Plugin loads in background thread to avoid blocking audio
- **Lock-free Audio Path**: Uses `try_lock()` to never block audio thread
- **Fire-and-forget Commands**: Reset/SetParameter don't wait for responses
- **Three States**: Loading → Ready → Failed
- **GUI Methods**: `open_gui()`, `close_gui()`, `has_gui()`, `is_gui_open()`

### 3. Shared Memory (`shared_memory.rs`, `platform_shm.rs`)

**Memory Layout:**
```
┌──────────────────────────────────────────────┐
│ Input Audio Ring Buffer                      │
│ Size: max_buffer_size * 2 (stereo) * 2       │
│ (2x buffering for low latency)               │
├──────────────────────────────────────────────┤
│ Output Audio Ring Buffer                     │
│ Size: max_buffer_size * 2 (stereo) * 2       │
├──────────────────────────────────────────────┤
│ MIDI Event Queue (Ring Buffer)               │
│ Size: 256 events                             │
├──────────────────────────────────────────────┤
│ Control Data (Atomic Counters)               │
│ - Input read/write positions                 │
│ - Output read/write positions                │
│ - MIDI read/write positions                  │
└──────────────────────────────────────────────┘
```

**Implementation:**
- Uses `memfd_create` on Linux (anonymous FD)
- FD passed to subprocess via `SCM_RIGHTS` over Unix socket
- Lock-free ring buffers with atomic read/write positions
- Supports variable-size audio chunks (128-512 samples)

### 4. Plugin Host Subprocess (`plugin_host.rs`)

**Main Event Loop:**

```rust
loop {
    // 1. Read commands from TCP socket (non-blocking, byte-by-byte)
    //    - Processes JSON commands (Initialize, Activate, etc.)
    //    - Responds immediately after processing
    
    // 2. Process audio (if activated)
    //    - Read from input ring buffer (variable chunk size)
    //    - Process through CLAP plugin
    //    - Write to output ring buffer
    //    - Process up to 8 chunks per iteration
    
    // 3. Process timers
    //    - Check which timers need to fire
    //    - Call plugin's on_timer() callbacks
    //    - Essential for GUI animations
    
    // 4. Call plugin GUI callbacks (if GUI open)
    //    - instance.call_on_main_thread_callback()
    //    - Keeps GUI responsive
    
    // 5. Sleep 1ms if no activity (prevents busy-waiting)
}
```

**Host Extensions:**

The subprocess implements these CLAP host extensions:
- **HostGui**: Required by most plugins with GUIs (e.g., DPF-based plugins)
  - Handles resize requests, show/hide, window close events
- **HostTimer**: Required for GUI animations and periodic updates
  - Minimum interval: 10ms (clamped for performance)
  - Thread-safe using Arc<Mutex<HashMap>>
  - Fires in main event loop alongside GUI callbacks

**Audio Processing:**
- **Variable Chunk Size**: 128-512 samples (adapts to available data)
- **Eager Processing**: Processes up to 8 chunks per iteration
- **Low Latency**: Processes as soon as 128 samples available
- **Non-blocking**: Skips processing if insufficient data

### 5. IPC Protocol (`ipc_protocol.rs`)

**Command Channel (TCP Socket):**
```rust
// Engine → Subprocess
Initialize { plugin_path, plugin_id, sample_rate, max_buffer_size, shm_name }
Activate
StartProcessing
StopProcessing
SetParameter { param_id, value }
OpenGui / CloseGui
Reset
Shutdown

// Subprocess → Engine  
InitializeSuccess { device_name, device_vendor, ... }
ActivateResult { success, error }
GuiOpened / GuiClosed
...
```

**Audio/MIDI Channel (Shared Memory):**
- Interleaved stereo audio (f32 samples)
- MIDI events with sample offset
- No synchronization needed (single producer/consumer)

## Critical Design Decisions

### 1. Why Subprocess Isolation?

**Benefits:**
- **Crash Isolation**: Plugin crash doesn't kill DAW
- **GUI Support**: Each plugin has its own event loop
- **Security**: Sandboxing between plugins and engine
- **Resource Management**: Can restart individual plugins

**Tradeoffs:**
- Added latency (~6-10ms with 2x buffering)
- Memory overhead (separate address space)
- IPC complexity

### 2. Why FD Passing vs Named Shared Memory?

**FD Passing (SCM_RIGHTS) - Current Approach:**
✅ More secure (no global namespace)
✅ Automatic cleanup when process exits
✅ Works with `memfd_create` (no filesystem)
✅ Proper Unix best practice

**Named Shared Memory (shm_open):**
❌ Requires filesystem cleanup
❌ Global namespace conflicts
❌ Security concerns

### 3. Why Non-blocking Everything?

**Audio Thread Protection:**
- Audio thread NEVER blocks (real-time requirement)
- Uses `try_lock()` instead of `lock()`
- Commands are fire-and-forget where possible
- Missing a command is better than audio glitches

### 4. Why Variable Chunk Size?

**Fixed chunks** would cause either:
- Buffer overflow (if subprocess too slow)
- Buffer underrun (if chunks too small)

**Variable chunks** allow:
- Process whatever is available
- Minimize latency (process ASAP)
- Avoid overflow (drain buffer quickly)

## Performance Characteristics

### Latency Budget

```
Component                    Latency
─────────────────────────────────────
Engine buffer (256 samples)  ~5.8ms @ 44.1kHz
Ring buffer (2x buffering)   ~11.6ms @ 44.1kHz
Subprocess processing        ~1-2ms
TCP command latency          <1ms
─────────────────────────────────────
Total typical latency:       ~18-20ms
```

### Throughput

- **Audio**: Processes 44,100 samples/sec @ 44.1kHz (100% of real-time)
- **MIDI**: Up to 256 events per buffer cycle
- **Commands**: Limited by TCP latency (~1ms)

## Common Issues & Solutions

### Issue: "Input buffer overflow"
**Cause**: Subprocess not consuming audio fast enough
**Solution**: 
- Increase subprocess processing frequency
- Reduce chunk size threshold
- Check subprocess is actually running

### Issue: "Output buffer full"
**Cause**: Engine not reading output fast enough
**Solution**:
- Ensure `process_block()` reads from output buffer
- Check `is_active` flag not blocking processing

### Issue: Plugin crashes immediately
**Cause**: Usually FD passing or shared memory mapping failure
**Solution**:
- Check subprocess stdout/stderr for errors
- Verify FD 3 is properly inherited
- Ensure shared memory size matches layout

### Issue: Plugin crashes with "hostGui != nullptr" assertion
**Cause**: Plugin requires HostGui extension but host doesn't provide it
**Solution**:
- Ensure `HostHandlers::declare_extensions()` registers `HostGui`
- Implement `HostGuiImpl` trait on shared state
- Common with DPF-based plugins

### Issue: Plugin crashes with "hostTimer != nullptr" assertion
**Cause**: Plugin requires HostTimer extension for GUI updates
**Solution**:
- Ensure `HostHandlers::declare_extensions()` registers `HostTimer`
- Implement `HostTimerImpl` trait on main thread handler
- Common with DPF-based plugins that animate their GUIs

### Issue: Plugin GUI doesn't open
**Cause**: Command routing fails to recognize subprocess adapter type
**Solution**:
- Check `AudioCommand::OpenPluginGui` handler tries downcasting to `SubprocessClapAdapter`
- Ensure it's checked before the legacy `ClapDeviceAdapter`

### Issue: High latency / 1+ second delay
**Cause**: Ring buffers too large
**Solution**:
- Reduce buffer multiplier in `SharedMemoryLayout::new()`
- Use 2x buffering instead of 4x+

## Current Status

### ✅ Working Features
- **Audio Processing**: Plugins process audio via shared memory ring buffers
- **GUI Support**: Plugin GUIs open in floating windows (X11 on Linux)
- **Timer Support**: GUI animations and periodic updates work properly
- **Crash Isolation**: Plugin crashes don't affect the main engine
- **Async Loading**: Plugins load in background threads without blocking audio
- **Parameter Control**: Full get/set/query with automatic normalization and race condition handling

### 🚧 Known Issues & TODOs

#### High Priority
1. **Parameter Control**: ✅ **COMPLETE** (October 2024)
   - [x] Implement `SetParameter` command handling in subprocess
   - [x] Implement `GetParameter` for reading current values
   - [x] Implement `GetParameterInfo` for discovering plugin parameters
   - [x] Fix race condition with async loading (DeviceReady notification)
   - [x] Automatic parameter broadcast to Godot when plugin finishes loading
   - [ ] Add parameter change notifications (plugin → engine) - Future enhancement

2. **GUI Window Management**:
   - [ ] Force plugin GUI windows to stay above Godot app window
   - [ ] Implement window focus management
   - [ ] Handle window close events properly

#### Medium Priority
3. **State Serialization**: Save/load plugin state via IPC
4. **MIDI Support**: Pass MIDI events through shared memory queue
5. **Multi-instance Support**: Multiple instances of the same plugin

### Planned Optimizations
1. **Eventfd Signaling**: Replace polling with event-driven wakeup
2. **Priority Scheduling**: Set subprocess to real-time priority
3. **CPU Affinity**: Pin subprocess to specific cores
4. **Parameter Caching**: Cache parameter values to avoid IPC roundtrips

### Under Consideration
1. **GPU Offloading**: Share GPU resources for visual plugins
2. **Multi-threading**: Process multiple plugins in parallel
3. **Adaptive Buffering**: Dynamically adjust buffer sizes based on load

## Testing Guidelines

### Unit Tests
- Shared memory ring buffer operations
- IPC protocol serialization/deserialization
- FD passing (mocked)

### Integration Tests
- Full subprocess spawn → initialize → process → shutdown cycle
- Audio flow through shared memory
- Command roundtrip latency
- Crash recovery

### Manual Testing
```bash
# Test basic functionality
1. Load plugin → should activate without errors
2. Play audio → should hear effect applied
3. Adjust parameters → should change sound
4. Stop/restart → should handle cleanly

# Test edge cases
1. Rapid parameter changes
2. High CPU load
3. Multiple plugins simultaneously
4. Plugin crash during playback
```

## Debugging Tips

### Enable Subprocess Logging
```rust
// In process_manager.rs
.stdout(std::process::Stdio::inherit())
.stderr(std::process::Stdio::inherit())
```

### Monitor Ring Buffer Usage
```rust
// Add to process_audio():
info!("Input available: {}, Output free: {}", 
      input_buffer.available(), 
      output_buffer.free_space());
```

### Check Subprocess Status
```bash
ps aux | grep plugin_host
strace -p <PID>  # Trace syscalls
perf record -p <PID>  # Profile performance
```

### Verify Shared Memory
```bash
ls -lh /proc/<PID>/fd  # Check FD 3 exists
cat /proc/<PID>/maps   # Verify memory mapping
```

## File Reference

```
Engine/src/audio/devices/clap_host/
├── mod.rs                    # Module exports
├── subprocess_adapter.rs     # Main adapter (AudioDevice impl)
├── process_manager.rs        # Subprocess lifecycle management
├── shared_memory.rs          # Ring buffers & memory access
├── platform_shm.rs           # Linux memfd_create wrapper
├── ipc_protocol.rs           # Command/response types
└── adapter.rs                # Old in-process adapter (deprecated)

Engine/src/bin/
└── plugin_host.rs            # Subprocess executable
```

## Related Documentation

- `OSC_PROTOCOL.md` - Engine ↔ Godot communication
- `PLUGIN_OSC_PROTOCOL.md` - Plugin-specific OSC commands
- `PLUGIN_PARAM_IMPLEMENTATION.md` - Parameter control implementation details
- `IMPLEMENTATION_LOG.md` - Development history

