# Device Frames — Design

Implements [requirements.md](./requirements.md).

## Context

**Godot**

- `Godot/devices/DeviceWindowManager.gd` (autoload `DeviceWindowManager`) — owns every device window today:
  `_popups`/`_views` (Window-view popups: native `Window` with OS decorations, `force_native`), `_guis`
  (open plugin GUIs), public API `is_open`/`toggle`/`open`/`close` and signal `state_changed(device)`.
  It watches `DeviceInstance.plugin_gui_closed`, `name_changed`, `Channel.device_removed`,
  `Channel.name_changed` and the parent's `child_removed`.
- Callers of that API: `devices/device_lane/DevicePanel.gd` (`window_button`, `_on_window_state_changed`,
  companion view at line ~1078) and `devices/compact/CompactDevicePanel.gd` (`DeviceWindowManager.toggle`).
- `Godot/devices/DeviceViewFactory.gd` — `create(instance, Device.ViewType.Window)`.
- `Godot/devices/DeviceView.gd` — `show_view()`/`hide_view()` drive data stream subscriptions.
- `Godot/data/DeviceInstance.gd` — `open_gui()`/`close_gui()` send `gui/open`/`gui/close`;
  signals `plugin_gui_closed`, `crashed`, `loading_state_changed`; `reload()`; `osc_addr()`; listeners are
  registered in the block around `gui_closed_addr` (line ~1499) and removed in its mirror (~1543).
- `Godot/data/Device.gd` — `has_gui()`, `has_window_view()`, `ViewType`.
- `Godot/data/Channel.gd` — `device_added`/`device_removed`/`device_moved`, `name_changed`.
- `Godot/editor/Editor.gd` — `enum View { ARRANGER, MIXER, EDITOR }`, `current_view`,
  `_update_view_visibility()`, `switch_view()`/`switch_extra_view()`, `primary_panel`
  (PanelContainer holding Arranger, Mixer, ClipEditor), `view_changed` signal.
- `Godot/settings/Settings.gd` — `Setting` builder (`sub`, `choices`, `scene`), `_register`, categories
  `CATEGORY_AUDIO`/`CATEGORY_BEHAVIOR`, `get_shortcut_list()` "View" group;
  `Godot/settings/SettingRow.gd` builds one row per setting.
- `Godot/editor/MainBar.gd` — hand-rolled window dragging (`_start_dragging`); unchanged here.
- `Godot/devices/PluginEmbedSpike.gd` — spike, removed by this spec.

**Engine**

- `Engine/src/window_manager.rs` — `WindowManager` (winit thread): `create_window`, `resize_window`,
  `show_window`, `destroy_window`, `close_event_rx`; spike additions `embed_window`, `set_embed_bounds`,
  `unembed_window`, `EmbedRect`, `mod x11_embed` (override-redirect, XShape viewport, withdraw).
- `Engine/src/osc/server.rs` — `handle_device_message`: `["gui","open"]` creates the host window (800×600) and
  sends `AudioCommand::OpenPluginGui`; `["gui","close"]`; spike `["gui","embed"|"bounds"|"unembed"]`.
  Main loop handles `GuiEvent::Resize`/`Closed`; `send_status_update` maps statuses to OSC (spike forwards
  `PluginGuiResizeRequest` as `gui/size`).
- `Engine/src/audio/commands.rs` — `AudioCommand::OpenPluginGui { window_handle }`, `ClosePluginGui`;
  `EngineStatus::PluginGuiResizeRequest`, `PluginGuiClosed`.
- `Engine/src/audio/command_worker.rs` — `open_plugin_gui`/`close_plugin_gui` run IPC with the state lock
  released; plugin `PluginEvent::GuiResizeRequest` → `EngineStatus::PluginGuiResizeRequest`.
  `already_open` currently reports a made-up 800×600.
- `Engine/src/audio/ipc/protocol.rs` — `PluginCommand::OpenGui { window_handle }`, `CloseGui`, `HasGui`;
  `PluginResponse::GuiOpened { width, height, is_resizable }`, `GuiError`; `PluginEvent::GuiResizeRequest`.
- `Engine/src/audio/devices/clap_host/subprocess_adapter/gui.rs`, `plugin_ipc.rs` — IPC wrappers.
- `Engine/src/plugin_host/operations.rs` — `open_plugin_gui` (embedded when a handle is given, errors out
  if the plugin doesn't support embedded mode), `close_plugin_gui`; `plugin_host/commands.rs` dispatch.
- ADR 0001 (out-of-process plugins), ADR 0009 (hosting modes, crash recovery) — unchanged and respected:
  the plugin GUI stays in the plugin host process.

## Approach

**One frame type for every device window.** A `DeviceFrame` control draws the title bar, a tab strip and a
content area. It is either inside a `FrameWindow` (a borderless native Godot `Window`, floating) or inside
the Primary area (attached). Changing mode reparents the same `DeviceFrame` node, so device views move
without being recreated (REQ-009). `DeviceWindowManager` keeps its public API and becomes the owner of
frames: it decides which frame a device opens in (grouping setting, nested devices), tracks the single
attached frame, and keeps `state_changed` working so `DevicePanel` and `CompactDevicePanel` stay unchanged.
Floating windows are moved and resized by the window manager through `DisplayServer.window_start_drag` /
`window_start_resize`, which keeps snapping and works on any display server.

**Plugin GUIs are embedded by reparenting the engine's host window into the Godot window that shows the
frame.** This is the spike's mechanism, made permanent. The engine's winit host window stays the plugin's
CLAP parent forever; only the host window moves between parents, so attach, detach and tab switches never
close the plugin GUI (REQ-022). Two Godot 4.7 X11 behaviours shape the design and are recorded in ADR 0016:
Godot holds SubstructureRedirect on its windows and drops redirected requests (the host window is
override-redirect), and Godot reads any direct child's ConfigureNotify as its own resize (the host window
always covers its whole Godot parent and is clipped to the viewport by an XShape bounding region; position
and scrolling move the plugin's own window inside it, which Godot never sees). A `PluginGuiSlot` control in
the tab computes the viewport rect in window pixels and drives the engine through `DeviceInstance`, never
OSC directly.

**Rejected alternatives.** (1) *Overlay*: keep the plugin as a separate always-on-top window positioned over a
placeholder. Godot would have to stream window positions, it lags during moves, ignores minimize and
workspaces, and always-on-top covers other apps. (2) *Re-open the GUI per parent*: CLAP can't change a
GUI's parent while open, so every attach or tab switch would destroy and recreate the plugin GUI (slow,
some plugins lose view state). (3) *Pass Godot's XID to the plugin directly* (no engine host window):
nothing would clip or scroll the plugin, and a mode change would again mean re-opening.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| Host windows, their embed parent and viewport (`HostWindow`) | WindowManager (winit) thread | main thread via `WindowCommand` channel + `EventLoopProxy` wakeup | n/a (not on the audio path) |
| X11 calls for embedding | WindowManager thread, on winit's own Xlib connection | — | n/a |
| Plugin GUI open/visible/size | plugin host GUI thread | command thread via IPC, state lock released (as `open_plugin_gui` today) | n/a |
| Frame model (frames, tabs, attached frame) | Godot main thread (`DeviceWindowManager`) | UI signals | n/a |

Nothing touches the audio callback.

## Data and protocol changes

### OSC, Godot → engine (`{device}` = `/channel/{id}/device/{path}`)

| Address | Args | Meaning |
|---|---|---|
| `{device}/gui/open` | *(none)* or `parent_xid:i x:i y:i w:i h:i` | Unchanged without args (floating). With args, the host window is embedded before it is first mapped, so no floating window ever flashes. |
| `{device}/gui/embed` | `parent_xid:i x:i y:i w:i h:i [scroll_x:i scroll_y:i]` | Move an open GUI's host window into another Godot window (attach/detach, tear-off). |
| `{device}/gui/bounds` | `x:i y:i w:i h:i [scroll_x:i scroll_y:i]` | New viewport (window pixels) and scroll offset. |
| `{device}/gui/unembed` | — | Back to a floating OS window (embedding switched off at runtime). |
| `{device}/gui/visible` | `visible:i` | Hide/show the GUI (tab switch, attached frame hidden). Calls CLAP `gui.hide()`/`show()` and unmaps/maps the host window. |
| `{device}/gui/size` | `w:i h:i` | Ask a resizable plugin to resize (REQ-020); the plugin host runs `adjust_size` then `set_size`. |

`gui/close` gains one behaviour: an embedded host window is unmapped and reparented to the root *unmapped*
before `CloseGui` goes out, so freeing the Godot window can't destroy the plugin's X window under it and
nothing flashes (REQ-023).

### OSC, engine → Godot

| Address | Args | Meaning |
|---|---|---|
| `{device}/gui/opened` | `w:i h:i resizable:i floating:i` | Sent after every successful open. `floating=1` when the plugin refused embedded mode and runs in its own window (REQ-024). |
| `{device}/gui/size` | `w:i h:i` | Current GUI size: after a `gui/size` request, and when the plugin resizes itself. |

### Engine internals

- `audio/commands.rs`: `AudioCommand::SetPluginGuiVisible { channel_id, device_path, visible }`,
  `AudioCommand::SetPluginGuiSize { channel_id, device_path, width, height }`;
  `EngineStatus::PluginGuiOpened { channel_id, device_path, width, height, resizable, floating }`.
  `PluginGuiResizeRequest` keeps its fields and is now also forwarded to Godot as `gui/size`.
- `audio/ipc/protocol.rs`: `PluginCommand::SetGuiVisible { visible }`, `PluginCommand::SetGuiSize { width, height }`;
  `PluginResponse::GuiOpened` gains `floating: bool`; new `PluginResponse::GuiSize { width, height }`.
- `plugin_host/operations.rs`: `open_plugin_gui` falls back to floating when `is_api_supported` refuses
  embedded mode, and reports it; new `set_plugin_gui_visible`, `set_plugin_gui_size`.
- `command_worker.rs`: `already_open` asks the plugin for its real size instead of reporting 800×600.
  When the open came back floating, the main loop destroys the unused host window.

### Godot model (`data/DeviceInstance.gd`)

New state `gui_size: Vector2i`, `gui_resizable: bool`, `gui_floating: bool`; signals
`gui_opened(size: Vector2i, resizable: bool, floating: bool)` and `gui_size_changed(size: Vector2i)`;
methods `open_gui_embedded(parent_xid: int, rect: Rect2i)`, `embed_gui(parent_xid, rect, scroll)`,
`set_gui_bounds(rect, scroll)`, `unembed_gui()`, `set_gui_visible(visible)`, `request_gui_size(size)`.
Listeners for `gui/opened` and `gui/size` join the existing listen/unlisten blocks. These are not synced
properties: none of it goes through `sync_to_engine()` (a GUI is reopened by the UI, not restored).

### Settings (`Settings.gd`)

- `devices/window_grouping` — CHOICE `["Per channel", "Per device"]`, default `"Per channel"`,
  `CATEGORY_BEHAVIOR`, sub "Devices" (REQ-010).
- `plugins/embed_gui` — BOOL, default `false`, `CATEGORY_AUDIO`, sub "Plugins", label
  "Embed plugin windows (experimental)" (REQ-017). Unavailable unless `DisplayServer.get_name() == "X11"`.
- New `Setting.available_if(check: Callable, reason: String)` builder; `SettingRow` disables the widget and
  shows `reason` when `check` returns false (REQ-025). `Settings.get_value("plugins/embed_gui")` keeps the
  stored value; `DeviceWindowManager` combines it with the same check.
- New input action `toggle_device_frame` (no default key) in `project.godot` and the "View" group of
  `get_shortcut_list()`: shows/hides the attached frame view (REQ-006).

## Godot structure

- **`DeviceFrame`** (`devices/frame/DeviceFrame.gd` + `.tscn`): title bar (title label, `TabBar`, buttons
  attach/detach, minimize, maximize, close), content area (`Control`) holding one tab page per device.
  Signals `close_requested`, `attach_requested`, `detach_requested`, `tab_torn_off(dev, screen_pos)`,
  `active_device_changed(dev)`. `set_mode(floating: bool)` hides minimize/maximize when attached (REQ-003).
  Tab pages are created on first selection: a `DeviceView` from `DeviceViewFactory.create(dev, Window)`, or a
  `PluginGuiSlot` for `has_gui()` devices. Only the selected page is visible; the frame calls
  `show_view()`/`hide_view()` when the selection, the frame's visibility or its window changes. The tab strip is
  hidden when the frame holds one device (REQ-014). Tabs aren't drag-rearrangeable (they mirror the
  chain, REQ-012). A press on a tab followed by a drag that ends outside the frame emits `tab_torn_off` (REQ-013).
- **`FrameWindow`** (`devices/frame/FrameWindow.gd`): borderless `Window` (`force_native`, no `always_on_top`,
  same reasons as today's popups) hosting one `DeviceFrame`. Title bar press → `window_start_drag`; thin edge
  grips → `window_start_resize(edge)`; `min_size` from the active page's minimum (REQ-002). Maximize toggles
  `Window.MODE_MAXIMIZED`/`MODE_WINDOWED` and minimize sets `MODE_MINIMIZED` (REQ-003). It remembers its last
  rect for detach (REQ-008).
- **`PluginGuiSlot`** (`devices/frame/PluginGuiSlot.gd`): black placeholder plus `HScrollBar`/`VScrollBar`.
  - `static func compute_viewport(area: Rect2, gui_size: Vector2, scroll: Vector2) -> Dictionary` does the
    pure layout math: centered when smaller, clipped and scrollable when larger, scrollbars eat their own
    width. It is unit-tested.
  - It converts to window pixels with `get_viewport().get_final_transform()`.
  - The parent XID comes from `DisplayServer.window_get_native_handle(WINDOW_HANDLE, get_window().get_window_id())`.
  - On `NOTIFICATION_ENTER_TREE`/window change it calls `embed_gui`. On resize, scroll and layout changes it
    calls `set_gui_bounds`, and it calls `set_gui_visible` from `is_visible_in_tree()`.
  - For resizable plugins it calls `request_gui_size(area.size)`, debounced to one request per frame (REQ-020).
  - It shows a note instead of the plugin in these states: "In its own window" plus a "Show window" button
    (embedding off, or `gui_floating`); crashed plus a Reload button calling `dev.reload()`, then re-embedding
    on `loading_state == "ready"` (REQ-026); "unavailable" on `AudioEngineOSC.engine_disconnected` (REQ-027).
- **`DeviceWindowManager`** keeps `is_open`/`toggle`/`open`/`close`/`state_changed`.
  - `open(dev)`: nested device (`get_parent_device() != null`) or "Per device" → that device's own frame.
    Otherwise the channel frame, created with a tab per top-level chain device that `has_window_view()` or
    `has_gui()`, with `dev` selected.
  - If the device already has a torn-off frame, that frame is raised instead (REQ-011, 013, 015).
  - `is_open(dev)` is true when `dev` is the selected tab of an open frame, or owns a frame.
    `toggle(dev)` on such a device closes that frame, and on any other device opens or selects it.
  - It watches the channel's `device_added`/`device_removed`/`device_moved` to rebuild tab order
    (REQ-012, 016).
  - `attach(frame)` asks `Editor.attach_frame(frame)`. A previously attached frame is detached first (REQ-007).
- **`Editor`**: `View.DEVICE`, `attached_frame`, `attach_frame(frame)` / `detach_frame()` (reparent into or out of
  `primary_panel`, remember and restore the previous view, REQ-005, 008), `toggle_device_frame()`, and
  `_update_view_visibility()` covering `View.DEVICE`. `switch_view()`/`switch_extra_view()` leave
  `View.DEVICE` like any other view. Opening a device whose frame is attached switches to `View.DEVICE` (REQ-006).
- **Closing a frame** (REQ-004, 023): every plugin tab gets `close_gui()`. The `FrameWindow` hides at once and
  is freed when every plugin tab has reported `plugin_gui_closed`, or after a 2 s timeout. An attached frame
  leaves the Primary area the same way. Built-in views get `hide_view()` and `queue_free()`.

## File-by-file change list

| File | Change |
|---|---|
| `Engine/src/window_manager.rs` | Productionize the spike: `HostWindow { window, embed: Option<(parent, EmbedRect)>, visible }`. `Create` takes an optional embed so it can embed before the first map. Commands `Embed`, `Bounds`, `Unembed`, `SetVisible`, `Release` (unmap and reparent to root unmapped before close). Keep `mod x11_embed`, plus `XUnmapWindow`/`XMapWindow` for visibility. Skip host resizes while embedded (spike). Drop the stale "SPIKE" markers. |
| `Engine/src/osc/server.rs` | `gui/open` with optional embed args; `gui/embed`, `gui/bounds`, `gui/unembed`, `gui/visible`, `gui/size`; `gui/close` calls `Release` first. Extract `parse_embed_args(args, with_xid) -> Option<(u64, EmbedRect)>`. Status mapping for `PluginGuiOpened` → `gui/opened` and `PluginGuiResizeRequest` → `gui/size`. Destroy the host window when an open reports `floating`. |
| `Engine/src/audio/commands.rs` | `AudioCommand::SetPluginGuiVisible`, `SetPluginGuiSize`; `EngineStatus::PluginGuiOpened`. |
| `Engine/src/audio/command_worker.rs` | Handle the two new commands with the lock released (as `open_plugin_gui`); emit `PluginGuiOpened`; query the real size when already open. |
| `Engine/src/audio/ipc/protocol.rs` | `PluginCommand::SetGuiVisible`, `SetGuiSize`; `PluginResponse::GuiOpened.floating`, `PluginResponse::GuiSize`. |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/gui.rs` | `set_gui_visible`, `set_gui_size` wrappers; `open_gui` returns `floating`. |
| `Engine/src/audio/devices/clap_host/subprocess_adapter/plugin_ipc.rs` | Matching `PluginIpcHandle` methods. |
| `Engine/src/plugin_host/operations.rs` | Floating fallback on embedded refusal; `set_plugin_gui_visible` (`show`/`hide`); `set_plugin_gui_size` (`adjust_size` → `set_size` → `get_size`). |
| `Engine/src/plugin_host/commands.rs` | Dispatch `SetGuiVisible`, `SetGuiSize`; `GuiOpened` with `floating`. |
| `Godot/data/DeviceInstance.gd` | GUI state, signals, embed methods, `gui/opened` + `gui/size` listeners (see above). |
| `Godot/devices/DeviceWindowManager.gd` | Rewritten around frames; public API unchanged; spike hooks removed. |
| `Godot/devices/frame/DeviceFrame.gd`, `DeviceFrame.tscn` | New: chrome, tabs, pages, tear-off. |
| `Godot/devices/frame/FrameWindow.gd` | New: borderless floating host, drag/resize/min/max, remembered rect. |
| `Godot/devices/frame/PluginGuiSlot.gd` | New: viewport math, scrollbars, embed driving, state notes. |
| `Godot/editor/Editor.gd` | `View.DEVICE`, `attach_frame`/`detach_frame`/`toggle_device_frame`, visibility, input action. |
| `Godot/project.godot` | `toggle_device_frame` input action (unbound). |
| `Godot/settings/Settings.gd` | Two settings, `Setting.available_if`, shortcut list entry. |
| `Godot/settings/SettingRow.gd` | Disabled state + reason for unavailable settings. |
| `Godot/devices/PluginEmbedSpike.gd`, `.uid` | Deleted. |
| `Godot/tests/test_device_window_persist.gd` | Find the frame (not a popup `Window`) after open; same assertions. |
| `Godot/tests/test_device_frames.gd` | New (see test plan). |
| `Engine/src/osc/server.rs` `mod tests` | `parse_embed_args` cases. |
| `docs/adr/0016-plugin-guis-embed-via-x11-reparenting.md` | New ADR: decision, Godot X11 constraints and workarounds, X11-only, experimental flag. |
| `docs/subsystems/osc-protocol.md` | The new and changed GUI messages. |
| `docs/subsystems/engine-plugin-architecture.md` | Plugin GUI section: embedding, host-window lifecycle, new IPC commands. |
| `docs/subsystems/godot-device-views.md` | Device frames, tabs, attach. |
| `CONTEXT.md` | Glossary: Device frame, Channel frame, Embedded plugin GUI. |
| `TODO.md` | Feature entry for spec 022; the "Plugin GUI windows should be forced to stay above Godot App" entry points at it. |

## Migration and compatibility

Nothing about frames is persisted. `config.json` gains `devices/window_grouping` and `plugins/embed_gui` with
registry defaults; older configs simply lack them. Projects are unchanged. With `plugins/embed_gui` off,
plugin GUIs open as today (`gui/open` without args). The only visible difference is the channel frame tab note.

## Test plan

- **Unit:** `cargo test parse_embed_args` — the arg parser accepts int/long/float and optional scroll, and
  rejects short lists.
- **Godot:** `Godot/tests/run_all.sh device_frames` (`Godot/tests/test_device_frames.gd`):
  - `PluginGuiSlot.compute_viewport`: centering, clipping, scrollbar interplay and scroll clamping, with
    the spike's Dragonfly numbers (920×345) as cases.
  - Per channel: opening EQ on Polysynth → EQ → Reverb gives one frame with three tabs and EQ selected.
    Opening Reverb selects it in the same frame. Delete, move and rename update the tabs, and deleting
    everything closes the frame.
  - Per device: two devices give two frames with no tab strip.
  - A nested pad device gets its own frame.
  - Attach then detach keeps the same `DeviceView` instance (`get_instance_id`) and restores the previous view.
    A second attach detaches the first.
  - `is_open`/`toggle` semantics for the selected tab versus other tabs.
- **Godot (existing):** `Godot/tests/run_all.sh device_window_persist` still passes.
- **Live** (engine + Godot on X11, embedding on), with Dragonfly Room Reverb and one resizable plugin:
  - Attach, detach, tear off and switch tabs while watching the engine log: a single `gui/open`, and no X11
    errors in `Engine/logs/last_combined.log`.
  - Resize the main window and toggle the device lane: the app never goes black (the spike regression),
    and the plugin clips and scrolls.
  - Minimize and switch workspace.
  - Close from each mode with no flash.
  - Kill the plugin host, then Reload.
  - Stop the engine: the tab shows "unavailable".
  - Embedding off: the plugin opens its own window and the tab shows the note.
  - `godot --path Godot --display-driver wayland`: the setting is disabled with the note.

## Risks

| Risk | Mitigation |
|---|---|
| Other window managers handle the withdraw/reparent dance differently (only Muffin tested) | Experimental flag, off by default; `withdraw` has a bounded wait and logs; embedding before the first map avoids the WM entirely for the common path. |
| A Godot update changes its X11 event handling | The workarounds stay correct if Godot fixes the ConfigureNotify bug (same-size events are no-ops). Report the bug upstream; ADR 0016 records the dependency. |
| A plugin misbehaves when its parent is shaped or its window is moved by the host (scrolling) | Live-test a GL-heavy plugin; if one breaks, fall back to no scrolling (centered and clipped) for that plugin. |
| Freeing a Godot window destroys the plugin's X window before the plugin closes it | `Release` on close, frame window hidden but kept alive until `gui/closed` or the timeout. |
| Keyboard focus and popups under the plugin | Accepted for v1 (requirements, deferred questions). |
| Frame windows without `always_on_top` can fall behind the main window | Same as today's popups; Godot makes `force_native` subwindows transient for the main window, which keeps them above it. |

## Open questions

None.
