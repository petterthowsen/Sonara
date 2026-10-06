# Device Frames — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

## Phase 1 — Engine: plugin GUI embedding end to end

- [x] **T-001** [REQ-022, REQ-024, REQ-020] Plugin host GUI commands and floating fallback.
  - _Files_: `Engine/src/audio/ipc/protocol.rs`, `Engine/src/plugin_host/operations.rs`, `Engine/src/plugin_host/commands.rs`
  - _Output_:
    - New commands `PluginCommand::SetGuiVisible { visible }` and `PluginCommand::SetGuiSize { width, height }`.
    - New response `PluginResponse::GuiSize`, and a `floating` field on `GuiOpened`.
    - When embedding is refused, `open_plugin_gui` falls back to a floating window.
    - `set_plugin_gui_visible` calls `show`/`hide`.
    - `set_plugin_gui_size` runs `adjust_size` → `set_size` → `get_size`.
  - _Verify_: `cargo build --release` and `cargo test` pass. Existing GUI open/close still works live (floating plugin window opens and closes).
  - _Note_: The floating fallback isn't exercised live yet; no installed plugin refuses embedded mode.
  - _Depends on_: —

- [x] **T-002** [REQ-022, REQ-020, REQ-024] Engine commands and statuses.
  - _Files_: `Engine/src/audio/commands.rs`, `Engine/src/audio/command_worker.rs`, `Engine/src/audio/devices/clap_host/subprocess_adapter/gui.rs`, `Engine/src/audio/devices/clap_host/subprocess_adapter/plugin_ipc.rs`
  - _Output_:
    - New commands `AudioCommand::SetPluginGuiVisible` and `SetPluginGuiSize`, handled with the state lock released.
    - New status `EngineStatus::PluginGuiOpened { width, height, resizable, floating }`.
    - An already-open GUI reports its real size.
  - _Verify_: `cargo test` passes. The engine log shows the `PluginGuiOpened` size matching the plugin (Dragonfly: 920×345) on first and repeated opens.
  - _Depends on_: T-001

- [x] **T-003** [REQ-018, REQ-021, REQ-022, REQ-023] Window manager embedding, productionized.
  - _Files_: `Engine/src/window_manager.rs`
  - _Output_:
    - `HostWindow` holds its embed state and visibility.
    - `Create` can embed the window before it is first mapped.
    - New commands `Embed`, `Bounds`, `Unembed`, `SetVisible` and `Release`.
    - `x11_embed` keeps the spike workarounds (override-redirect, full-parent size, XShape viewport, inner scroll).
    - No "SPIKE" markers left.
  - _Verify_: `cargo build --release`. `grep -n SPIKE Engine/src/window_manager.rs` finds nothing.
  - _Depends on_: —

- [x] **T-004** [REQ-018–023] OSC handlers and status mapping.
  - _Files_: `Engine/src/osc/server.rs`
  - _Output_:
    - `gui/open` takes optional embed args.
    - New handlers for `gui/embed`, `gui/bounds`, `gui/unembed`, `gui/visible` and `gui/size`.
    - `gui/close` releases the host window before closing.
    - `parse_embed_args`, with a `mod tests`.
    - Statuses are forwarded as `gui/opened` and `gui/size`.
    - The host window is destroyed when an open reports `floating`.
  - _Verify_: `cargo test parse_embed_args` passes. Live with `oscsend`:
    - `oscsend localhost 7000 /channel/2/device/0/gui/open iiiii <godot_xid> 0 0 920 345` embeds the plugin into the Sonara window with no floating flash.
    - `.../gui/visible i 0` hides it, and `i 1` shows it again.
  - _Depends on_: T-002, T-003

## Phase 2 — Godot: model and settings

- [x?] **T-005** [REQ-018–022] `DeviceInstance` GUI state and embed methods.
  - _Files_: `Godot/data/DeviceInstance.gd`, `Godot/tests/test_device_gui_embed.gd`
  - _Output_:
    - State `gui_size`, `gui_resizable` and `gui_floating`.
    - Signals `gui_opened` and `gui_size_changed`.
    - Methods `open_gui_embedded`, `embed_gui`, `set_gui_bounds`, `unembed_gui`, `set_gui_visible` and `request_gui_size`.
    - Listeners for `gui/opened` and `gui/size` in the existing listen/unlisten blocks.
  - _Verify_: `Godot/tests/run_all.sh device` passes. A test-mode check that `embed_gui` sends the expected OSC address and args through the test OSC stub.
  - _Depends on_: T-004

- [x?] **T-006** [REQ-010, REQ-017, REQ-025, REQ-006] Settings, `available_if`, shortcut action.
  - _Files_: `Godot/settings/Settings.gd`, `Godot/settings/SettingRow.gd`, `Godot/project.godot`, `Godot/tests/test_settings_registry.gd`
  - _Output_:
    - New settings `devices/window_grouping` and `plugins/embed_gui`.
    - `Setting.available_if(check, reason)`; `SettingRow` shows such a setting disabled, with the reason.
    - A `toggle_device_frame` action, listed in the "View" shortcut group.
  - _Verify_: `Godot/tests/run_all.sh settings_registry` passes. The Settings dialog shows both settings. Under `--display-driver wayland`, the embed setting is disabled with the X11 note.
  - _Note_: `toggle_device_frame` has no default key, and `get_shortcut_list()` skips unbound actions, so it won't appear in the Shortcuts page until it's bound.
  - _Depends on_: —

## Phase 3 — Godot: frames

- [x?] **T-007** [REQ-019, REQ-021] `PluginGuiSlot.compute_viewport` and its tests.
  - _Files_: `Godot/devices/frame/PluginGuiSlot.gd`, `Godot/tests/test_device_frames.gd`
  - _Output_: The static layout function: centering, clipping, scrollbars that take their own width, and scroll clamping.
  - _Verify_: `Godot/tests/run_all.sh device_frames`. The viewport cases pass, including a 920×345 GUI in a larger area, a smaller area, and areas exactly one scrollbar wide.
  - _Depends on_: —

- [x?] **T-008** [REQ-001, REQ-003, REQ-014] `DeviceFrame` chrome, tabs and pages.
  - _Files_: `Godot/devices/frame/DeviceFrame.gd`
  - _Note_: The chrome is built in code (as `DockPanel` does), so there is no `.tscn`.
  - _Output_:
    - Title bar with title, tab bar, and attach/detach, minimize, maximize and close buttons.
    - `set_mode(floating)` hides minimize and maximize when attached.
    - The tab strip is hidden when the frame holds one device.
    - Pages are created when first selected, and `show_view`/`hide_view` follow selection and visibility.
  - _Verify_: The frame test cases in `test_device_frames.gd` cover the title text, buttons per mode, a single view per page across selection changes, and `show_view`/`hide_view` calls.
  - _Depends on_: —

- [x?] **T-009** [REQ-002, REQ-003, REQ-008] `FrameWindow`.
  - _Files_: `Godot/devices/frame/FrameWindow.gd`
  - _Output_: A borderless native window holding a `DeviceFrame`:
    - Dragging the title bar moves it, and edge grips resize it.
    - Its minimum size follows the active page.
    - Maximize, restore and minimize.
    - It remembers its last rect.
  - _Verify_: Live: drag, edge-resize to the EQ minimum, maximize and restore, minimize. Headless: `min_size` follows the active page's minimum size.
  - _Depends on_: T-008

- [x?] **T-010** [REQ-004, REQ-011–016] `DeviceWindowManager` rewritten around frames; spike removed.
  - _Files_: `Godot/devices/DeviceWindowManager.gd`, `Godot/tests/test_device_window_persist.gd`, `Godot/tests/test_device_frames.gd`, `Godot/data/Channel.gd`; delete `Godot/devices/PluginEmbedSpike.gd` and `.uid`
  - _Note_: `Channel.remove_device` emitted the device *type* id in `device_removed`/`child_removed`, so removing a device never closed its window. It now emits the instance id, as the signals document.
  - _Note_: With embedding off, a plugin opened while its channel has no frame opens in its own window with no frame (as before). With a channel frame open, its tab is selected and shows the note (REQ-017). `close_all()` runs on project close.
  - _Output_:
    - Grouping per channel or per device; nested devices get their own frame.
    - Tabs follow the chain, and frames close when their channel or device is removed.
    - `is_open`/`toggle` semantics as in the design.
  - _Verify_: `Godot/tests/run_all.sh device_window_persist device_frames`. The per-channel, per-device, nested and chain-edit cases pass.
  - _Depends on_: T-006, T-008, T-009

- [x?] **T-011** [REQ-005–009] Attach and detach in the Primary area.
  - _Files_: `Godot/editor/Editor.gd`, `Godot/devices/DeviceWindowManager.gd`
  - _Output_:
    - `View.DEVICE`, plus `attach_frame`, `detach_frame` and `toggle_device_frame`.
    - Only one frame can be attached at a time.
    - Detaching restores the previous view and the last floating rect.
  - _Verify_: The `test_device_frames.gd` attach cases pass: the same `DeviceView` instance id survives attach and detach, a second attach detaches the first, and the previous view is restored. Live: the EQ analyzer keeps running across attach and detach.
  - _Depends on_: T-010

- [x?] **T-012** [REQ-013] Tab tear-off.
  - _Files_: `Godot/devices/frame/DeviceFrame.gd`, `Godot/devices/DeviceWindowManager.gd`
  - _Output_:
    - A tab dragged out of its frame becomes a frame of its own at the drop position.
    - Selecting that tab in the channel frame afterwards raises the torn-off frame.
  - _Verify_: Live: tear off Reverb, then click its tab in the channel frame. Headless: calling the manager's tear-off entry point creates the frame and redirects selection.
  - _Depends on_: T-010

- [x?] **T-013** [REQ-017–022, REQ-024] `PluginGuiSlot` embedding.
  - _Files_: `Godot/devices/frame/PluginGuiSlot.gd`
  - _Output_:
    - Opens the GUI embedded, and re-embeds it when the frame changes window.
    - Sends bounds on layout and scroll changes, and visibility from `is_visible_in_tree`.
    - Requests resizes for resizable plugins, debounced.
    - Shows the "In its own window" note with a Show window button when embedding is off or the plugin opened floating; attach is disabled with a tooltip when it opened floating.
  - _Verify_: Live, with embedding on:
    - Dragonfly embeds in a floating frame and in the attached view.
    - A resizable plugin fills the area.
    - Resizing the main window and toggling the device lane never blanks the app.
    - Clipping and scrolling work.
    - The engine log shows a single `gui/open` across attach, detach and tab switches.
    - With embedding off, the plugin opens its own window and the tab shows the note.
  - _Depends on_: T-005, T-011

- [x?] **T-014** [REQ-004, REQ-023] Close lifecycle.
  - _Files_: `Godot/devices/DeviceWindowManager.gd`, `Godot/devices/frame/FrameWindow.gd`
  - _Output_:
    - Closing a frame closes every GUI in it.
    - The frame window hides at once and is freed after `plugin_gui_closed`, or after 2 s.
    - Built-in views are freed.
  - _Verify_: Live: close floating and attached frames that hold Dragonfly. Nothing flashes, and `grep -i "x11\|BadWindow" Engine/logs/last_combined.log` finds nothing new.
  - _Note_: Godot destroys a native subwindow's X window on `hide()`, which took the embedded plugin with it on attach (BadWindow). The engine now confirms every host-window move with `gui/embedded` (`WindowManager::embed_window`/`unembed_window`/`release_window` wait for the winit thread), and the manager hides or frees a frame window only once its GUIs have left it (`_when_vacated`, 2 s fallback).
  - _Depends on_: T-013

- [x?] **T-015** [REQ-026, REQ-027] Crash and engine-loss states in the slot.
  - _Files_: `Godot/devices/frame/PluginGuiSlot.gd`
  - _Output_:
    - A crashed plugin shows the crash note with a Reload button, and its GUI re-embeds once the plugin is `ready`.
    - When the engine disconnects, the slot shows "unavailable".
  - _Verify_: Live: `kill` the plugin host pid (from `{device}/host`) while it is attached, then Reload. Stop the engine and see "unavailable" with the app still usable.
  - _Depends on_: T-013

## Phase 4 — docs

- [x] **T-016** [REQ-018–025] ADR 0016.
  - _Files_: `docs/adr/0016-plugin-guis-embed-via-x11-reparenting.md`
  - _Output_: The ADR records:
    - The decision and the rejected alternatives.
    - The Godot X11 constraints and their workarounds.
    - That embedding is X11-only and behind the experimental flag.
  - _Verify_: The ADR exists, and the design's ADR references resolve.
  - _Depends on_: T-004

- [x] **T-017** [REQ-all] OSC protocol doc.
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: Every new and changed GUI message, with its arguments and direction.
  - _Verify_: Every address in the design's two OSC tables appears in the doc.
  - _Depends on_: T-004

- [x] **T-018** [REQ-all] Subsystem docs, glossary, backlog.
  - _Files_: `docs/subsystems/engine-plugin-architecture.md`, `docs/subsystems/godot-device-views.md`, `CONTEXT.md`, `TODO.md`
  - _Output_:
    - The embedding lifecycle and the new IPC commands.
    - Device frames and the attach model.
    - Glossary terms for both.
    - The TODO entry updated.
  - _Verify_: The docs mention `gui/embed`, `SetGuiVisible` and `DeviceFrame`, and `CONTEXT.md` has "Device frame".
  - _Depends on_: T-014

## Phase 5 — live verification

- [ ] **T-019** [REQ-all] Full live pass on X11.
  - _Files_: —
  - _Output_: The `TODO.md` entry is marked `[x]`; `STATUS.md` notes what was and wasn't checked, and on which WM.
  - _Verify_: Run the design's "Live" list end to end, with Dragonfly Room Reverb, a resizable plugin, and a GL-heavy plugin, with embedding both on and off.
  - _Depends on_: T-011, T-012, T-014, T-015, T-018
