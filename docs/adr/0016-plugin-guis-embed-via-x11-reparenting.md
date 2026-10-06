# 0016 — Plugin GUIs embed into Godot windows by X11 reparenting

Status: accepted (experimental, X11 only, behind the `plugins/embed_gui` setting).

## Context

Spec 022 (device frames) draws every device window in Sonara: a frame with a title bar and a tab
per device, either floating in its own window or attached to the Primary area of the main window.
Built-in devices are Godot views, so they move between frames freely. CLAP plugin GUIs are native
windows owned by the plugin, which runs in a separate `plugin_host` process (ADR 0001). The engine
gives each one a winit **host window** as its CLAP parent.

Until now that host window was a floating OS window. It fell behind the main window, ignored the
frame's minimize and workspace, and couldn't sit in a tab or in the Primary area.

CLAP can't change an open GUI's parent. Anything that gives the plugin a different parent per
frame means closing and reopening the GUI on every attach, detach and tab switch. That is slow,
and some plugins lose their view state.

## Decision

- The plugin's CLAP parent stays the engine's host window for as long as the GUI is open. Only the
  host window moves: the engine reparents it into the X11 window of whichever Godot window shows
  the frame (`XReparentWindow` on winit's own Xlib connection). Attach, detach, tear-off and tab
  switches never close the plugin GUI.
- Godot drives it through `DeviceInstance` (never raw OSC from UI code): `gui/open` with embed
  arguments embeds before the window is first mapped, so nothing floats on screen first. After
  that, `gui/embed` moves it, `gui/bounds` sets its viewport and scroll, `gui/visible` hides it on
  a hidden tab, and `gui/unembed` makes it a floating window again. `PluginGuiSlot` computes the
  viewport in window pixels and sends only what changed, once per frame.
- The engine confirms every move of the host window with `gui/embedded parent_xid`, once the X
  server has it. A Godot window that holds plugin GUIs hides or is freed only after they have
  moved out (2 s fallback).
- On `gui/close` the engine first unmaps the host window and reparents it to the root, then closes
  the GUI, so freeing the Godot window can't destroy the plugin's window under it.
- A plugin that refuses embedded mode opens floating, and `gui/opened` reports `floating=1`. Its
  tab shows a note, and its frame can't be attached.
- Embedding is X11 only, and off by default (`plugins/embed_gui`, "Embed Plugin Windows
  (Experimental)"). The setting is disabled on other display servers. With it off, plugin GUIs
  open in their own window as before.

### Godot 4.7 X11 behaviours, and the workarounds

| Behaviour | Workaround |
|---|---|
| Godot holds SubstructureRedirect on its windows and drops the redirected map and configure requests of child windows it didn't create. | The host window is override-redirect, which bypasses the redirect. |
| Godot takes a ConfigureNotify from any direct child as a resize of its own window. | The host window always covers its whole Godot parent at (0,0), so its ConfigureNotify carries Godot's real size. The viewport is an XShape bounding region on it (clipping drawing and input), and position and scrolling move the plugin's own window (a grandchild Godot never sees) inside it. It is resized only when the parent's size differs, and a floating window is sized before it is reparented. |
| Hiding a native `Window` destroys its X window (and every child window with it); showing it creates a new one with a new XID. | Godot never hides or frees a window that holds a plugin GUI until the engine has confirmed the GUI moved out (`gui/embedded`). `PluginGuiSlot` re-embeds whenever its window's XID changes. |
| A window manager reparents a managed toplevel into its frame window. Reparenting out of that frame behind its back races with the WM reparenting it back on unmap. | Before the first embed of a floating host window, `withdraw` unmaps it and waits (bounded) until its parent is the root again. Embedding at `gui/open` avoids the WM entirely. |
| winit leaves the host window's background unset, and ARGB visuals are see-through. | The engine sets an opaque black background, so viewport pixels the plugin doesn't cover are black. |

## Rejected alternatives

1. **Overlay:** keep the plugin as a separate always-on-top window positioned over a placeholder.
   Godot would have to stream window positions, the overlay lags during moves, it ignores minimize
   and workspaces, and always-on-top covers other apps.
2. **Reopen the GUI per parent:** CLAP can't reparent an open GUI, so every attach or tab switch
   would close and reopen the plugin GUI. It is slow, and some plugins lose view state.
3. **Pass Godot's XID to the plugin directly** (no engine host window): nothing would clip or
   scroll the plugin, and a mode change would mean reopening again.

## Consequences

- One `gui/open` per plugin across attach, detach and tab switches. The plugin stays in its own
  process (ADR 0001, 0009), and only its window is shared.
- The design depends on Godot's X11 event handling. If a Godot update fixes the ConfigureNotify
  behaviour, the workarounds stay correct (same-size configures are no-ops). If it changes how
  windows are created or hidden, embedding has to be rechecked.
- Godot may track a floating window's screen position wrongly while a plugin is embedded in it.
  Tab tear-off therefore uses only the press and release event positions, never
  `get_local_mouse_position()`.
- Only tested on Muffin (Cinnamon). Other window managers may handle the withdraw differently,
  which is one reason the feature is experimental.
- Not handled in v1: keyboard focus inside an embedded plugin, plugin popups and menus, HiDPI
  `set_scale`. Native Wayland, macOS and Windows keep floating plugin windows.

References: `docs/specs/022-device-frames/` (design, requirements REQ-017–REQ-025),
`Engine/src/window_manager.rs` (`mod x11_embed`), `Godot/devices/frame/PluginGuiSlot.gd`,
ADR 0001, ADR 0009, `docs/subsystems/osc-protocol.md`
