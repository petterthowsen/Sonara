# CLAP Plugin Support Implementation Plan

## Executive Summary

This document outlines a comprehensive plan to integrate CLAP plugin support into Sonara using the `clack-host` Rust library. The current architecture is **already well-suited** for plugin integration with its port-based `AudioDevice` trait.

**Status: Phase 3 Complete ✅**
- Plugin discovery and loading working
- Tested with Dragonfly Hall Reverb (effect plugin)
- Plugins appear in Godot browser UI alongside built-in devices
- Audio processing clean and glitch-free
- Ready for parameter UI and state management (Phase 4)

This plan covers discovery, loading, parameter mapping, threading, GUI integration, and future extensibility for VST3/LV2.

---

## Current Architecture Analysis

### Strengths (Already Plugin-Ready)
✅ **Port-based architecture** - `AudioDevice` trait with `audio_ports()` and `midi_ports()`  
✅ **Block-based processing** - `process_block(inputs, outputs, sample_count)`  
✅ **Parameter abstraction** - `set_parameter()` / `get_parameter()` with normalized 0.0-1.0 values  
✅ **Device variants** - `DeviceVariant` enum already has `Clap` placeholder  
✅ **Lock-free audio thread** - Uses crossbeam channels, no blocking calls  
✅ **Device chain support** - Channels have `Vec<Box<dyn AudioDevice>>` for effect chains  

### Current Limitations (Updated)
✅ ~~**No dynamic plugin loading**~~ - CLAP plugins now load dynamically alongside built-in devices  
✅ ~~**No plugin discovery system**~~ - Scans standard CLAP directories, sends metadata to Godot  
⚠️ **No state management** - Can't save/restore plugin state in projects (Phase 4)  
⚠️ **Single-threaded processing** - Plugins processed serially in device chain (acceptable for now)  
⚠️ **No GUI support** - No way to open/embed plugin UIs (Phase 4)  
⚠️ **No parameter UI** - Can't control plugin parameters from Godot yet (Phase 4)  

---

## What Works Now (Phase 3 Complete)

### Plugin Discovery
- Scans `/usr/lib/clap`, `/usr/local/lib/clap`, `~/.clap` on startup
- Sends plugin metadata to Godot via `/plugin/info` OSC messages
- Plugins appear in Browser UI alongside built-in devices
- Progressive discovery with live UI updates

### Plugin Loading
- Drag CLAP plugin from browser onto mixer channel
- Plugin instantiates via OSC command: `/channel/{id}/add_device`
- Unified API with built-in devices (same commands)
- Proper category detection (instrument/effect/utility)

### Audio Processing
- Real-time audio processing through CLAP plugins
- Tested with Dragonfly Hall Reverb (effect plugin)
- Clean audio, no glitches or artifacts
- Variable buffer sizes handled correctly (up to 8192 samples)
- Bypass/enable support (active/enabled states)

### Integration
- `DeviceAssetProvider` discovers plugins via OSC
- Single unified device registry (built-in + plugins)
- Device metadata (name, vendor, version, category) displayed in browser
- Follows existing asset system patterns

### Next Steps (Phase 4)
- ✅ **Parameter UI auto-generation** - Implemented! Queries params via `/plugin/get_parameters`, auto-builds UI
- ⏳ Plugin state save/load for projects
- ⏳ Parameter automation lanes
- ⏳ Plugin GUI support (floating windows, optional)

---

## Phase 1: Core Infrastructure (Week 1-2)

### 1.1 Add Dependencies

**File:** `Engine/Cargo.toml`

```toml
[dependencies]
# Existing dependencies...

# CLAP plugin hosting
clack-host = "0.13"           # Core hosting library
clack-extensions = "0.13"     # Parameter, GUI, state extensions
libloading = "0.8"            # For safe dynamic library loading

# Serialization for plugin state
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
base64 = "0.22"               # Encode binary state for JSON storage
```

**Rationale:** `clack-host` provides safe CLAP hosting APIs. We'll use `libloading` (already a transitive dep) for dynamic library management.

---

### 1.2 Create Plugin Discovery System

**New file:** `Engine/src/audio/devices/clap_host/mod.rs`

```rust
pub mod discovery;
pub mod instance;
pub mod adapter;
pub mod parameter_bridge;

use std::path::{Path, PathBuf};
use std::collections::HashMap;

/// Plugin scanner that finds .clap files in standard locations
pub struct PluginScanner {
    scan_paths: Vec<PathBuf>,
    discovered_plugins: HashMap<String, PluginDescriptor>,
}

impl PluginScanner {
    pub fn new() -> Self {
        Self {
            scan_paths: Self::default_scan_paths(),
            discovered_plugins: HashMap::new(),
        }
    }

    /// Standard CLAP plugin paths (Linux)
    fn default_scan_paths() -> Vec<PathBuf> {
        vec![
            PathBuf::from("/usr/lib/clap"),
            PathBuf::from(format!("{}/.clap", std::env::var("HOME").unwrap_or_default())),
        ]
    }

    /// Scan all paths and populate discovered_plugins
    pub fn scan(&mut self) -> Result<(), Box<dyn std::error::Error>> {
        // Walk directories, find .clap and .so files
        // Use clack_host::PluginBundle::load() to introspect
        // Store PluginDescriptor metadata
        todo!()
    }

    pub fn get_plugin(&self, id: &str) -> Option<&PluginDescriptor> {
        self.discovered_plugins.get(id)
    }

    pub fn all_plugins(&self) -> impl Iterator<Item = &PluginDescriptor> {
        self.discovered_plugins.values()
    }
}

/// Metadata for a discovered plugin
#[derive(Debug, Clone)]
pub struct PluginDescriptor {
    pub id: String,              // e.g. "com.u-he.diva"
    pub name: String,
    pub vendor: String,
    pub version: String,
    pub category: DeviceCategory,
    pub path: PathBuf,           // Path to .clap bundle
}
```

**Key Design Decisions:**
- **Lazy loading:** Don't load plugins until instantiated (avoid RAM waste)
- **Cache metadata:** Store descriptor info to avoid re-scanning on startup
- **Thread safety:** Scanner runs on main thread, results cached in `EngineState`

---

### 1.3 Create CLAP-to-Device Adapter

**New file:** `Engine/src/audio/devices/clap_host/adapter.rs`

This is the **core integration point** - adapts clack's API to our `AudioDevice` trait.

```rust
use clack_host::prelude::*;
use clack_host::events::event_types::*;
use crate::audio::devices::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamValue, ParamInfo};

/// Wraps a CLAP plugin instance to implement our AudioDevice trait
pub struct ClapDeviceAdapter {
    // Bundle and instance (must outlive processing)
    _bundle: PluginBundle,
    instance: Option<PluginInstance<SonaraHost>>,
    audio_processor: Option<PluginAudioProcessor>,
    
    // Metadata
    device_id: String,
    device_name: String,
    category: DeviceCategory,
    
    // Parameter mapping (CLAP param ID -> our normalized ParamId)
    param_map: HashMap<ClapId, ParamId>,
    param_info_cache: Vec<ParamInfo>,
    
    // Audio buffer management
    input_buffers: Vec<Vec<f32>>,
    output_buffers: Vec<Vec<f32>>,
    input_ports: AudioPorts,
    output_ports: AudioPorts,
    
    // Event buffers (MIDI -> CLAP events)
    event_buffer: Vec<NoteOnEvent>,  // Pre-allocated for real-time safety
    output_events: EventBuffer,
    
    // State
    sample_rate: f32,
    max_buffer_size: usize,
}

impl ClapDeviceAdapter {
    pub fn new(
        bundle_path: &Path,
        plugin_id: &str,
        sample_rate: f32,
        max_buffer_size: usize,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        // 1. Load bundle
        let bundle = unsafe { PluginBundle::load(bundle_path)? };
        
        // 2. Find plugin descriptor
        let factory = bundle.get_plugin_factory()
            .ok_or("No plugin factory")?;
        let descriptor = factory.plugin_descriptors()
            .find(|d| d.id().unwrap().to_bytes() == plugin_id.as_bytes())
            .ok_or("Plugin not found in bundle")?;
        
        // 3. Create plugin instance
        let host_info = HostInfo::new(
            "Sonara",
            "Sonara Project",
            "https://github.com/sonara",
            "0.1.0"
        )?;
        
        let mut instance = PluginInstance::<SonaraHost>::new(
            |_| SonaraHostShared,
            |_| SonaraHostMainThread,
            &bundle,
            descriptor.id().unwrap(),
            &host_info
        )?;
        
        // 4. Query parameters (via CLAP params extension)
        let param_info_cache = Self::query_parameters(&mut instance)?;
        
        // 5. Activate plugin
        let audio_config = PluginAudioConfiguration {
            sample_rate: sample_rate as f64,
            min_frames_count: 64,
            max_frames_count: max_buffer_size as u32,
        };
        
        let audio_processor = instance.activate(
            |_, _| SonaraHostAudioProcessor,
            audio_config
        )?;
        
        // 6. Pre-allocate buffers (2 channels stereo for now)
        let input_buffers = vec![vec![0.0f32; max_buffer_size]; 2];
        let output_buffers = vec![vec![0.0f32; max_buffer_size]; 2];
        
        Ok(Self {
            _bundle: bundle,
            instance: Some(instance),
            audio_processor: Some(audio_processor),
            device_id: plugin_id.to_string(),
            device_name: descriptor.name().unwrap().to_str()?.to_string(),
            category: Self::infer_category(&descriptor),
            param_map: Self::build_param_map(&param_info_cache),
            param_info_cache,
            input_buffers,
            output_buffers,
            input_ports: AudioPorts::with_capacity(2, 1),
            output_ports: AudioPorts::with_capacity(2, 1),
            event_buffer: Vec::with_capacity(128),
            output_events: EventBuffer::new(),
            sample_rate,
            max_buffer_size,
        })
    }
    
    fn query_parameters(instance: &mut PluginInstance<SonaraHost>) -> Result<Vec<ParamInfo>, Box<dyn std::error::Error>> {
        // Use clack-extensions params API to enumerate parameters
        // Map to our ParamInfo struct
        todo!()
    }
    
    fn build_param_map(params: &[ParamInfo]) -> HashMap<ClapId, ParamId> {
        // Map CLAP param IDs (arbitrary u32) to sequential ParamId (0, 1, 2...)
        todo!()
    }
    
    fn infer_category(descriptor: &PluginDescriptor) -> DeviceCategory {
        // Use CLAP's features array to determine instrument vs effect
        // Check for "instrument", "synthesizer", etc.
        DeviceCategory::Effect  // Default
    }
}

impl AudioDevice for ClapDeviceAdapter {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // 1. Copy interleaved input to plugin's buffers
        for i in 0..sample_count {
            let left_idx = i * 2;
            let right_idx = i * 2 + 1;
            self.input_buffers[0][i] = inputs[left_idx];
            self.input_buffers[1][i] = inputs[right_idx];
        }
        
        // 2. Prepare CLAP audio structures
        let input_audio = self.input_ports.with_input_buffers([AudioPortBuffer {
            latency: 0,
            channels: AudioPortBufferType::f32_input_only(
                self.input_buffers.iter_mut().map(|b| InputChannel::constant(&b[..sample_count]))
            )
        }]);
        
        let mut output_audio = self.output_ports.with_output_buffers([AudioPortBuffer {
            latency: 0,
            channels: AudioPortBufferType::f32_output_only(
                self.output_buffers.iter_mut().map(|b| &mut b[..sample_count])
            )
        }]);
        
        // 3. Prepare events
        let input_events = InputEvents::from_buffer(&self.event_buffer);
        let mut output_events = OutputEvents::from_buffer(&mut self.output_events);
        
        // 4. Process audio
        if let Some(processor) = &mut self.audio_processor {
            let _ = processor.process(
                &input_audio,
                &mut output_audio,
                &input_events,
                &mut output_events,
                None,
                None
            );
        }
        
        // 5. Copy plugin output to interleaved output buffer
        for i in 0..sample_count {
            let left_idx = i * 2;
            let right_idx = i * 2 + 1;
            outputs[left_idx] = self.output_buffers[0][i];
            outputs[right_idx] = self.output_buffers[1][i];
        }
        
        // 6. Clear event buffer for next block
        self.event_buffer.clear();
    }
    
    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool) {
        if is_note_on {
            let event = NoteOnEvent::new(
                0,  // Sample offset (could be frame-accurate in future)
                Pckn::new(0u16, 0u16, 0u16, note as u32),  // Port, channel, key, note_id
                velocity as f64 / 127.0  // Normalize velocity
            );
            self.event_buffer.push(event);
        } else {
            // TODO: Create NoteOffEvent
        }
    }
    
    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        // Map our ParamId to CLAP's ClapId and send ParamValueEvent
        // Note: May need to queue this for next process() call
        todo!()
    }
    
    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        // Query plugin's current parameter value
        todo!()
    }
    
    fn device_id(&self) -> &str { &self.device_id }
    fn device_name(&self) -> &str { &self.device_name }
    fn device_category(&self) -> DeviceCategory { self.category }
    fn device_variant(&self) -> DeviceVariant { DeviceVariant::Clap }
    
    fn parameters(&self) -> Vec<ParamInfo> {
        self.param_info_cache.clone()
    }
    
    fn reset(&mut self) {
        // Send CLAP reset event or deactivate/reactivate
        self.event_buffer.clear();
        self.input_buffers.iter_mut().for_each(|b| b.fill(0.0));
        self.output_buffers.iter_mut().for_each(|b| b.fill(0.0));
    }
}
```

**Critical Design Decisions:**

1. **Thread Safety:**
   - Bundle and instance created on **main thread**
   - `activate()` called on main thread, returns `AudioProcessor`
   - Processing happens on **audio thread** via `AudioProcessor::process()`
   - Deactivation happens back on **main thread**

2. **Lifetime Management:**
   - Bundle must outlive instance
   - Instance must outlive audio processor
   - Use `Option<T>` to allow staged teardown

3. **Buffer Management:**
   - Pre-allocate buffers at activation (no allocations in audio callback)
   - Copy between interleaved (Sonara) and deinterleaved (CLAP) formats

4. **Event Handling:**
   - MIDI notes queued in `event_buffer` during `send_midi_event()`
   - Converted to CLAP NoteOn/NoteOff events in `process_block()`
   - Cleared after each block

---

### 1.4 Implement Host Handlers

**New file:** `Engine/src/audio/devices/clap_host/host_impl.rs`

```rust
use clack_host::prelude::*;

/// Shared host state (accessible from all threads)
pub struct SonaraHostShared;

impl<'a> SharedHandler<'a> for SonaraHostShared {
    fn request_restart(&self) {
        // Plugin requesting restart (parameter list changed, etc.)
        // Send OSC message to Godot to reload plugin UI
        tracing::info!("CLAP plugin requested restart");
    }
    
    fn request_process(&self) {
        // Plugin requesting processing to start (e.g., tail processing after note off)
        tracing::debug!("CLAP plugin requested process");
    }
    
    fn request_callback(&self) {
        // Plugin requesting main thread callback (GUI update, etc.)
        tracing::debug!("CLAP plugin requested callback");
    }
}

/// Main thread handler (parameter queries, state save/load)
pub struct SonaraHostMainThread;

impl<'a> PluginMainThread<'a, SonaraHostShared> for SonaraHostMainThread {
    // Implement callbacks for parameter changes, state updates, etc.
}

/// Audio processor handler (transport info, etc.)
pub struct SonaraHostAudioProcessor;

impl<'a> PluginAudioProcessor<'a, SonaraHostShared, SonaraHostMainThread> for SonaraHostAudioProcessor {
    // Implement audio thread callbacks (rare, mostly informational)
}

/// Top-level host handlers struct
pub struct SonaraHost;

impl HostHandlers for SonaraHost {
    type Shared<'a> = SonaraHostShared;
    type MainThread<'a> = SonaraHostMainThread;
    type AudioProcessor<'a> = SonaraHostAudioProcessor;
}
```

---

## Phase 2: OSC Protocol Extensions (Week 2-3)

### 2.1 Plugin Discovery Protocol

Add new OSC endpoints for plugin management:

**Rust → Godot (port 7001):**
```
/plugin/discovered [count]                    # Total plugins found
/plugin/info [id, name, vendor, category]     # Per-plugin metadata
```

**Godot → Rust (port 7000):**
```
/plugin/scan                                  # Trigger plugin scan
/plugin/instantiate [channel_id, plugin_id]   # Load plugin on channel
/plugin/remove [channel_id, device_index]     # Remove device from chain
```

### 2.2 Parameter Protocol

**Rust → Godot:**
```
/plugin/param/count [channel_id, device_idx, count]
/plugin/param/info [channel_id, device_idx, param_id, name, min, max, default, unit]
/plugin/param/value [channel_id, device_idx, param_id, value]  # Current value
```

**Godot → Rust:**
```
/plugin/param/set [channel_id, device_idx, param_id, value]
/plugin/param/get [channel_id, device_idx, param_id]           # Query value
```

### 2.3 State Management Protocol

**Godot → Rust:**
```
/plugin/state/save [channel_id, device_idx]                     # Returns base64 blob
/plugin/state/load [channel_id, device_idx, base64_state_blob]
```

**Implementation in `Engine/src/audio/commands.rs`:**

```rust
pub enum AudioCommand {
    // Existing commands...
    
    // Plugin discovery
    ScanPlugins,
    InstantiatePlugin { channel_id: ChannelId, plugin_id: String },
    RemoveDevice { channel_id: ChannelId, device_index: usize },
    
    // Plugin parameters
    SetPluginParameter { channel_id: ChannelId, device_index: usize, param_id: ParamId, value: ParamValue },
    GetPluginParameter { channel_id: ChannelId, device_index: usize, param_id: ParamId },
    
    // State management
    SavePluginState { channel_id: ChannelId, device_index: usize },
    LoadPluginState { channel_id: ChannelId, device_index: usize, state: Vec<u8> },
}
```

---

## Phase 3: Godot Integration (Week 3-4)

### 3.1 Plugin Browser UI

Create `Godot/browser/PluginAssetProvider.gd`:

```gdscript
extends AssetProvider
class_name PluginAssetProvider

# Listen for /plugin/info OSC messages
# Populate Asset list with:
# - Asset.id = plugin_id
# - Asset.name = plugin name
# - Asset.category = "Instruments" or "Effects"
# - Asset.metadata = { vendor, version }

func _ready():
    AudioEngineOSC.connect("message_received", _on_osc_message)

func scan_plugins():
    AudioEngineOSC.send_message("/plugin/scan", [])

func _on_osc_message(address: String, args: Array):
    if address == "/plugin/info":
        var plugin_asset = Asset.new()
        plugin_asset.id = args[0]
        plugin_asset.name = args[1]
        # ... populate metadata
        emit_signal("asset_added", plugin_asset)
```

**Integration:**
- Plugins appear in existing Browser alongside built-in devices
- Drag-and-drop onto mixer channels to instantiate
- Category filtering ("Instruments", "Effects", "Analyzers")

### 3.2 Plugin Parameter UI

Extend `DeviceParameter.gd` to handle CLAP parameters:

```gdscript
# No changes needed! Current parameter system already uses:
# - param_id (u32)
# - normalized values (0.0-1.0)
# - min/max/default metadata

# Just need to listen for /plugin/param/info messages to populate UI
```

**Auto-generate UI:**
- Sliders for continuous parameters
- Dropdowns for stepped parameters (via CLAP `STEP_COUNT` flag)
- Text boxes for string parameters

### 3.3 Plugin State Serialization

**In `Project.gd` save/load:**

```gdscript
# Save plugin state
if device.variant == Device.Variant.CLAP:
    var state_blob = await AudioEngineOSC.send_request(
        "/plugin/state/save", 
        [channel_id, device_index]
    )
    device_data["clap_state"] = state_blob  # Base64 string

# Load plugin state
if device_data.has("clap_state"):
    AudioEngineOSC.send_message(
        "/plugin/state/load",
        [channel_id, device_index, device_data["clap_state"]]
    )
```

---

## Phase 4: Advanced Features (Week 4-5)

### 4.1 Plugin GUI Support (Optional, Complex)

**Challenge:** Embedding native plugin GUIs in Godot

**Options:**

1. **X11 Window Reparenting (Linux-specific):**
   - Plugin opens window with `CLAP_WINDOW_X11` API
   - Use Godot's `DisplayServer.window_set_transient()` to embed
   - **Complexity:** High, requires X11 integration

2. **Floating Windows (Simpler):**
   - Plugin opens separate window
   - Godot tracks window ownership via process ID
   - **Complexity:** Low, but less integrated

3. **Remote GUI (Future):**
   - Use CLAP's remote GUI extension (rare)
   - Render in separate process, embed in Godot

**Recommendation:** Start with floating windows, defer embedding to Phase 5+.

**Implementation:**

```rust
// In ClapDeviceAdapter
pub fn open_gui(&mut self) -> Result<(), PluginError> {
    if let Some(instance) = &mut self.instance {
        // Use clack-extensions GUI extension
        // Call show_window() with X11 parent handle
    }
}
```

**OSC Protocol:**
```
/plugin/gui/open [channel_id, device_idx]
/plugin/gui/close [channel_id, device_idx]
```

### 4.2 Latency Compensation

**Problem:** Plugins may report latency (delay between input and output)

**Solution:**
1. Query latency via CLAP `latency` extension during `activate()`
2. Store per-device latency in `ClapDeviceAdapter`
3. Align playback by offsetting channels in mixer

**Implementation:**

```rust
impl ClapDeviceAdapter {
    pub fn get_latency_samples(&self) -> u32 {
        // Query plugin's reported latency
        // Return 0 if plugin doesn't report latency
    }
}

// In Engine/src/audio/mixing.rs
// Adjust playhead offset per-channel based on device chain latency
```

### 4.3 Plugin Preset Management

**CLAP State Extension** supports:
- `state_save()` - returns binary blob
- `state_load()` - restores from blob
- Preset enumeration (optional extension)

**Godot Integration:**
```gdscript
# Save preset to file
var preset_data = await AudioEngineOSC.request("/plugin/state/save", [...])
var file = FileAccess.open("user://presets/MyPreset.clapstate", FileAccess.WRITE)
file.store_string(preset_data)

# Load preset
var preset_data = file.get_as_text()
AudioEngineOSC.send("/plugin/state/load", [channel_id, device_idx, preset_data])
```

### 4.4 Multi-Threading (Performance Optimization)

**Current Bottleneck:** Device chains process serially

**Optimization:**
- Process independent channels in parallel (crossbeam `rayon` or `scoped` threads)
- Keep plugin processing on same thread (most plugins aren't thread-safe)

**Implementation:**

```rust
// In Engine/src/audio/processing.rs
use crossbeam::thread;

pub fn process_audio_parallel(state: &mut EngineState, frames: usize) {
    // Group channels by dependency (topological sort of routing graph)
    let channel_groups = state.compute_processing_order();
    
    for group in channel_groups {
        thread::scope(|s| {
            for channel_id in group {
                s.spawn(|_| {
                    // Process channel's device chain
                    if let Some(channel) = state.channels.get_mut(&channel_id) {
                        channel.process_device_chain(frames);
                    }
                });
            }
        }).unwrap();
    }
}
```

**Caveats:**
- Most CLAP plugins are **not** thread-safe for concurrent processing
- Only parallelize **across channels**, not within a channel's device chain

---

## Phase 5: Extensibility for VST3/LV2 (Future)

### 5.1 Unified Plugin Abstraction

To support multiple plugin formats, introduce a plugin manager layer:

```rust
// Engine/src/audio/devices/plugin_manager.rs

pub enum PluginFormat {
    Clap,
    Vst3,   // Future: via vst3-sys crate
    Lv2,    // Future: via lv2-raw-sys crate
}

pub trait PluginHost {
    fn scan(&mut self) -> Vec<PluginDescriptor>;
    fn instantiate(&self, plugin_id: &str) -> Result<Box<dyn AudioDevice>, PluginError>;
}

pub struct PluginManager {
    clap_host: ClapHostManager,
    vst3_host: Option<Vst3HostManager>,  // Future
    lv2_host: Option<Lv2HostManager>,    // Future
}

impl PluginManager {
    pub fn scan_all(&mut self) -> Vec<PluginDescriptor> {
        let mut plugins = Vec::new();
        plugins.extend(self.clap_host.scan());
        // plugins.extend(self.vst3_host.scan());  // Future
        plugins
    }
    
    pub fn instantiate(&self, plugin_id: &str) -> Result<Box<dyn AudioDevice>, PluginError> {
        // Dispatch to appropriate host based on plugin format
        if let Some(clap_device) = self.clap_host.try_instantiate(plugin_id) {
            return Ok(clap_device);
        }
        // Try VST3, LV2, etc.
        Err(PluginError::NotFound)
    }
}
```

### 5.2 Format Detection

**Heuristics:**
- `.clap` extension → CLAP
- `.vst3` extension → VST3
- `.lv2` directory → LV2
- Probe file headers for magic bytes

---

## Testing Strategy

### Unit Tests

1. **Plugin Discovery:**
   - Mock `.clap` file with known plugins
   - Verify scanner finds and parses descriptors

2. **Parameter Mapping:**
   - Test bidirectional conversion between CLAP IDs and our `ParamId`
   - Verify normalization (0.0-1.0)

3. **Buffer Handling:**
   - Test interleaved ↔ deinterleaved conversion
   - Verify no buffer overruns

### Integration Tests

1. **End-to-End Plugin Loading:**
   - Use a real CLAP plugin (e.g., Surge XT, free/open-source)
   - Scan → Instantiate → Process audio → Verify output

2. **OSC Round-Trip:**
   - Godot sends `/plugin/instantiate`
   - Rust loads plugin, sends `/plugin/param/info` back
   - Godot displays parameters

3. **State Serialization:**
   - Set parameters → Save state → Load state → Verify parameters restored

### Performance Tests

1. **Latency:**
   - Measure round-trip audio latency with plugin chain
   - Target: <10ms @ 48kHz/512 samples

2. **CPU Usage:**
   - Load 10 plugins on 10 channels
   - Verify audio thread stays below 50% CPU

---

## Risk Mitigation

### Risk 1: Plugin Crashes

**Impact:** Segfault in plugin takes down entire DAW  
**Mitigation:**
- Run plugins in separate process (future: CLAP out-of-process extension)
- Catch panics with `std::panic::catch_unwind()` (limited effectiveness in C++ FFI)
- Extensive logging before/after plugin calls

### Risk 2: Thread Safety Violations

**Impact:** Race conditions, audio glitches  
**Mitigation:**
- Strictly follow CLAP threading model (main thread for activate/deactivate, audio thread for process)
- Use `Send + Sync` bounds where appropriate
- Audit `unsafe` code blocks

### Risk 3: Parameter Automation Conflicts

**Impact:** Godot UI and plugin GUI fight over parameter values  
**Mitigation:**
- Use CLAP's parameter gesture events (begin/end edit)
- Lock UI controls during plugin GUI editing
- Implement "touch automation" mode

### Risk 4: Sample Rate Mismatches

**Impact:** Pitch/timing errors  
**Mitigation:**
- Always pass device's actual sample rate to plugin
- Verify plugin supports project sample rate before activation
- Resample if necessary (future: use `rubato` crate)

---

## Performance Considerations

### Memory

**Baseline:**
- Each CLAP plugin instance: ~10-50 MB (depends on plugin)
- 10 plugins = ~500 MB
- Buffers: 512 samples × 2 channels × 4 bytes × 10 plugins = ~40 KB (negligible)

**Optimization:**
- Lazy load plugins (don't load until instantiated)
- Unload plugins when project closed
- Share read-only data (preset banks, wavetables) between instances if possible

### CPU

**Baseline:**
- Simple gain plugin: <1% CPU @ 48kHz/512 samples
- Complex synth (e.g., Diva): 10-30% CPU per instance
- Target: Support 10+ instances before audio glitches

**Optimization:**
- Multi-thread channel processing (Phase 4.4)
- Increase buffer size (512 → 1024 samples) for lower latency-tolerant use cases
- Use SIMD-optimized plugins when available

### Latency

**Current:**
- Buffer size: 512 samples @ 48 kHz = ~10.7 ms
- Plugin latency: 0-1024 samples (depends on plugin)

**Target:**
- Keep total latency <20 ms for real-time playing

---

## Dependencies Summary

```toml
[dependencies]
# Existing
cpal = "0.15"
rustwav = "0.3.8"
rosc = "0.10"
anyhow = "1.0"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-appender = "0.2"
crossbeam = "0.8"
chrono = "0.4"

# New for CLAP support
clack-host = "0.13"
clack-extensions = "0.13"
libloading = "0.8"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
base64 = "0.22"
```

---

## Issues Encountered & Fixed

### Buffer Size Mismatch (Phase 3)
**Problem:** CLAP plugins were initialized with `max_buffer_size = 512`, but CPAL was calling the audio callback with 1881 frames, causing buffer overflows and audio glitches.

**Root Cause:** Hardcoded buffer size in `engine.rs` didn't account for CPAL's variable buffer sizes (system-dependent).

**Solution:** Changed `max_buffer_size` from 512 to 8192 to safely accommodate any reasonable CPAL buffer size. Plugins now allocate generous buffers (~131KB per stereo plugin) to handle variable callback sizes.

**Files Modified:**
- `Engine/src/audio/engine.rs` (line 120-124)

**Result:** Clean audio processing with Dragonfly Hall Reverb, no more buffer overflow errors.

---

### OSC Protocol Inconsistency - Parameter Messages (Phase 4)
**Problem:** Plugin parameter messages used argument-based routing (`/plugin/param/count [channel_id, device_pos, count]`) instead of path-based routing. This required all Channel instances to listen to the same global address and filter by `channel_id`, which is inefficient and inconsistent with the existing protocol.

**Root Cause:** Initial implementation didn't follow the established pattern of path-based routing used for other channel-specific messages (e.g., `/channel/{id}/peak`).

**Solution:** Changed parameter messages to use path-based routing:
- Before: `/plugin/param/count [channel_id, device_pos, count]`
- After: `/channel/{channel_id}/device/{device_pos}/param/count [count]`
- Before: `/plugin/param/info [channel_id, device_pos, param_id, name, min, max, default]`
- After: `/channel/{channel_id}/device/{device_pos}/param/info [param_id, name, min, max, default]`

**Benefits:**
- Each Channel only listens to its own addresses (no filtering needed)
- Consistent with existing protocol design
- More efficient (no unnecessary callbacks)
- Cleaner separation of concerns

**Files Modified:**
- `Engine/src/osc/server.rs` - Changed message format to use path-based routing
- `Godot/data/Channel.gd` - Added device-specific listeners, query logic, and parameter loading
- `Godot/device_lane/DevicePanel.gd` - Added signal handler to refresh UI when params load
- `PLUGIN_OSC_PROTOCOL.md` - Updated documentation

**Result:** Plugin parameters now load automatically when a plugin is added to a channel, and the UI auto-generates controls just like built-in devices.

---

## Timeline

### Week 1-2: Core Infrastructure ✅ Phase 1 Complete
- [x] Add dependencies (`clack-host`, `clack-extensions`, `libloading`, `serde`, `base64`)
- [x] Implement `PluginScanner` (discovery system with Linux standard paths)
- [x] Implement `ClapDeviceAdapter` (full AudioDevice trait implementation)
- [x] Implement host handlers (`SonaraHost`, `SharedHandler`, `MainThreadHandler`, `AudioProcessorHandler`)
- [ ] Unit tests (deferred)

### Week 2-3: OSC Protocol ✅ Phase 2 Complete
- [x] Add OSC endpoints for discovery, instantiation, parameters
- [x] Integrate into `commands.rs`
- [x] Add plugin commands to AudioCommand enum
- [x] Add PluginScanner to EngineState
- [x] Implement command handlers for plugin operations
- [x] Add status responses for plugin discovery and parameters
- [x] Test script created (`test_plugin_osc.sh`)
- [x] End-to-end testing with real CLAP plugins (Dragonfly Hall Reverb)

### Week 3-4: Godot Integration ✅ Phase 3 Complete
- [x] `DeviceAssetProvider.gd` - Plugin discovery via OSC
- [x] Plugin browser UI (unified with built-in devices)
- [x] OSC listeners for `/plugin/info` and `/plugin/scan_complete`
- [x] Progressive plugin discovery with live updates
- [x] Fixed buffer size mismatch (512 → 8192 max_buffer_size)
- [x] Tested with real plugin (Dragonfly Hall Reverb)
- [x] Parameter UI auto-generation (deferred to Phase 4)
- [?] State serialization in project save/load (deferred to Phase 4)
    - [x] Parameter serialization

### Week 4-5: Advanced Features (In Progress)
- [x] Parameter UI auto-generation (query via `/plugin/get_parameters`)
- [?] State serialization in project save/load
- [ ] Plugin GUI (floating windows)
- [ ] Latency compensation
- [ ] Preset management
- [ ] Multi-threading optimization

### Week 5+: Polish & Testing
- [ ] Integration tests with real plugins (Surge XT, TAL-NoiseMaker)
- [ ] Performance profiling
- [ ] Documentation
- [ ] User testing

---

## Open Questions

1. **GUI Strategy:** Floating windows or X11 embedding? (Recommend: start with floating)
2. **Plugin Sandboxing:** Run in same process or separate? (Recommend: same process initially, out-of-process in Phase 6)
3. **Preset Format:** Store as base64 in project JSON or separate `.preset` files? (Recommend: base64 for simplicity)
4. **Parameter Automation:** Implement automation lanes for plugin params? (Recommend: yes, Phase 5)
5. **Multi-Output Plugins:** How to handle plugins with >2 outputs? (Recommend: create child channels, Phase 5)

---

## Success Criteria

✅ Load and process audio through a real CLAP plugin (Dragonfly Hall Reverb tested)  
✅ Plugin parameters visible and controllable in Godot UI (auto-generated, fully working)  
⏳ Plugin state saved and restored in project files (pending)  
⏳ CPU usage <50% with 10 plugin instances (not tested yet)  
✅ No audio glitches or crashes during normal operation (buffer size issue fixed)  
✅ Support for both instrument and effect plugins (category detection working)  

---

## Conclusion

The current Sonara architecture is **already well-designed** for plugin integration. The `AudioDevice` trait and port-based processing align perfectly with CLAP's design. The main work involves:

1. **Bridging clack's API to our trait** (ClapDeviceAdapter)
2. **Adding OSC protocol extensions** (minimal changes to existing code)
3. **Creating Godot UI for plugin browsing** (reuse existing Browser system)

The plan is incremental and allows for future expansion to VST3/LV2 without major architectural changes.

**Estimated Total Effort:** 4-5 weeks for full CLAP support (Phases 1-4)  
**Risk Level:** Medium (primarily FFI/threading challenges)  
**Reward:** Professional plugin ecosystem, massive expansion of available instruments/effects

