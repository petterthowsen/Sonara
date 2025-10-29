# Asset System Documentation

## Overview

The Sonara Asset System provides a flexible, provider-based architecture for discovering and managing musical assets (audio files, MIDI clips, devices, etc.). It supports:

- **Auto-discovery** of assets from configured directories
- **Hot-reloading** when files change on disk
- **Metadata management** (favorites, tags, last used timestamps)
- **Unified query interface** across multiple asset sources
- **Drag-drop integration** with the Browser UI

## Architecture

### Core Classes

#### `Asset.gd`
The fundamental data class representing a single asset.

**Properties:**
- `type: Asset.TYPE` - Audio, Midi, Device, SFZ, or SoundFont
- `name: String` - Display name
- `path: String` - Absolute file path
- `favorite: bool` - User-marked favorites
- `tags: Array[String]` - Custom tags for organization
- `last_used: int` - Unix timestamp of last use
- `file_size_bytes: int` - Size on disk
- `file_modified_time: int` - For hot-reload detection

**Helper Methods:**
- `get_display_name() -> String` - Filename without extension
- `get_file_extension() -> String` - File extension
- `is_audio() -> bool`, `is_midi() -> bool`, `is_sfz() -> bool`, `is_soundfont() -> bool` - Type checkers
- `get_icon() -> String` - Godot icon name for UI
- `mark_as_used() -> void` - Update last_used timestamp
- `has_changed(current_mod_time: int) -> bool` - Check if file changed

#### `AssetProvider.gd` (Abstract)
Base class for asset discovery implementations.

**Signals:**
- `assets_changed(added, removed, modified)` - Emitted when assets change

**Virtual Methods:**
- `initialize() -> void` - One-time setup
- `scan() -> void` - Discover/update assets
- `get_assets() -> Array[Asset]` - Get all managed assets
- `get_assets_by_type(type) -> Array[Asset]` - Filter by type
- `is_ready() -> bool` - Check if initialized

#### `FileSystemAssetProvider.gd`
Concrete provider that scans directories for audio/MIDI files.

**Supported Formats:**
- Audio: `.wav`, `.mp3`, `.ogg`, `.flac`
- MIDI: `.mid`, `.midi`

**Features:**
- Recursive directory scanning
- Hidden file filtering (names starting with `.`)
- Hot-reload via `get_tree().create_timer()`
- Modification time tracking for change detection
- Configurable scan interval (default: 5 seconds)
- Asset caching to `samples_cache.json` for instant startup

**Configuration:**
```gdscript
# In Sonara config:
{
  "assets": {
    "samples": {
      "paths": ["~/Music/Samples", "~/Music/MIDI"]
    },
    "scan_interval_seconds": 5.0
  }
}
```

#### `DeviceAssetProvider.gd`
Stub provider for future LV2/CLAP plugin discovery (Phase 4).

#### `SfzAssetProvider.gd`
Concrete provider that scans directories for SFZ sampler instrument files.

**Supported Formats:**
- SFZ: `.sfz`

**Features:**
- Recursive directory scanning
- Hidden file filtering (names starting with `.`)
- Hot-reload via `get_tree().create_timer()`
- Modification time tracking for change detection
- Configurable scan interval (inherits from global assets config)
- Assets are classified as `TYPE.SFZ` (distinct from regular audio files)
- Asset caching to `sfz_cache.json` for instant startup

**Configuration:**
```gdscript
# In Sonara config:
{
  "assets": {
    "sfz": {
      "paths": ["~/Music/SFZ", "~/Samples"]
    },
    "scan_interval_seconds": 5.0,
    "enabled_providers": ["filesystem", "devices", "sfz"]
  }
}
```

**Notes:**
- SFZ files are loaded into the built-in sfizz sampler device
- Use `/channel/{id}/device/{pos}/load_file` OSC command to load SFZ into sfizz
- Supports the full SFZ spec via the sfizz engine

#### `AssetService.gd` (Singleton Autoload)
Central registry and query interface for all asset providers.

**Startup Behavior:**
- On startup, AssetService does NOT perform an initial scan
- Relies on hot-reload timers (first scan after `scan_interval_seconds`)
- Users can manually trigger scan via Edit → Scan Assets
- Faster startup time, especially with large asset libraries

**Key Methods:**
```gdscript
# Queries
get_all_assets() -> Array[Asset]
get_assets_by_type(type: Asset.TYPE) -> Array[Asset]
get_audio_assets() -> Array[Asset]
get_midi_assets() -> Array[Asset]
get_device_assets() -> Array[Asset]
get_sfz_assets() -> Array[Asset]
get_soundfont_assets() -> Array[Asset]
find_asset(path: String) -> Asset

# Metadata management
set_favorite(asset_path: String, is_favorite: bool)
add_tag(asset_path: String, tag: String)
remove_tag(asset_path: String, tag: String)
mark_asset_used(asset_path: String)

# Control
scan() -> void  # Force rescan
is_ready() -> bool
```

**Signals:**
- `assets_updated` - Any assets changed
- `asset_added(asset)` - New asset discovered
- `asset_removed(asset)` - Asset deleted
- `asset_modified(asset)` - Asset changed

#### `Browser.gd`
UI component displaying available assets in an ItemList with drag-drop support.

**Features:**
- Displays assets grouped by type (Audio, MIDI, Devices)
- Live updates when assets are added/removed
- Drag-drop data export for timeline integration
- Asset selection signals

**Signals:**
- `asset_selected(asset)` - User clicked asset
- `asset_requested_drag(asset)` - Drag initiated

## Usage Examples

### Query assets
```gdscript
# Get all audio files
var audio_assets = AssetService.get_audio_assets()

# Find specific asset
var asset = AssetService.find_asset("/path/to/kick.wav")

# Filter by type
var midis = AssetService.get_assets_by_type(Asset.TYPE.Midi)
```

### Manage metadata
```gdscript
# Mark as favorite
AssetService.set_favorite("/path/to/sample.wav", true)

# Add tags
AssetService.add_tag("/path/to/sample.wav", "drums")
AssetService.add_tag("/path/to/sample.wav", "percussion")

# Track usage
AssetService.mark_asset_used("/path/to/sample.wav")
```

### Listen for changes
```gdscript
func _ready():
    AssetService.asset_added.connect(_on_asset_added)
    AssetService.assets_updated.connect(_on_assets_updated)

func _on_asset_added(asset: Asset):
    print("New asset: %s" % asset.get_display_name())
```

### Drag-drop integration (Browser to Timeline)
```gdscript
# In Browser:
signal asset_requested_drag(asset: Asset)

# In Timeline/Arranger:
func _can_drop_data(position, data):
    return data is Asset

func _drop_data(position, data):
    if data.is_audio():
        create_audio_clip_from_asset(data)
    elif data.is_midi():
        create_midi_clip_from_asset(data)
```

## Configuration

Configuration is stored in `~/.config/sonara/` directory:

### config.json
Main configuration file with asset discovery settings:
```json
{
  "assets": {
    "samples": {
      "paths": [
        "~/Music/Samples",
        "~/Music/MIDI"
      ]
    },
    "sfz": {
      "paths": [
        "~/Music/SFZ",
        "~/Samples"
      ]
    },
    "scan_interval_seconds": 5.0,
    "enabled_providers": ["filesystem", "devices", "sfz"]
  }
}
```

Access via:
```gdscript
var scan_paths = Sonara.get_config("assets/samples/paths", [])
var sfz_paths = Sonara.get_config("assets/sfz/paths", [])
```

### assets.json
Separate cache file for asset metadata (favorites, tags, usage tracking):
```json
{
  "/absolute/path/to/asset.wav": {
    "favorite": true,
    "tags": ["drums", "kick"],
    "last_used": 1729320000
  },
  "/absolute/path/to/melody.mid": {
    "favorite": false,
    "tags": ["ambient", "pad"],
    "last_used": 1729310000
  }
}
```

## Future Enhancements (Post-MVP)

1. **Search & filtering** - Full-text search in Browser UI
2. **Waveform preview** - Visual feedback for audio assets
3. **Audio playback** - Preview assets before using
4. **Project-local library** - Assets stored in project.json
5. **Plugin discovery** - DeviceAssetProvider implementation
6. **Asset tagging UI** - Edit tags/favorites in Browser
7. **Recent assets** - Quick access to last-used items
8. **Native filesystem watching** - When Godot adds full FileSystemWatcher API

## Common Patterns

### Create a custom provider
```gdscript
class_name MyAssetProvider extends AssetProvider

func initialize(tree: SceneTree) -> void:
    # Setup
    pass

func scan() -> void:
    var assets: Array[Asset] = []
    # ... discover assets ...
    _detect_changes(assets)

func get_assets() -> Array[Asset]:
    return _assets
```

### Display in UI
```gdscript
func _ready():
    AssetService.assets_updated.connect(_refresh_display)
    _refresh_display()

func _refresh_display():
    for asset in AssetService.get_audio_assets():
        add_item_to_list(asset.get_display_name())
```

### Handle dropped assets
```gdscript
func _can_drop_data(pos, data):
    return data is Asset and data.is_audio()

func _drop_data(pos, data):
    var clip = Clip.new()
    clip.audio_path = data.path
    add_clip_to_track(clip)
    AssetService.mark_asset_used(data.path)
```
