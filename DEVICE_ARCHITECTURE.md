# Device Architecture Design

## Overview

Sonara uses a **plugin-agnostic device framework** designed to support:
- Built-in effects and instruments (Oscillator, Delay, etc.)
- Future VST3 & CLAP plugin integration

The architecture treats built-in devices and plugins uniformly through a common trait.

## Key Concepts

### AudioDevice Trait

All devices implement `AudioDevice`, providing:

```rust
pub trait AudioDevice: Send {
    // Core audio processing
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize);

    // MIDI support (for instruments)
    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool);

    // Parameter control (normalized 0.0-1.0)
    fn set_parameter(&mut self, param_id: u32, value: f32);
    fn get_parameter(&self, param_id: u32) -> Option<f32>;

    // Metadata
    fn device_id(&self) -> &str;           // "sonara.builtin.oscillator"
    fn device_name(&self) -> &str;         // "Oscillator"
    fn device_category(&self) -> DeviceCategory;
    fn device_variant(&self) -> DeviceVariant;  // BuiltIn, Lv2, Clap

    // Plugin compatibility
    fn audio_ports(&self) -> Vec<AudioPort>;   // Stereo in/out by default
    fn midi_ports(&self) -> Vec<MidiPort>;     // MIDI in for instruments
    fn parameters(&self) -> Vec<ParamInfo>;    // All parameters with ranges
}
```

**Design Rationale:**
- **Block-based processing**: Processes multiple samples per call (not per-sample), enabling efficient plugin wrapper compatibility
- **Normalized parameters** (0.0-1.0): Plugin hosts use normalized ranges; devices map to meaningful values
- **Port declarations**: LV2/CLAP compatibility requires declaring audio/MIDI ports
- **Real-time safe**: No allocations during `process_block()`

### Device Variant

```rust
pub enum DeviceVariant {
    BuiltIn,  // Compiled-in device
    Lv2,      // LV2 plugin (future)
    Clap,     // CLAP plugin (future)
}
```

This allows differentiating between built-in devices and external plugins.

### Device Category

```rust
pub enum DeviceCategory {
    Instrument,  // Generates audio from MIDI
    Effect,      // Processes audio input
    Utility,     // Analysis, control routing, etc.
}
```

Used for plugin discovery and UI filtering.

## Built-In Devices

### Oscillator (Instrument)

**Device ID:** `sonara.builtin.oscillator`

**Category:** Instrument

**MIDI Support:** Yes (receives MIDI events via `send_midi_event()`)

**Parameters:**
- `0`: Waveform (0.0-1.0 → sine/square/sawtooth/triangle)
- `1`: Amplitude (0.0-1.0)

**Design Notes:**
- Monophonic proof-of-concept
- Full polyphony would be managed at the channel level with multiple Voice instances
- Converts MIDI note numbers to frequency (A4=440Hz=note 69)

### Delay (Effect)

**Device ID:** `sonara.builtin.delay`

**Category:** Effect

**MIDI Support:** No

**Parameters:**
- `0`: Delay Time (0.0-1.0 → 1-5000ms)
- `1`: Wet Amount (0.0-1.0, where 0=dry, 1=100% wet)

**Design Notes:**
- Fixed pre-allocated ring buffer (real-time safe)
- Stereo processing with interleaved samples
- Built-in feedback (0.6) for repeating echoes

## Channel Architecture (Future)

### Planned Channel Structure

```rust
pub struct Channel {
    // ... existing fields ...

    // Device chain (ordered processing)
    pub devices: Vec<Box<dyn AudioDevice>>,

    // For INSTRUMENT channels only: active voices
    pub active_voices: HashMap<MidiNote, Voice>,
}
```

**Channel Types & Device Support:**

| Type       | Purpose | Devices | MIDI In | Audio In |
|-----------|---------|---------|---------|----------|
| INSTRUMENT | Generate from MIDI | Instrument devices | ✓ | ✗ |
| AUDIO | Play audio clips | None initially | ✗ | ✓ |
| BUS | Route/mix | Effect devices | ✗ | ✓ |
| MASTER | Main output | Effect devices | ✗ | ✓ |

## OSC Protocol Extensions (Planned)

```
# Device management
/channel/{id}/add_device {device_id} {position}
/channel/{id}/remove_device {position}
/channel/{id}/device/{slot}/param/{param_id} {normalized_value}

# Example: Add oscillator to channel 2 at position 0
/channel/2/add_device "sonara.builtin.oscillator" 0

# Example: Set waveform to square
/channel/2/device/0/param/0 0.25
```

## Integration Points

### Audio Callback Changes Needed

1. **MIDI Routing**: Route MIDI note-ons to target channel's instrument device
   ```rust
   if let Some(channel) = channels.get_mut(&channel_id) {
       for device in &mut channel.devices {
           device.send_midi_event(note, velocity, is_note_on);
       }
   }
   ```

2. **Device Processing**: Process audio through device chains
   ```rust
   let mut block_buffer = vec![0.0; sample_count * 2];
   for device in &mut channel.devices {
       device.process_block(&block_buffer, &mut block_buffer, sample_count);
   }
   ```

3. **Buffer Management**: Device chains process in-place or with intermediate buffers

### Godot UI Considerations

- **Device list UI** for each channel
- **Parameter knobs/sliders** that map to normalized ranges
- **Device picker** (dropdown with available devices)
- **Parameter automation** framework (using normalized parameters)

## Future: LV2 Plugin Support

When LV2 support is added:

1. Create `Lv2Wrapper` struct implementing `AudioDevice`
2. Use `lv2` crate to wrap plugin
3. Map LV2 ports → `audio_ports()` / `midi_ports()`
4. Map LV2 parameters → `set_parameter()` / `get_parameter()`
5. Route audio blocks through LV2 plugin's `run()` method

Similar approach for CLAP support.

## Real-Time Safety Guarantees

✓ No allocations in `process_block()`
✓ No blocking calls
✓ Pre-allocated buffers (ring buffers, sample buffers)
✓ Predictable CPU usage
✓ Parameter changes queued between blocks (via command channel)

## Next Steps

1. **Refactor Channel** to hold device chains
2. **Update audio callback** to route MIDI → instruments and process effect chains
3. **Add OSC commands** for device management
4. **Remove active_voices from Track** (move to INSTRUMENT channels)
5. **Test with Oscillator + Delay** combo
6. **Plan LV2 wrapper** for future integration
