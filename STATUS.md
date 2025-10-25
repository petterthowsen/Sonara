# Project Status

## Current Work: Embedded Plugin GUI System

### Working ✅
- **Winit threaded architecture** - Dedicated thread running `event_loop.run()` with `any_thread()` flag
- **Window creation** - Windows successfully created with proper X11 handles
- **Plugin embedding** - Plugins successfully call `set_parent()` and create child windows
- **IPC protocol** - Full stack passes window handles from OSC → Audio → IPC → Plugin subprocess
- **Automatic sizing** - Host queries and respects plugin's preferred initial GUI size
- **Dynamic resizing** - Plugins can request resize at any time; host updates parent window
- **Resizability support** - Host queries `can_resize()` and respects plugin preferences
- **Clean shutdown** - Fixed X Error on close by hiding window before plugin cleanup
- **LSP plugins** - Continue to work in floating mode (regression test passed)
- **Dragonfly plugins** - Working perfectly in embedded mode with correct sizing

### Not Working ❌
- **Sforzando rendering** - Window appears but shows BLACK SCREEN
  - Window exists and is visible, plugin embeds successfully
  - Plugin creates its GUI window and registers timers
  - **But nothing renders** - completely black
  - Resizing shows brief glitchy artifacts but no actual content
  - **Hypothesis**: May require OpenGL context or specific X11 visual
  - **Status**: Needs retesting after recent fixes

### Recent Fixes
1. **Automatic window sizing** - Host now queries `gui_ext.get_size()` on open and initializes window to plugin's preferred dimensions
2. **Dynamic resize support** - Implemented `request_resize()` callback, full IPC propagation, and window manager resize
3. **Resizability flag** - Query `gui_ext.can_resize()` and track per-plugin
4. **X Error fix** - Window hidden on close, `PluginGuiClosed` status waits for plugin cleanup confirmation, then window destroyed safely
5. **Reopen black window fix** - Always reset `gui_open` flag even if IPC times out, and reuse existing window if close failed
6. **Window reuse** - If window still exists from failed close, reuse it instead of creating orphaned windows

### Implementation Evolution

**Initial attempt (pump_events):**
- Used `EventLoop::pump_events()` in OSC thread
- Windows never actually created - `pump_events()` doesn't fire `NewEvents` reliably
- Failed completely

**Current implementation (dedicated thread):**
- Dedicated background thread running `event_loop.run()`
- Used `EventLoopBuilder::with_any_thread(true)` to allow non-main-thread event loop
- Synchronous window creation via channels - blocks until window created
- Windows DO get created successfully
- But Sforzando still doesn't render

### What Changed From Original

**Removed:**
- `xcb` dependency
- Manual X11 window creation in plugin_host.rs
- X11 event processing loop in plugin subprocess
- `PluginState.x11_connection` and `x11_window` fields

**Added:**
- `winit = "0.30"` and `raw-window-handle = "0.6"` dependencies
- `WindowManager` module with dedicated thread for winit event loop
- Window handle parameter through entire stack:
  - OSC handler creates window via WindowManager
  - AudioCommand::OpenPluginGui includes handle
  - SubprocessClapAdapter.open_gui_with_handle() accepts handle
  - PluginCommand::OpenGui includes handle
  - Plugin subprocess uses provided handle for set_parent()

**Current Architecture:**
```
Main Thread (OSC)              Window Thread              Plugin Subprocess
─────────────────              ─────────────              ─────────────────
create_window() ─────────┐
                         │
      [sync_channel]─────┼──> event_loop.run()
                         │    NewEvents()
                         │    create_window()
                         │    get X11 handle
                         │
      [sync_channel]<────┼─── send(0x8600004)
                         │
window_handle ───────────┘

OpenPluginGui { 0x8600004 } ────────────────────────> set_parent(0x8600004)
                                                       creates child: 0x8800000
                                                       registers timers
                                                       ❌ BLACK SCREEN
```

### Testing Results
- ✅ **LSP plugins**: Work in floating mode (no window handle needed)
- ✅ **Dragonfly plugins**: Work perfectly in embedded mode with proper sizing
- ❌ **Sforzando embedded**: Window created, plugin embeds, but BLACK SCREEN (needs retest)
- ❓ **Sforzando floating**: set_transient() still fails (different issue)

### Possible Solutions to Explore

1. **Add GL context**: Use `glutin` to create OpenGL context for the window
   - Most likely solution if Sforzando uses GPU rendering
   - Requires significant refactor
   - Would match professional DAWs that support GPU-rendered plugin GUIs

2. **Try software rendering**: Use `softbuffer` for CPU-based pixel buffer
   - Might work if Sforzando can render to pixels directly
   - Simpler than GL but potentially slower
   - May not work if plugin specifically needs GL

3. **Test with clack example**: Run clack's cpal example with Sforzando
   - If it also shows black screen → confirms it's a general issue
   - If it works → we're missing something they do
   - Quick way to validate our hypothesis

4. **Document as limitation**: Accept that some plugins need GL contexts
   - Focus on plugins that work (LSP, Dragonfly, etc.)
   - Document Sforzando as incompatible without GL support
   - Revisit if/when we add full GL rendering support

## Previous Work
- ✅ **COMPLETED:** Fixed critical IO Safety violation bug in plugin shutdown!
- ✅ **COMPLETED & DEBUGGED:** Fully bidirectional plugin parameter synchronization working end-to-end!
- Plugins notify host of parameter changes → Engine forwards via OSC → Godot UI updates automatically.
- Plugin subprocess shutdown now safe and clean - no more crashes on project clear.

## Known Issues

**Non-Critical:**
- IPC timeout warning on CloseGui (subprocess sends response but engine recv times out)
  - Doesn't affect functionality as we now always reset gui_open flag
  - Response arrives successfully (~8ms later) but socket read times out
  - Should investigate recv timeout configuration

## Next Steps

**Immediate:**
1. ✅ DONE: Implement automatic window sizing based on plugin preferences
2. ✅ DONE: Implement dynamic resize support for plugins
3. ✅ DONE: Fix X Error on window close
4. ✅ DONE: Fix black window on reopen after close
5. ✅ DONE: Dragonfly plugins working perfectly with multiple close/reopen cycles
6. 🔄 TODO: Retest Sforzando with all fixes in place

**Future:**
- Fix IPC recv timeout on CloseGui (non-critical)
- Consider preset management (save/load plugin states)
- Multi-output plugin support
- Investigate if Sforzando needs specific X11 visual or GL context

## Lessons Learned
- `pump_events()` is unreliable for window creation - use `run()` in dedicated thread
- X11 on non-main thread requires `with_any_thread(true)`
- Basic winit windows successfully create and embed plugin child windows
- Most plugins (LSP, Dragonfly) work perfectly with basic winit windows
- Must query and respect plugin's preferred size via `get_size()` for proper initial layout
- Must implement `request_resize()` callback for plugins that dynamically change size
- **Window close synchronization critical**: Must wait for plugin to confirm cleanup (via `PluginGuiClosed` status) before destroying window to avoid X11 BadWindow errors
- Destroying parent window while plugin subprocess is unmapping child causes X Error
- Some plugins (Sforzando) may have special rendering requirements
