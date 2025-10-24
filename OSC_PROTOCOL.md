# OSC Protocol Specification

Communication between Godot (UI) and Rust (Audio Engine) over UDP on localhost.

**Ports:**
- Godot sends to: `127.0.0.1:7000` (Rust listens)
- Rust sends to: `127.0.0.1:7001` (Godot listens)

## Message Types

### Transport Control (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/transport/play` | - | Start playback |
| `/transport/pause` | - | Pause playback |
| `/transport/stop` | - | Stop and reset to 0 |
| `/transport/seek` | `i:ticks` | Seek to tick position |
| `/transport/tempo` | `f:bpm` | Set tempo |
| `/transport/time_signature` | `i:numerator, i:denominator` | Set time signature |

### Transport Status (Rust -> Godot)

| Address | Args | Description |
|---------|------|-------------|
| `/status/playhead` | `i:ticks` | Current playhead position (sent periodically) |
| `/status/playing` | `i:0_or_1` | Playback state (0=stopped, 1=playing) |

### Project Setup (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/project/init` | `f:tempo, i:numerator, i:denominator, i:ppq, i:sample_rate` | Initialize project settings |
| `/project/clear` | - | Clear all channels and tracks |

### Channel Management (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/channel/create` | `i:channel_id, s:name` | Create channel with ID |
| `/channel/volume` | `i:channel_id, f:db` | Set channel volume in dB |
| `/channel/pan` | `i:channel_id, f:pan` | Set pan (-1.0 to 1.0) |
| `/channel/mute` | `i:channel_id, i:0_or_1` | Set mute state |
| `/channel/solo` | `i:channel_id, i:0_or_1` | Set solo state |
| `/channel/route` | `i:channel_id, i:output_channel_id` | Set output routing (-1 for none) |

### Channel Metering (Rust -> Godot)

| Address | Args | Description |
|---------|------|-------------|
| `/channel/{id}/peak` | `f:peak_left, f:peak_right` | Peak levels (linear 0.0-1.0+) |

### Track Management (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/track/{id}/create` | `i:channel_id` | Create track with ID, routed to channel |
| `/track/{id}/clear_midi` | - | Clear all MIDI notes for track |

### Clip Management (Godot -> Rust) - NEW

| Address | Args | Description |
|---------|------|-------------|
| `/clip/create` | `s:clip_id, s:clip_type, s:name` | Create clip in global pool (type: "midi" or "audio") |
| `/clip/delete` | `s:clip_id` | Delete clip from pool |
| `/clip/{id}/add_note` | `i:note_id, i:note, i:start_tick, i:duration, i:velocity` | Add MIDI note to clip (relative to clip start) |
| `/clip/{id}/remove_note` | `i:note_id` | Remove MIDI note from clip |
| `/clip/{id}/update_note` | `i:note_id, i:note, i:start_tick, i:duration, i:velocity` | Update MIDI note in clip |

### ClipInstance Management (Godot -> Rust) - NEW

| Address | Args | Description |
|---------|------|-------------|
| `/track/{id}/add_instance` | `s:instance_id, s:clip_id, i:start_tick, i:duration` | Add clip instance to track timeline |
| `/track/{id}/remove_instance` | `s:instance_id` | Remove clip instance from track |
| `/track/{id}/instance/{id}/set_position` | `i:start_tick, i:duration` | Update instance position |
| `/track/{id}/instance/{id}/set_transpose` | `i:semitones` | Set instance transpose (-12 to +12) |
| `/track/{id}/instance/{id}/set_gain` | `f:db` | Set instance gain offset in dB |
| `/track/{id}/instance/{id}/set_mute` | `i:0_or_1` | Set instance mute state |
| `/track/{id}/instance/{id}/set_loop` | `i:enabled, i:start_tick, i:length` | Configure instance looping |

### Device Management (Godot -> Rust)

| Address | Args | Description |
|---------|------|-------------|
| `/channel/{id}/add_device` | `s:device_id, i:position, i:active?, i:enabled?` | Add device to channel (active/enabled default to 1) |
| `/channel/{id}/remove_device` | `i:position` | Remove device from channel |
| `/channel/{id}/clear_devices` | - | Remove all devices from channel |
| `/channel/{id}/device/{position}/param/{param_id}` | `f:normalized_value` | Set device parameter (0.0-1.0) |
| `/channel/{id}/device/{position}/activate` | `i:active` | Activate/deactivate device (1=load, 0=unload) |
| `/channel/{id}/device/{position}/enable` | `i:enabled` | Enable/disable device (1=on, 0=bypass) |

### Device State Updates (Rust -> Godot)

| Address | Args | Description |
|---------|------|-------------|
| `/channel/{id}/device/{position}/active` | `i:0_or_1` | Device activated/deactivated (engine confirms state) |
| `/channel/{id}/device/{position}/enabled` | `i:0_or_1` | Device enabled/disabled (engine confirms state) |

#### Built-In Devices

**Oscillator (`sonara.builtin.oscillator`)**
- **Type:** Instrument (receives MIDI) 
- **Params:**
  - `0`: Waveform (0.0-1.0: Sine, Square, Sawtooth, Triangle)
  - `1`: Amplitude (0.0-1.0)

**Delay (`sonara.builtin.delay`)**
- **Type:** Effect
- **Params:**
  - `0`: Delay Time (1-5000ms, normalized 0.0-1.0)
  - `1`: Wet Amount (0.0-1.0)

#### CLAP Plugins

**Plugin Discovery (Godot -> Rust)**
```
/plugin/scan
```
Scans standard CLAP plugin directories and discovers available plugins.

**Response:**
```
/plugin/scan_complete [i:count]
```

**Adding Plugins (same as built-in devices!)**
```
/channel/{id}/add_device [s:plugin_id, i:position, i:active?, i:enabled?]
```
- **active**: 1=load plugin (default), 0=don't load (save RAM)
- **enabled**: 1=process audio (default), 0=bypass

Examples:
```bash
# Load active + enabled (default)
/channel/2/add_device ["michaelwillis.dragonfly.room", -1]

# Load inactive (template with 200 plugins)
/channel/2/add_device ["com.heavysynth", -1, 0, 1]

# Load bypassed
/channel/2/add_device ["in.lsp-plug.compressor_mono", -1, 1, 0]
```

**Plugin State Management**
```
/plugin/state/save [i:channel_id, i:device_position]
/plugin/state/load [i:channel_id, i:device_position, s:state_base64]
```

**Device Lifecycle Control**
```
/channel/{id}/device/{position}/activate [i:active]
/channel/{id}/device/{position}/enable [i:enabled]
```
- **activate**: Load/unload device (affects RAM, parameters visible/hidden)
- **enable**: Bypass device (zero-latency, maintains state)

**Plugin GUI Control (CLAP plugins only)**
```
/channel/{id}/device/{position}/gui/open
/channel/{id}/device/{position}/gui/close
```
- Opens/closes floating plugin GUI window
- Only works for CLAP plugins that support the GUI extension
- Can be called while plugin is activated and processing audio
- GUI state is managed by the plugin, not the host

**Query Parameters (works for both built-in and plugins)**
```
/plugin/get_parameters [i:channel_id, i:device_position]
```

See `PLUGIN_OSC_PROTOCOL.md` for detailed plugin documentation.

**Benefits of Active/Enabled System**
- **Film scoring templates**: Load 200 plugins, keep 150 inactive (~2GB RAM vs ~10GB)
- **A/B testing**: Toggle bypass instantly without reloading
- **CPU management**: Deactivate unused plugins during playback

#### Example Usage
```gdscript
# Add oscillator + delay to channel 2
AudioEngineOSC.send("/channel/2/add_device", ["sonara.builtin.oscillator", -1])
AudioEngineOSC.send("/channel/2/add_device", ["sonara.builtin.delay", -1])

# Configure oscillator (sine wave, 60% volume)
AudioEngineOSC.send("/channel/2/device/0/param/0", [0.0])  # Sine
AudioEngineOSC.send("/channel/2/device/0/param/1", [0.6])  # Amplitude

# Configure delay (250ms, 50% wet)
AudioEngineOSC.send("/channel/2/device/1/param/0", [0.05])  # 250ms
AudioEngineOSC.send("/channel/2/device/1/param/1", [0.5])   # Wet mix
```

## Timing and Synchronization

- **Audio engine is master**: Rust audio callback drives timing
- **Playhead updates**: Sent every ~50ms (20Hz) during playback
- **Godot playhead**: Interpolates smoothly between updates for UI
- **Corrective updates**: Godot adjusts if drift detected

## Connection Handshake

1. Godot starts and creates OSCClient + OSCServer
2. Rust engine starts listening on port 7000
3. Godot sends `/project/init` message
4. Rust responds with `/status/playing 0` to confirm connection
5. Godot sends channel/track setup
6. Godot sends `/transport/play` to start

## Data Flow Example

### Playing MIDI Using Clip/ClipInstance Architecture

1. **Setup:**
   - Godot: `/project/init 120.0 4 4 960 48000`
   - Godot: `/channel/0/create "Master"`
   - Godot: `/channel/1/create "Synth"`
   - Godot: `/channel/1/route 0` (route Synth -> Master)
   - Godot: `/track/0/create 1` (track 0 -> channel 1)

2. **Create Clip and Add MIDI Notes:**
   - Godot: `/clip/create "clip_001" "midi" "Bass Pattern"`
   - Godot: `/clip/clip_001/add_note 1 60 0 480 100` (C3 at tick 0, 1 beat)
   - Godot: `/clip/clip_001/add_note 2 64 960 480 100` (E3 at tick 960, 1 beat)

3. **Place Clip Instances on Timeline:**
   - Godot: `/track/0/add_instance "instance_001" "clip_001" 0 1920` (place at tick 0, 2 bars long)
   - Godot: `/track/0/add_instance "instance_002" "clip_001" 3840 1920` (place at tick 3840, transposed)
   - Godot: `/track/0/instance/instance_002/set_transpose 12` (transpose +12 semitones)

4. **Playback:**
   - Godot: `/transport/play`
   - Rust: Resolves clip instances → notes from clip pool
   - Rust: Applies transpose to instance_002
   - Rust: Generates sine waves at specified MIDI notes
   - Rust: `/status/playhead 0` (tick 0)
   - Rust: `/status/playhead 240` (tick 240)
   - Rust: `/channel/1/peak 0.5 0.5` (channel 1 meters)
   - Rust: `/channel/0/peak 0.4 0.4` (master meters)
   - ... continues ...

5. **Edit Clip (affects all instances):**
   - Godot: `/clip/clip_001/update_note 1 60 0 240 100` (shorten first note)
   - Rust: Both instance_001 and instance_002 now play shortened note

6. **Stop:**
   - Godot: `/transport/stop`
   - Rust: `/status/playing 0`
   - Rust: `/status/playhead 0`
