# Project Status

## Current Work: Winit Integration for Plugin GUIs (BLOCKED)

### Working ✅
- **Winit threaded architecture** - Dedicated thread running `event_loop.run()` with `any_thread()` flag
- **Window creation** - Windows successfully created with proper X11 handles (e.g., 0x8600004)
- **Plugin embedding** - Sforzando successfully calls `set_parent()` and creates child window (0x8800000)
- **IPC protocol** - Full stack passes window handles from OSC → Audio → IPC → Plugin subprocess
- **LSP plugins** - Continue to work in floating mode (regression test passed)

### Not Working ❌
- **Sforzando rendering** - Window appears but shows BLACK SCREEN
  - Window exists and is visible: `xwininfo` shows parent (0x8600004) and child (0x8800000)
  - Plugin creates its GUI window inside our winit window
  - Plugin registers timers (33ms, 16ms, 1000ms) for redraws
  - **But nothing renders** - completely black
  - Resizing shows brief glitchy artifacts but no actual content

### Root Cause Analysis
The issue is **NOT** with window creation anymore - that works perfectly. The problem is:

**Sforzando requires OpenGL/rendering context that basic winit windows don't provide**

Evidence:
1. ✅ Window created successfully with proper X11 handle
2. ✅ Plugin accepts the window and calls `set_parent()` without errors
3. ✅ Plugin creates child window (visible in `xwininfo`)
4. ✅ Plugin registers timers for GUI updates
5. ❌ **Nothing renders** - plugin likely expects GL context or pixel buffer that isn't there

**Why clack example might work but we don't:**
- Unknown - need to test clack example with Sforzando to see if it has same issue
- Clack example doesn't use glutin/softbuffer either - just basic winit
- Possible they only tested with plugins that don't need GL contexts

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
- ❌ **Sforzando embedded**: Window created, plugin embeds, but BLACK SCREEN
- ❓ **Sforzando floating**: set_transient() still fails (different issue)
- ❓ **Other plugins**: Not tested yet

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

## Next Steps

**Immediate:**
1. Test clack CPAL example with Sforzando to confirm behavior
2. Research if other DAWs have similar Sforzando embedding issues
3. Decide: Add GL context support vs. document as limitation

**Future:**
- Consider preset management (save/load plugin states)
- Multi-output plugin support

## Lessons Learned
- `pump_events()` is unreliable for window creation - use `run()` in dedicated thread
- X11 on non-main thread requires `with_any_thread(true)`
- Basic winit windows successfully create and embed plugin child windows
- **Creating a window ≠ providing a rendering surface** - plugins may need GL/Vulkan context
- Successful `set_parent()` doesn't guarantee rendering will work
