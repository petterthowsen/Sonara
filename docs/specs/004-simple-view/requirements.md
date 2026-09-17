# Simple View — Requirements

## Problem

Most devices have no custom view. CLAP plugins without a native GUI (or whose GUI is closed),
and builtins without a Panel view, can only be edited through the flat parameter list. That list
is hard to scan for devices with more than a handful of parameters. It doesn't group related
parameters (a reverb's dry and wet levels can be far apart), and it can't show a control that
spans several parameters, like an XY pad. Users want a usable panel for any device without anyone
hand-building a view for it.

## Scope

| | |
|---|---|
| Subsystem | both (Godot view and layout generation; engine exposes richer parameter and plugin metadata) |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | yes. Plugin parameter metadata and plugin feature tags must reach Godot |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. A new per-device layout file; `plugins.json` gains feature tags (old cache entries without them stay loadable) |

## Terms

- **Simple View**: a device view generated from the device's parameters.
- **Layout**: the saved description of a Simple View (pages, cells, controls, labels, units).
- **Device kind**: the inferred type that picks the generation rules: synth, reverb, delay,
  compressor, eq, or generic.
- **Compound control**: one control bound to more than one parameter (XY pad, ADSR envelope, EQ band).

## Requirements

### Generation

### REQ-001 — Simple View for any device

WHEN a user opens the Simple View of a device that has at least one visible parameter, the device
panel shall show a generated view whose controls change the device's parameters, just like the
parameter list does.

- **Acceptance:** Load Dragonfly Hall Reverb, open its Simple View, turn a control, hear the
  change. Moving the same parameter in the parameter list moves the Simple View control.

### REQ-002 — Device kind inference

The Simple View generator shall classify a device as synth, reverb, delay, compressor, eq or
generic, using the device category, the plugin's feature tags and the device name. It shall fall
back to generic when nothing matches.

- **Acceptance:** Headless test: features `["audio-effect","reverb"]` → reverb; a builtin
  Instrument with no tags → synth; features `["audio-effect"]` with name "Foo" → generic.
- **Example:** Dragonfly Plate Reverb → reverb. Builtin `delay` → delay.

### REQ-003 — Control kind per parameter

The Simple View generator shall pick a control for each parameter from its type and metadata:
a toggle for 2-step parameters, a segmented control for 3–5 steps, a dropdown for more than
5 steps, and a knob or slider for continuous parameters.

- **Acceptance:** Headless test with a bool, a 4-value enum, a 12-value enum and a float parameter
  gets back toggle, segmented, dropdown and knob.

### REQ-004 — Hidden and read-only parameters

IF a parameter is marked hidden or read-only by the device, THEN the Simple View generator shall
leave it out of the generated layout.

- **Acceptance:** Headless test: a parameter set with one hidden and one read-only parameter gives
  a layout with neither.

### REQ-005 — Compound controls

The Simple View generator shall combine parameters into a compound control when their names
share a stem and together match a known pattern: `x`/`y` → XY pad; attack/decay/sustain/release
→ envelope; freq/gain/q → EQ band. IF only some parts of a pattern are found, THEN it shall use
single controls for them instead.

- **Acceptance:** Headless test: `position_x` + `position_y` → one XY pad; `band1_freq` +
  `band1_gain` + `band1_q` → one EQ band; `pan_x` alone → one knob.

### REQ-006 — Grouping

The Simple View generator shall place related parameters in one titled group. It shall use the
device's own parameter grouping when there is one (the CLAP module path), and otherwise the rules
of the device kind.

- **Acceptance:** Headless test: parameters with module paths `Early/Size` and `Early/Send` form
  group "Early". For a reverb with no module paths, `Dry Level` and `Wet Level` land in the same
  group.

### REQ-007 — Importance and main page

The Simple View generator shall rank parameters by importance using the device kind's rules. The
first page shall hold the most important parameters, and the other groups shall follow on later pages.

- **Acceptance:** Headless test: for a reverb, mix, decay and size are on page 1. For a synth with
  100 parameters, page 1 holds at most one grid's worth of cells.

### Grid and pages

### REQ-008 — Grid placement

The Simple View shall place controls on a grid of fixed-size cells (default 6 columns × 4 rows
per page). Each control takes a footprint that depends on its control kind (for example, knob
1×1, XY pad 2×2), and no two controls on a page overlap.

- **Acceptance:** Headless test: a generated layout has no overlapping cells, and no cell sits
  outside the grid.

### REQ-009 — Pages

WHILE a layout has more than one page, the Simple View shall let the user move between pages and
shall show which page is active.

- **Acceptance:** Live: a device with more parameters than fit on one page shows page controls,
  and switching pages shows the other controls.

### REQ-010 — Grid size is adjustable

The Simple View shall let the user change a layout's columns and rows. Controls that no longer fit
on their page shall move onto the next free space, without overlapping.

- **Acceptance:** Headless test: shrinking a 6×4 layout to 4×4 keeps every control and has no
  overlaps.

### Persistence and editing

### REQ-011 — Layouts are saved and reused

WHEN a Simple View is generated for a device for the first time, the system shall save the layout
as a human-readable JSON file for that device. Later it shall load that file instead of
generating the layout again, for every instance of the device and across restarts.

- **Acceptance:** Generate Dragonfly Hall's view, restart Godot, reopen it. The file is loaded
  (logged) and the layout is unchanged. Editing the JSON by hand (moving a cell) shows up after the
  view is reopened.

### REQ-012 — Edit mode

WHILE the Simple View is in edit mode, the user shall be able to move and resize controls on the
grid, move controls between pages, add and remove pages, and remove controls. WHEN edit mode is
left, the layout shall be saved.

- **Acceptance:** Live: move a knob to another cell, leave edit mode, reopen the device. The knob
  is still in the new cell.

### REQ-013 — Editable labels and units

WHILE in edit mode, the user shall be able to rename a control's label and a group's title, and to
set a control's display unit (for example ms, dB, %, Hz). The Simple View shall show those instead
of the device's names.

- **Acceptance:** Live: rename Dragonfly's "Early Level" to "ER" and set its unit to "%". The
  control shows "ER" and a percentage value, and still does so after a restart.

### REQ-014 — Add a parameter back

WHILE in edit mode, the user shall be able to add any visible parameter that is not in the layout
as a control.

- **Acceptance:** Live: remove a knob, add it back from the list of parameters missing from the
  layout.

### REQ-015 — Regenerate

WHEN the user chooses to reset a layout, the system shall replace it with a newly generated one,
after a confirmation.

- **Acceptance:** Live: edit a layout, reset it, confirm. The generated layout comes back and the
  file is overwritten.

### REQ-016 — Parameter set changes

IF a saved layout refers to parameters the device no longer has, THEN the Simple View shall leave
those controls out and log a warning. IF the device has visible parameters that the layout doesn't
mention, THEN they shall be added on free cells of the last pages. Everything the user placed
stays where it was.

- **Acceptance:** Headless test: a layout with parameter ids {1,2,99} against a device with
  {1,2,3} drops 99, keeps 1 and 2 in their cells, and adds 3.

### REQ-017 — Broken layout file

IF a layout file can't be parsed, THEN the Simple View shall log a warning, generate a new layout
without overwriting the broken file, and show that layout.

- **Acceptance:** Headless test: invalid JSON gives a generated layout, and the file on disk is
  unchanged.

### Metadata

### REQ-018 — Plugin parameter metadata reaches the UI

The engine shall report, for every CLAP plugin parameter: whether it is stepped, hidden, read-only
or a bypass parameter, and its module path. Stepped parameters shall reach Godot as enum or bool
parameters with their value count, instead of as floats.

- **Acceptance:** Load Dragonfly Hall. Its stepped parameters (if any) show as dropdowns or toggles
  in the parameter list, and the module paths are logged in Godot.

### REQ-019 — Plugin feature tags reach the UI

The engine shall report each discovered CLAP plugin's feature tags to Godot, and the plugin cache
shall keep them.

- **Acceptance:** After a plugin scan, Dragonfly's feature list in `plugins.json` contains
  `reverb`.

## Non-functional

- **Real-time safety:** unchanged. All generation, file I/O and new metadata queries run in Godot,
  or on the engine's plugin-loading or discovery paths, never on the audio callback.
- **Performance:** generating a layout for a device with 500 parameters takes under 100 ms in
  Godot, so opening the view doesn't hitch visibly.
- **Compatibility:** existing projects and the existing `plugins.json` load unchanged. Missing
  feature tags count as "none".

## Out of scope

- Per-project or per-instance layout overrides. A layout is shared by every instance of a device.
- Sharing or importing layout packs.
- Custom drawn controls beyond knob, slider, toggle, segmented, dropdown, XY pad, envelope and EQ band.
- Automation or modulation editing from the Simple View.
- Meters or visualizers in the Simple View.
- LV2 plugins.

## Decisions

- **Placement:** the Simple View is the Panel view for every device that has no registered Panel
  view. Devices that have one get a "Simple" toggle to switch to it.
- **Storage:** `~/.config/sonara/device_layouts/<sanitized device id>.json`, shared across projects.
  Builtins don't ship hand-tuned layouts in the repo.
- **Compact view:** `CompactDevicePanel` doesn't use the Simple View (out of scope).

## Open questions

- None blocking design.
