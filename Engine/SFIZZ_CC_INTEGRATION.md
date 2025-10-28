# Sfizz CC Parameter Integration

## Summary

Integrated the new `sfizz::CcLabel` API to expose SFZ-declared MIDI CC parameters as automatable device parameters in Sonara.

## Implementation Details

### Rust Engine (`Engine/src/audio/devices/sfizz_device.rs`)

**Added Fields:**
- `cc_labels: Arc<Mutex<Vec<sfizz::CcLabel>>>` - Stores labeled CCs from loaded SFZ
- `cc_values: Arc<Mutex<HashMap<u8, f32>>>` - Tracks current normalized (0.0-1.0) values
- `parameters_changed: Arc<Mutex<bool>>` - Poll-based flag for parameter list changes

**Key Methods:**

1. **`load_sfz_async()`** - Enhanced to:
   - Call `synth.cc_labels()` after successful SFZ load
   - Initialize `cc_values` to 0.0 for each discovered CC
   - Set `parameters_changed` flag to trigger Godot notification
   - Log discovered CCs: `CC{number}: {name}`

2. **`parameters()`** - Returns dynamic parameter list:
   - Maps each `CcLabel` to a `ParamInfo`
   - `param_id` = CC number (0-127)
   - Range: 0.0-1.0 (normalized)
   - All CCs marked as `is_automation_safe = true`

3. **`set_parameter(param_id, value)`** - Sends CC to sfizz:
   - Stores value in `cc_values` map
   - Calls `sfizz_send_hdcc()` with normalized 0.0-1.0 value
   - Uses `try_lock()` pattern (non-blocking, audio-thread safe)
   - Falls back gracefully if synth not ready

4. **`get_parameter(param_id)`** - Retrieves stored CC value from cache

5. **`take_parameters_changed()`** - Poll method for parameter list updates:
   - Returns `true` if parameters changed since last poll
   - Clears flag atomically (consume-on-read pattern)

### Parameter Update Flow (`Engine/src/audio/mixing.rs`)

Added polling in the device chain processing loop:

```rust
if let Some(sfizz_device) = device.as_any_mut().downcast_mut::<SfizzDevice>() {
    if sfizz_device.take_parameters_changed() {
        // Send PluginParameterCount + PluginParameterInfo messages to Godot
    }
}
```

This runs every audio callback (~20Hz) and sends parameter updates whenever:
- A new SFZ file finishes loading
- CC labels change (new instrument loaded)

### Godot Integration

**No Godot changes required!** The existing plugin parameter system handles dynamic parameters:

- `PluginParameterCount` message clears old parameters
- `PluginParameterInfo` messages populate new CC list
- Device UI rebuilds automatically when parameters change
- Parameter automation already supports real-time CC changes

## Usage

1. **Load SFZ with labeled CCs:**
   ```sfz
   <control>
   label_cc7=Volume
   label_cc10=Pan
   label_cc74=Brightness
   ```

2. **Parameters appear automatically:**
   - Device panel shows CC sliders/knobs
   - Automation lanes available for each CC
   - Changes sent as MIDI HDCC (high-definition, 0.0-1.0)

3. **Real-time updates:**
   - Load different SFZ → parameters update instantly
   - No manual refresh needed
   - Old parameters cleared, new ones populated

## Audio Thread Safety

All operations follow real-time safety rules:

- ✅ `try_lock()` used everywhere (never blocks)
- ✅ Background thread for SFZ file loading
- ✅ Pre-allocated HashMap for CC values
- ✅ Poll-based notification (no callbacks)
- ✅ Skip on lock failure (no audio glitches)

## Testing

Test with an SFZ file that includes labeled CCs:

```sfz
<control>
label_cc1=Modulation
label_cc7=Volume
label_cc10=Pan
label_cc11=Expression
label_cc74=Brightness
label_cc91=Reverb

<region>
sample=kick.wav
ampeg_attack_oncc1=0.5
ampeg_release_oncc1=0.5
volume_oncc7=12
pan_oncc10=100
```

Expected behavior:
1. Load SFZ → Engine logs "📋 Discovered 6 labeled CC parameters"
2. Godot receives 6 `PluginParameterInfo` messages
3. Device panel shows 6 parameter controls
4. Moving sliders → Engine logs "Set parameter X = Y (CLAP ID: Z, denormalized: W)"
5. Load different SFZ → parameters update automatically

## Benefits

- **Dynamic parameters:** No hardcoded CC list, respects SFZ author's intentions
- **Instrument-specific:** Each SFZ exposes only the CCs it uses
- **Zero latency:** HDCC uses normalized values, no MIDI quantization
- **Future-proof:** Automatically supports new SFZ features as sfizz adds them

