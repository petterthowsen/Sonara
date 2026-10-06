# Device Frames — Requirements

## Problem

Device windows (Window views and CLAP plugin GUIs) only exist as floating OS windows. Built-in Window views
get OS decorations that don't match the app, and they can't be shown inside the main area where the
arranger, mixer and clip editor live. CLAP plugin GUIs live in a separate engine-owned window that Sonara
can't decorate, dock, or keep above the app (TODO: "Plugin GUI windows should be forced to stay above
Godot App"). There is no way to browse the devices of a channel from an open device window: each device
needs its own window, opened from the device lane.

The spike on `spike/plugin-gui-embed` (commit `168e0e5`) showed that a CLAP plugin GUI can be embedded
into Godot windows on X11, with workarounds for Godot's X11 event handling. That depends on the
host's display server and window manager, so plugin embedding ships behind an experimental setting.

## Scope

| | |
|---|---|
| Subsystem | both (Godot device windows, engine window manager) |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | yes — plugin GUI embedding and GUI size messages; protocol docs are part of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes — `config.json` gains two new setting keys with defaults; no migration needed. `.sonara` is unchanged |

## Terms

- **Device frame** — the Sonara-drawn container that shows device windows: a title bar plus a content area
  with one tab per device. It is either **floating** (its own OS window) or **attached** (shown in the
  Primary area).
- **Channel frame** — a device frame holding the top-level devices of one channel's chain.
- **Embedded plugin GUI** — a CLAP plugin GUI shown inside a device frame's content area instead of in its
  own window.

## Requirements

### Frame chrome

#### REQ-001 — Custom title bar

The device frame shall draw its own title bar with the title `<channel> — <device>` (the active tab's
device), and buttons for attach/detach, minimize, maximize and close. A floating frame shall have no OS
window decorations.

- **Acceptance:** open the EQ window: the frame shows the Sonara title bar with all four buttons and no OS
  title bar. Rename the channel to "Drums": the title becomes "Drums — EQ".

#### REQ-002 — Move and resize a floating frame

WHILE a frame is floating, dragging its title bar shall move it, and dragging its edges shall resize it,
never below the minimum size of the active tab's content.

- **Acceptance:** drag the title bar: the frame follows the pointer (including window-manager snapping).
  Drag an edge inward past the EQ view's minimum: the frame stops at that minimum.

#### REQ-003 — Minimize and maximize

WHILE a frame is floating, minimize shall minimize its window, and maximize shall toggle between
maximized and its previous size and position. WHILE a frame is attached, the maximize and minimize
buttons shall be hidden.

- **Acceptance:** maximize, then press it again: the frame returns to its earlier rect. Attach it: only
  detach and close remain.

#### REQ-004 — Close

WHEN the close button is pressed, the device frame shall close along with every device window it holds,
and each device's window button in the device lane shall show as closed.

- **Acceptance:** open EQ and Compressor in one channel frame, press close: the frame is gone, and neither
  device's window button is pressed.

### Attach and detach

#### REQ-005 — Attach to the Primary area

WHEN attach is pressed, the frame shall be shown in the Primary area as its own view, in place of the
arranger, mixer or clip editor, and its floating window shall close.

- **Acceptance:** attach the EQ frame: the Primary area shows the EQ frame; no floating window remains.

#### REQ-006 — Return to an attached frame

WHILE a frame is attached, the user shall be able to switch the Primary area between the attached frame and
the arranger, mixer and clip editor, and the attached frame shall keep its state while hidden.

- **Acceptance:** attach EQ, switch to the mixer, switch back: EQ shows again with the same band selected.

#### REQ-007 — One attached frame

IF a frame is attached while another frame is already attached, THEN the previously attached frame shall
be detached to floating.

- **Acceptance:** attach EQ, then attach Reverb: Reverb is in the Primary area and EQ floats.

#### REQ-008 — Detach

WHEN detach is pressed on an attached frame, the frame shall float again, at its previous floating
position and size if it had one, otherwise centered on the main window's screen and sized to its content.
The Primary area shall return to the view shown before the frame was attached.

- **Acceptance:** float EQ at a known spot, attach, detach: EQ floats at the same spot.

#### REQ-009 — Views survive mode changes

WHEN a frame is attached or detached, its device views shall be moved and not recreated: control state, scroll
position and data streams (meters, analyzers) shall continue.

- **Acceptance:** with audio playing through the EQ, attach and detach repeatedly: the analyzer keeps
  updating and the selected band stays selected.

### Tabs

#### REQ-010 — Window grouping setting

The device window manager shall offer a setting, "Device windows", with two choices: **per channel**
(default) and **per device**.

- **Acceptance:** the setting appears in the Settings dialog; changing it affects frames opened afterwards.

#### REQ-011 — Channel frames

WHERE device windows are grouped per channel, opening a top-level device's window shall show that channel's
frame, creating it if needed, with that device's tab selected. The frame shall hold one tab per top-level
device in the channel's chain that has a Window view or a plugin GUI, in chain order.

- **Acceptance:** on a channel with Polysynth → EQ → Reverb, open Reverb: one frame opens with tabs
  Polysynth, EQ, Reverb and Reverb selected. Open EQ from the device lane: the same frame selects EQ.

#### REQ-012 — Tabs follow the chain

WHILE a channel frame is open, adding, removing, moving or renaming a device in the chain shall update its
tabs to match. IF the last tab is removed, THEN the frame shall close.

- **Acceptance:** with the channel frame open, delete EQ: its tab disappears. Move Reverb first: its tab
  moves first. Delete every device: the frame closes.

#### REQ-013 — Tear off a tab

WHEN a tab is dragged out of its frame, the device shall get a floating frame of its own at the drop
position. Selecting that device's tab in the channel frame afterwards shall bring its own frame to the
front instead.

- **Acceptance:** drag Reverb's tab onto the desktop: Reverb floats separately; clicking Reverb's tab in the
  channel frame raises the Reverb frame.

#### REQ-014 — Per-device frames

WHERE device windows are grouped per device, each opened device shall get its own frame with no tab strip.

- **Acceptance:** with the setting on per device, open EQ and Reverb: two frames, neither shows tabs.

#### REQ-015 — Nested devices

WHEN a nested device's window is opened (a Drum Machine pad's device, a Layer slot's device), it shall open
in a frame of its own, whatever the grouping setting is.

- **Acceptance:** open a pad's Kick window: a separate frame opens; the channel frame gets no Kick tab.

#### REQ-016 — Removed channel or device

WHEN a channel or a device is removed, every frame or tab showing it shall close.

- **Acceptance:** delete the channel whose frame is open: the frame closes. Same for a torn-off device.

### Plugin GUIs

#### REQ-017 — Embedding is experimental and off by default

The settings shall offer an experimental option, "Embed plugin windows", off by default. WHILE it is off,
plugin GUIs shall open in their own window as today, and selecting a plugin's tab in a channel frame shall
open or raise that window while the frame shows a short note that the plugin is in its own window.

- **Acceptance:** with the option off, select a CLAP plugin's tab: its native window opens; the frame shows
  the note; the frame's attach button still attaches the frame.

#### REQ-018 — Embedded plugin GUI

WHILE embedding is on, a plugin's GUI shall be shown inside the frame's content area, in both floating and
attached frames. It shall move, minimize and change workspace together with the frame, and no separate
plugin window shall be visible.

- **Acceptance:** open Dragonfly Room Reverb: it shows inside a Sonara frame. Move the frame, minimize it,
  switch workspace: the plugin GUI stays inside the frame.

#### REQ-019 — Fixed-size plugins

WHILE embedding is on and a plugin GUI cannot be resized, a floating frame shall open sized to fit the GUI,
and when the content area is bigger than the GUI it shall be centered on a black background.

- **Acceptance:** attach Dragonfly in a large main window: the GUI is centered with black margins.

#### REQ-020 — Resizable plugins

WHILE embedding is on and a plugin GUI can be resized, the GUI shall be resized to fill the content area
whenever that area changes size, within the size limits and aspect ratio the plugin accepts. Any area left
over shall be black, with the GUI centered.

- **Acceptance:** with a resizable plugin attached, resize the main window: the plugin GUI grows and shrinks
  with it.

#### REQ-021 — Plugins larger than the content area

IF a plugin GUI is larger than the content area, THEN it shall be clipped to the area and scrollbars shall
scroll it.

- **Acceptance:** attach Dragonfly, then shrink the main window below its size: the GUI is clipped,
  scrollbars appear, scrolling reveals the rest, and its controls still respond at the scrolled position.

#### REQ-022 — No reopen on mode or tab changes

WHILE embedding is on, attaching, detaching, and switching tabs shall neither close nor reopen a plugin's
GUI. A hidden tab's plugin GUI shall be hidden and shown again when its tab is selected.

- **Acceptance:** engine log shows a single gui/open for the plugin across repeated attach, detach and
  tab switches.

#### REQ-023 — Clean close

WHEN a frame holding an embedded plugin GUI closes, the plugin GUI shall close without any window appearing
on screen, and without X errors in the plugin host's log.

- **Acceptance:** close a frame with Dragonfly attached, and with it floating: nothing flashes on screen;
  `Engine/logs/last_combined.log` has no X11 error lines.

#### REQ-024 — Plugins that can't be embedded

IF a plugin only supports floating GUIs, THEN it shall open in its own window as if embedding were off,
and the attach button shall be disabled with a tooltip saying the plugin can't be attached.

- **Acceptance:** with a floating-only plugin, the frame shows the "own window" note and attach is
  disabled with the tooltip.

#### REQ-025 — Not on X11

IF Sonara isn't running on the X11 display server, THEN the "Embed plugin windows" option shall be
disabled with a note that it requires X11, and plugin GUIs shall behave as with the option off.

- **Acceptance:** run Godot with `--display-driver wayland`: the option is disabled with the note.

#### REQ-026 — Crashed plugin

WHEN an embedded plugin's host process crashes, its tab shall show the crashed state with a reload action,
and WHEN the plugin is reloaded its GUI shall come back embedded in the same tab.

- **Acceptance:** kill the plugin host process while the GUI is attached: the tab shows the crash and
  reload; reload brings the GUI back in place.

#### REQ-027 — Engine restart

WHEN the engine stops while plugin GUIs are embedded, the device frames shall stay open and functional for
built-in views, and the plugin tabs shall show the plugin as unavailable rather than leaving a blank area.

- **Acceptance:** stop the engine with Dragonfly attached: the tab shows "unavailable", the app is usable.

## Non-functional

- **Real-time safety:** unchanged. Nothing here runs on the audio callback; plugin GUI work stays on the main
  thread, the WindowManager thread and the plugin host's GUI thread.
- **Robustness:** an X11 error caused by embedding shall never terminate the engine or the plugin host.
- **Compatibility:** with embedding off, plugin GUI behaviour matches today's except for the channel frame
  note (REQ-017). Older projects and configs load unchanged.

## Out of scope

- Persisting frames: mode, position, size and open tabs are not saved in projects or config (v1).
- Tabs for nested devices inside a channel frame.
- Embedding on native Wayland, macOS or Windows.
- More than one attached frame, or splitting the Primary area.
- Plugin GUI scaling (HiDPI `set_scale`) beyond today's behaviour.
- Fixing Godot's X11 event handling upstream (the bug gets reported separately).

## Open questions

None open. Deferred (decided 2026-10-06):

- **Menus and tooltips over embedded plugins** — Sonara's own popups draw under an embedded plugin GUI unless
  Godot renders popups as native windows, which would change popup behaviour app-wide. Accepted for v1: most
  popups open from controls below the plugin area and flow downwards.
- **Keyboard shortcuts while a plugin has focus** — clicking into a plugin GUI takes keyboard focus from
  Godot (as with today's floating windows). Forwarding unhandled keys back to Sonara, possibly as a setting,
  is a later feature.
