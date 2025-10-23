# Project Data Model

Core data structures for the DAW project system.

## Overview

The project data model separates **Tracks** (timeline/sequencing) from **Channels** (audio routing/mixing), providing flexibility while maintaining sensible defaults.

## Architecture

```
Project
├── Tracks (timeline)
│   ├── Clips (audio/MIDI)
│   └── Automation Lanes
│       └── Automation Points
└── Channels (mixer)
    ├── Volume, Pan, Mute, Solo
    ├── FX Chain
    └── Send Channels
```

## Classes

### Project
Main project container with tempo, time signature, and PPQ settings.

**Key Features:**
- PPQ-based timing (960 ticks per quarter note)
- Automatic master channel creation
- Helper methods for creating tracks with channels
- Full JSON serialization

### Track
Timeline track containing clips and automation.

**Track Types:**
- `AUDIO` - Audio recording/playback track (contains audio clips)
- `INSTRUMENT` - Virtual instrument track (contains MIDI clips → instrument plugin → audio)
- `GROUP` - Folder/container for organizing tracks (can have optional channel for group processing)

**Properties:**
- Clips (audio/MIDI regions)
- Automation lanes
- Default channel routing
- UI state (height, folded, mute, solo, armed)

### Channel
Mixer channel for audio processing and routing.

**Pan Modes (Cubase-style):**
- `STEREO_COMBINED` - Single pan knob (constant power, default)
- `STEREO_DUAL` - Separate L/R pan controls
- `STEREO_BALANCE` - Simple L/R balance
- `MONO` - Mono to stereo panning

**Features:**
- Volume (dB), pan, mute, solo, phase invert
- Flexible routing (output channel + sends)
- FX chain support (placeholder)
- Real-time metering (peak/RMS)

### Clip
Audio or MIDI clip on the timeline.

**Properties:**
- PPQ-based position and duration
- Clip offset (for trimming)
- Gain adjustment
- Fade in/out
- Audio file path or MIDI events

### AutomationLane
Parameter automation over time.

**Features:**
- Target any parameter by path
- Multiple automation points
- Linear interpolation (curve types planned)
- Visual state (height, color, visibility)

### AutomationPoint
Single automation point with value and curve type.

**Curve Types:**
- `LINEAR` - Straight line interpolation
- `BEZIER` - Smooth curves (planned)
- `STEP` - Stepped values
- `EXPONENTIAL` - Exponential curves (planned)

### SendConfig
Auxiliary send routing configuration.

**Properties:**
- Target channel
- Send amount (dB)
- Pre/post fader
- Mute

## Usage Examples

### Create a New Project

```gdscript
var project = Project.new()
project.project_name = "My Song"
project.tempo = 128.0
project.time_numerator = 4
```

### Create an Instrument Track

```gdscript
# Creates both track and channel, automatically routed
var result = project.create_instrument_track("Synth Lead")
var track = result["track"]
var channel = result["channel"]

# Customize
track.color = Color.CYAN
channel.pan_mode = Channel.PanMode.STEREO_COMBINED
channel.volume = -6.0  # -6 dB
```

### Add a Clip to a Track

```gdscript
var clip = Clip.new()
clip.name = "Intro"
clip.type = Clip.ClipType.AUDIO
clip.start_ticks = 0  # Bar 1
clip.duration_ticks = 3840 * 4  # 4 bars at PPQ=960
clip.audio_file_path = "res://audio/intro.wav"

track.clips.append(clip)
```

### Create Automation

```gdscript
var auto_lane = AutomationLane.new()
auto_lane.parameter_path = "channel.volume"
auto_lane.parameter_name = "Volume"

# Add points
var point1 = AutomationPoint.new()
point1.tick = 0
point1.value = -12.0  # Start at -12 dB

var point2 = AutomationPoint.new()
point2.tick = 3840  # 1 bar later
point2.value = 0.0  # Fade to 0 dB

auto_lane.points.append(point1)
auto_lane.points.append(point2)

track.automation_lanes.append(auto_lane)
```

### Create a Folder Track

```gdscript
# Create folder with channel (for folder processing)
var result = project.create_folder_track("Drums", true)
var drums_folder = result["track"]
var drums_channel = result["channel"]

# Add tracks to folder
var kick_idx = project.tracks.find(kick_track)
var snare_idx = project.tracks.find(snare_track)
var folder_idx = project.tracks.find(drums_folder)

project.add_track_to_folder(kick_idx, folder_idx)
project.add_track_to_folder(snare_idx, folder_idx)

# Process entire folder through drums_channel
drums_channel.volume = -3.0  # Folder volume
```

### Add a Send

```gdscript
# Create reverb bus
var reverb_bus = project.create_bus_channel("Reverb")

# Add send from channel to reverb
var send = SendConfig.new()
send.target_channel_id = project.channels.find(reverb_bus)
send.amount = -18.0  # -18 dB send level
send.pre_fader = false

channel.send_channels.append(send)
```

### Pan Mode Examples

```gdscript
# Cubase-style stereo combined (default)
channel.pan_mode = Channel.PanMode.STEREO_COMBINED
channel.pan = 0.5  # Pan right

# Dual panner (independent L/R)
channel.pan_mode = Channel.PanMode.STEREO_DUAL
channel.pan_left = -0.3
channel.pan_right = 0.7

# Simple balance
channel.pan_mode = Channel.PanMode.STEREO_BALANCE
channel.pan = -0.5  # More left

# Get pan coefficients for audio processing
var coeffs = channel.get_pan_coefficients()
# Returns: {left_to_left, right_to_right, left_to_right, right_to_left}
```

### Save/Load Project

```gdscript
# Save
var json_data = project.to_json()
var json_string = JSON.stringify(json_data, "\t")
var file = FileAccess.open("user://project.json", FileAccess.WRITE)
file.store_string(json_string)
file.close()

# Load
var file = FileAccess.open("user://project.json", FileAccess.READ)
var json_string = file.get_as_text()
file.close()
var json_data = JSON.parse_string(json_string)
var loaded_project = Project.from_json(json_data)
```

## Time Conversion Utilities

You may want to add these helper functions to `Project.gd`:

```gdscript
# Convert ticks to samples
func ticks_to_samples(ticks: int) -> int:
    var seconds_per_tick = 60.0 / (tempo * ppq)
    return int(ticks * seconds_per_tick * sample_rate)

# Convert samples to ticks
func samples_to_ticks(samples: int) -> int:
    var seconds = float(samples) / float(sample_rate)
    var ticks_per_second = (tempo * ppq) / 60.0
    return int(seconds * ticks_per_second)

# Convert ticks to bars/beats/ticks
func ticks_to_bbt(ticks: int) -> Dictionary:
    var ticks_per_bar = ppq * time_numerator
    var bar = ticks / ticks_per_bar
    var remaining = ticks % ticks_per_bar
    var beat = remaining / ppq
    var tick = remaining % ppq
    return {"bar": bar + 1, "beat": beat + 1, "tick": tick}
```

## Design Principles

1. **Separation of Concerns**: Tracks handle timeline, channels handle audio
2. **PPQ-Based Timing**: All positions use ticks for sample-accurate, tempo-independent positioning
3. **Flexible Routing**: Tracks can route to any channel, channels can route to any output
4. **Sensible Defaults**: Helper methods create common configurations automatically
5. **Full Serialization**: Complete project state can be saved/loaded as JSON

## Future Enhancements

- [ ] MIDI event data structures
- [ ] Effect/instrument plugin system
- [ ] Tempo automation
- [ ] Time signature changes
- [ ] Marker/region system
- [ ] Undo/redo support
- [ ] Project templates
