# Sforzando GUI Issue

## Summary
Sforzando CLAP plugin GUI does not display in Sonara, while other plugins (LSP, Dragonfly) work correctly.

## Environment
- **OS**: Linux (X11)
- **Plugin**: Sforzando (Plogue Art et Technologie)
- **Plugin Path**: `/home/pelatho/.clap/sforzando.clap`
- **Plugin ID**: `com.Plogue Art et Technologie, Inc.sforzando`
- **Working Plugins**: LSP plugins, Dragonfly plugins

## Current Behavior

### Floating Mode (is_floating=true)
- Plugin reports support for floating mode
- `gui.create()` succeeds
- `gui.set_transient()` **fails** with error: "Failed to set plugin window parent"
- `gui.show()` succeeds
- **Result**: No window appears, no errors after initial set_transient failure

### Embedded Mode (is_floating=false)
- Plugin reports support for embedded mode (actually prefers it over floating)
- Host creates X11 window via xcb
- `gui.create()` succeeds
- `gui.set_parent()` succeeds with host-created window
- `gui.show()` succeeds
- **Result**: Window appears but shows only black screen, no plugin UI renders

### Working Plugin (LSP for comparison)
```
✅ set_transient succeeds
✅ Plugin requests resize to 947x557
✅ GUI appears and renders correctly
✅ Full functionality works
```

## What We've Tried

### 1. Socket Timeout Fix
- **Issue**: Initial timeout errors when reading OpenGui response
- **Fix**: Added 5-second timeout for GUI operations in `subprocess_adapter/gui.rs`
- **Result**: Timeout resolved, but GUI still doesn't appear

### 2. Added CLAP Log Extension
- **Implementation**: Added `HostLog` extension to capture plugin diagnostic messages
- **Result**: Sforzando doesn't output any log messages (may not use the extension)

### 3. Floating Mode Investigation
- **Tried**: `is_floating=true` mode (plugin manages its own window)
- **Added**: `set_transient()` call with X11 root window (0) as per CLAP spec
- **Result**: `set_transient()` fails, no window appears
- **Logs**:
  ```
  WARN ⚠️  Failed to set transient window (non-fatal): Failed to set plugin window parent
  INFO ✅ Plugin GUI opened successfully (floating mode)
  ```

### 4. Embedded Mode Implementation
- **Created**: X11 window using xcb library with proper setup:
  - Window creation with appropriate size
  - Event mask (EXPOSURE, KEY_PRESS)
  - Window mapping
  - Initial Expose event sent
- **Called**: `set_parent()` with host window handle
- **Added**: X11 event loop processing (Expose, ConfigureNotify)
- **Result**: Window appears but remains black (no content rendered)

### 5. Main Thread Callback Pumping
- **Added**: Regular calls to `instance.call_on_main_thread_callback()` in main loop
- **Added**: Initial pumping (10 iterations) after `show()` call
- **Added**: X11 event processing with callback on Expose events
- **Result**: No change - black screen persists in embedded mode

### 6. Mode Preference Testing
- **Tested**: Both floating-first and embedded-first priority
- **Finding**: Sforzando supports both but neither works properly
  - Floating: claims support, fails set_transient, no window
  - Embedded: claims support, window appears, black screen

## Technical Details

### Plugin Capabilities
```
GUI Extension: ✅ Available
API Type: x11
Floating Support: ✅ Yes (but broken)
Embedded Support: ✅ Yes (preferred, but renders black)
Parameters: 0 (normal - parameters appear after loading .sfz file)
```

### Host Implementation
- **Architecture**: Subprocess-based CLAP hosting for crash isolation
- **IPC**: Unix sockets + shared memory for audio
- **GUI Thread**: Main thread in subprocess handles GUI callbacks
- **X11 Integration**: Direct xcb usage for window creation

### Code References
- Plugin host subprocess: `Engine/src/bin/plugin_host.rs`
- GUI opening logic: `open_plugin_gui()` function (line ~1330)
- Main event loop: `run_plugin_host()` function (line ~540)
- X11 event processing: Lines ~676-697

## Hypothesis

### Why Floating Mode Fails
Sforzando's floating mode implementation appears broken:
- `set_transient()` fails (LSP plugins succeed)
- Plugin may not properly create/show its window
- Without successful transient setting, window manager may hide/ignore the window

### Why Embedded Mode Shows Black Screen
Likely causes:
1. **OpenGL Context Missing**: Modern plugin UIs often use GPU rendering
   - Basic xcb window doesn't provide OpenGL context
   - Plugin may render but output goes nowhere

2. **X11 Visual/Depth Mismatch**: Plugin may expect specific visual format
   - Our xcb window uses `COPY_FROM_PARENT` and root visual
   - Plugin might need specific depth (24-bit, 32-bit) or visual class

3. **Event Loop Integration**: Plugin may need full event loop
   - clack example uses `winit::EventLoop` for embedded mode
   - `winit` handles platform integration, events, DPI, etc.
   - Our basic xcb window lacks this infrastructure

## Comparison with Reference Implementation

The clack CPAL example (`../../clack/host/examples/cpal/`) uses:
```rust
// For embedded mode:
let window = event_loop.create_window(
    Window::default_attributes()
        .with_title("Clack CPAL plugin!")
        .with_inner_size(PhysicalSize { height, width })
        .with_resizable(is_resizeable),
)?;

unsafe { gui.set_parent(plugin, ClapWindow::from_window(&window).unwrap())? };
```

Key differences:
- Uses `winit::EventLoop` and `winit::Window`
- `winit` provides cross-platform window abstraction
- Handles OpenGL contexts, events, DPI scaling automatically
- Our implementation uses raw xcb without these features

## Proposed Solutions

### Option 1: Use winit for Embedded Mode (Recommended)
**Pros**:
- Matches reference implementation
- Provides OpenGL context automatically
- Handles events, DPI, window management
- Would likely fix Sforzando

**Cons**:
- More complex integration
- `winit::EventLoop` needs to run on main thread
- May require restructuring subprocess event loop
- Adds dependency

**Implementation**:
```toml
[dependencies]
winit = "0.29"
raw-window-handle = "0.6"
```

### Option 2: Document as Unsupported
**Pros**:
- LSP and Dragonfly plugins already work
- Clear documentation of limitation
- Less maintenance burden

**Cons**:
- Sforzando users affected
- May affect other plugins with similar issues

### Option 3: Investigate X11 Visual/Context
**Pros**:
- Might be simpler than full winit integration
- Could fix just the rendering issue

**Cons**:
- Uncertain if this is the actual problem
- May still need winit for full compatibility
- OpenGL context creation is complex

## Recommendation

**Short term**: Document that Sforzando requires embedded mode with proper window integration, currently unsupported.

**Long term**: Implement winit-based embedded mode support to match clack reference implementation and support the widest range of plugins.

## References

- CLAP GUI specification: https://github.com/free-audio/clap/blob/main/include/clap/ext/gui.h
- clack library: https://github.com/prokopyl/clack
- clack CPAL example (with working embedded GUI): `../../clack/host/examples/cpal/src/host/gui.rs`

## Related Files

- `Engine/src/bin/plugin_host.rs` - Plugin host subprocess
- `Engine/src/audio/devices/clap_host/subprocess_adapter/gui.rs` - GUI adapter
- `Engine/src/audio/ipc/process_manager.rs` - Process management
- `Engine/Cargo.toml` - Dependencies (currently uses `xcb = "1.4"`)

## Testing

To reproduce:
1. Load Sforzando plugin in Sonara
2. Attempt to open GUI via OSC: `/plugin/gui/open`
3. Observe either:
   - Floating mode: No window appears, logs show set_transient failure
   - Embedded mode: Black window appears, no content

To verify LSP plugins work:
1. Load LSP plugin (e.g., `lsp-plugins-clap`)
2. Open GUI
3. Window appears with full UI rendering correctly
