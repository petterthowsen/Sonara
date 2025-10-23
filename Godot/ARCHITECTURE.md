# Sonara UI Architecture

Signal-based MVC architecture for clean separation between data and UI.

## Overview

```
┌─────────────────────────────────────────────────────┐
│              Sonara (Autoload)                      │
│  - Global reference to Editor                       │
└─────────────────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────┐
│              Editor (Controller)                    │
│  - Owns Project instance                            │
│  - Emits signals on data changes                    │
│  - Handles user actions                             │
│  - Coordinates data ↔ UI                            │
└─────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
┌──────────────────┐              ┌──────────────────┐
│  Data Layer      │              │   UI Layer       │
│  (Model)         │              │   (View)         │
├──────────────────┤              ├──────────────────┤
│ Project          │              │ TrackList        │
│ Track            │◄─────────────│ TrackItem        │
│ Channel          │   binds to   │ MixerChannel     │
│ Clip             │              │ TimelineTrack    │
└──────────────────┘              └──────────────────┘
```

## Layers

### 1. Data Layer (Model)
**Location:** `project/`

Pure data classes with no UI dependencies:
- `Project.gd` - Project container
- `Track.gd` - Timeline track
- `Channel.gd` - Mixer channel
- `Clip.gd` - Audio/MIDI clip
- `AutomationLane.gd` - Parameter automation
- etc.

**Characteristics:**
- No signals (just data)
- No UI references
- Full JSON serialization
- Only data manipulation methods

### 2. Editor (Controller)
**Location:** `editor/Editor.gd`

Central coordinator between data and UI:
- Owns the current `Project` instance
- Emits signals when data changes
- Provides methods to modify data
- Handles transport control
- Manages save/load

**Key Signals:**
```gdscript
# Project lifecycle
signal project_opened(project: Project)
signal project_closed()
signal project_saved(path: String)

# Track events
signal track_added(track: Track, index: int)
signal track_removed(index: int)
signal track_property_changed(index: int, property: String, value: Variant)

# Channel events
signal channel_added(channel: Channel, index: int)
signal channel_removed(index: int)
signal channel_property_changed(index: int, property: String, value: Variant)

# Clip events
signal clip_added(track_index: int, clip: Clip, clip_index: int)
signal clip_removed(track_index: int, clip_index: int)

# Transport
signal playback_started()
signal playback_stopped()
signal playhead_moved(ticks: int)
signal tempo_changed(new_tempo: float)
```

### 3. UI Layer (View)
**Location:** `arranger/`, `mixer/`, `components/`

Visual components that display and interact with data:
- `TrackList.gd` - Container for track items
- `TrackItem.gd` - Single track UI
- `MixerChannel.gd` - Mixer channel strip
- `TimelineTrack.gd` - Timeline track view
- etc.

**Characteristics:**
- Listen to Editor signals
- Bind to data objects
- Emit user action signals
- Update visual state

## Data Flow

### User Interaction → Data Change

```
1. User clicks mute button on TrackItem
   ↓
2. TrackItem._on_mute_toggled(pressed)
   ↓
3. Sonara.editor.set_track_property(index, "muted", pressed)
   ↓
4. Editor updates Track.muted
   ↓
5. Editor emits track_property_changed(index, "muted", pressed)
   ↓
6. All TrackItems listening update their UI
   ↓
7. Audio engine receives update (TODO: via OSC)
```

### Project Load → UI Update

```
1. Editor.load_project(path)
   ↓
2. Deserialize JSON → Project instance
   ↓
3. Editor.open_project(project)
   ↓
4. Editor emits project_opened(project)
   ↓
5. Editor emits track_added for each track
   ↓
6. TrackList creates TrackItem for each track
   ↓
7. TrackItem.bind_to_track(track, index)
   ↓
8. TrackItem updates all UI from track data
```

## Example: TrackItem Implementation

```gdscript
class_name TrackItem extends PanelContainer

# Data binding
var track: Track = null
var track_index: int = -1

func _ready():
    # Connect UI signals (user input)
    mute_toggle.toggled.connect(_on_mute_toggled)
    
    # Connect Editor signals (data changes)
    Sonara.editor.track_property_changed.connect(_on_track_property_changed)

func bind_to_track(t: Track, idx: int):
    track = t
    track_index = idx
    _update_from_track()

func _update_from_track():
    # Update UI from data
    label.text = track.name
    mute_toggle.set_pressed_no_signal(track.muted)

# User clicked mute button
func _on_mute_toggled(pressed: bool):
    # Tell Editor to update data
    Sonara.editor.set_track_property(track_index, "muted", pressed)

# Editor notified us of data change
func _on_track_property_changed(index: int, property: String, value: Variant):
    if index != track_index:
        return
    
    match property:
        "muted":
            mute_toggle.set_pressed_no_signal(value)
```

## Benefits

✅ **Separation of Concerns**
- Data layer is pure and testable
- UI can be rebuilt without losing data
- Multiple views can show same data

✅ **Undo/Redo Ready**
- All changes go through Editor
- Easy to add command pattern later

✅ **Audio Engine Sync**
- Editor can forward changes to Rust engine via OSC
- Single point of truth for state

✅ **Hot Reload Safe**
- UI can rebuild from data on scene reload
- No state lost in UI components

✅ **Debuggable**
- Clear signal flow
- Easy to trace data changes
- Single source of truth

## Adding New Features

### Adding a New Track Property

1. **Add to Track.gd:**
```gdscript
var new_property: bool = false
```

2. **Add to Track.to_json():**
```gdscript
"new_property": new_property
```

3. **Add to Editor.set_track_property():**
```gdscript
match property:
    "new_property": track.new_property = value
```

4. **Add to TrackItem._on_track_property_changed():**
```gdscript
match property:
    "new_property":
        # Update UI
```

### Adding a New UI Component

1. **Create the component:**
```gdscript
class_name MyComponent extends Control

var data_object = null
var data_index: int = -1

func _ready():
    Sonara.editor.my_signal.connect(_on_my_signal)

func bind_to_data(obj, idx):
    data_object = obj
    data_index = idx
    _update_from_data()
```

2. **Create container that listens to Editor:**
```gdscript
class_name MyContainer extends VBoxContainer

func _ready():
    Sonara.editor.data_added.connect(_on_data_added)

func _on_data_added(data, index):
    var component = MyComponentScene.instantiate()
    add_child(component)
    component.bind_to_data(data, index)
```

## Best Practices

1. **Never modify data directly from UI**
   - ❌ `track.muted = true`
   - ✅ `Sonara.editor.set_track_property(index, "muted", true)`

2. **Use `set_*_no_signal()` to avoid loops**
   - When updating UI from data changes
   - Prevents infinite signal loops

3. **Check `Engine.is_editor_hint()` in @tool scripts**
   - Don't connect signals in editor preview
   - Only connect at runtime

4. **Store indices, not references**
   - UI stores `track_index`, not `track` reference
   - Safer when tracks are removed/reordered

5. **Validate indices before use**
   - Always check bounds before accessing arrays
   - Handle removed items gracefully

## Future Enhancements

- [ ] Undo/Redo system (command pattern)
- [ ] OSC integration for audio engine sync
- [ ] Multi-selection support
- [ ] Drag & drop reordering
- [ ] Copy/paste tracks and clips
- [ ] Project templates
