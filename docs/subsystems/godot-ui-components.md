# Godot UI components

Design rules for the small reusable controls in `Godot/components/` (knobs, sliders, faders,
meters, the envelope editor) and the views built from them. Read this before you add a control
or change how one looks or behaves.

## Principles

### 1. Progressive visibility
Show the value at rest and reveal the rest on demand, in this order:

1. **At rest:** only what reads the value: the fill, arc, level bar or curve. No handles, no numbers.
2. **Hover:** the handle, the exact value in a `ValueTooltip`, and the full text of any trimmed caption.
3. **Drag:** the same as hover, and it stays visible even when the pointer leaves the control.
4. **Double-click:** type an exact value in a `FloatingValueEditor`.

Examples: `HorSlider.handle_on_hover_only` (on by default), the Volumeter handle, the
EnvelopeControl handle highlight and tooltip, and `LabelOverlay` for captions. When hiding the
handle leaves nothing on screen at a common value, add a faint marker so the value still reads.
For example, a two-sided HorSlider draws a center tick so a centered pan doesn't look empty.

Things that always stay visible:
- Warnings: clip lines and clip lights. The Volumeter holds its clip line for 10 s.
- Controls where the handles *are* the value, such as the dual pan slider's two handles.

### 2. Conserve space; overlays never shift layout
Mixer strips, track headers and Simple View cells are tight. Anything that shows up on
interaction is a **top-level, click-through overlay**: `top_level = true`,
`mouse_filter = MOUSE_FILTER_IGNORE`, added as an internal child
(`add_child(node, false, Node.INTERNAL_MODE_BACK)`). This covers tooltips, full-caption
overlays and drop indicators (see `godot-drag-and-drop.md`).

- Captions have a fixed width and trim with `TextServer.OVERRUN_TRIM_ELLIPSIS`. Never let a long
  name widen a strip.
- When a caption and a value readout share a row, show the value only while both fit. Otherwise
  hide it and show it while the value control is hovered or dragged; the caption trims to make
  room and the row never widens (`CompactParameterControl`). Dropdowns set
  `fit_to_longest_item = false` and trim the selected item.
- Place a value tooltip on the side away from the caption. Captions go above in Simple View and
  below in the sends panel, so the readout never covers the name (`RotaryKnob.tooltip_side`).
- A readout drawn over its own control uses a plain `ValueTooltip` (`set_plain(true)`, then
  `place_over`): no panel, outlined and shadowed text. The mixer pan strip does this. On hover in
  Stereo Combined it shows only the part under the pointer (`HDualSlider.pick_at`): the width
  (`W: 25`) on a handle or the empty space beside one, the position over the fill. Pan values are
  signed percents (`-30`, `0`, `80`), not L/R.
- Keep everything inside the control's rect. The EnvelopeControl insets its curve by the
  handle radius, so handles at min or max don't draw outside.

### 3. Consistent interaction
Every value control should behave the same way, so users learn it once:

| Gesture | Meaning | Where it exists today |
|---|---|---|
| Drag | Change the value | all |
| Shift + drag | Fine adjustment (0.15×), with no jump when Shift is pressed or released mid-drag | all (knob via relative motion, the rest via `FineDrag`) |
| Double-click | Type an exact value | RotaryKnob, Fader, VSlider, Meter fader, Volumeter |
| Ctrl/Cmd + click | Reset to default | RotaryKnob, Fader, HorSlider, Meter fader |
| Right-click | Context menu (mode, options) | PanControl, send knobs |

RotaryKnob, Fader, HorSlider and Meter report how the last change was made in `last_edit_kind`
(`ValueEditKind`: `DRAG`, `TYPED`, `RESET`). Read it inside the `value_changed` handler when a
drag and an absolute entry should behave differently (mixer multi-edit does). Knob and slider
also emit `reset_requested` on every Ctrl/Cmd-click, even when already at the default.

**Mixer multi-edit.** With several strips selected, editing volume, pan or a send level on one
selected strip applies to all (`mixer/ChannelMultiEdit.gd`): a drag moves the others by the same
amount, a typed value sets them all, Ctrl/Cmd-click resets each to its own default. One gesture is
one undo step (`ChannelsPropertyCommand`). A control gets the peers from
`Mixer.get_multi_edit_peers()`, so a control outside a Mixer edits only its own channel.

A new control should support the whole row, not just drag. Gaps in the right-hand column are
backlog, not intent.

- **Absolute sliders:** the press jumps to the pointer, then motion goes through
  `FineDrag.update(mouse, event.shift_pressed, bounds)`.
- **Handle grabs** (envelope points): use `FineDrag.begin_at(handle_pos, mouse)` so the handle
  doesn't jump on press.
- **Drag events:** handle drags in `_gui_input` motion events. Don't poll `Input` in `_process`.
- **Signals:** emit the change signal only when the value actually changes.

### 4. Modular and reusable
Build controls from the shared pieces below instead of copying their logic. When two controls
start copying the same behavior, extract it into a component. That's how `ValueTooltip`,
`FineDrag` and `LabelOverlay` came about.

- A component owns presentation and input only. It gets data through setters and
  `set_value_no_signal`/`set_*_no_signal`, and reports changes through signals. It never sends OSC
  or touches `Project` data; the view that binds it does that (see the data-model rule in
  `AGENTS.md`).
- Expose look and behavior as `@export`s with sensible defaults: colors, sizes, sides,
  `handle_on_hover_only`, `time_curve`. A view overrides only what differs.
- Data that describes a domain object belongs in a resource, not in the control. For example,
  `Envelope` holds the stage values, ranges and `stages` subset, and `EnvelopeControl` only
  draws and edits it.

### 5. One visual system
- Level meters use the mixer strip's colors everywhere (a Volumeter or any new meter matches
  `Meter` in `MixerChannel.tscn`): low `(0.728, 0.8, 0.08)`, high `(0.8, 0.416, 0.08)`, clip
  `(0.8, 0.08, 0.08)`, dark background, white-smoke handle.
- `LevelMeter` has two colour modes. ZONES uses `safe_color` below `warn_db`, then the warn and
  clip colours; SOLID uses `safe_color` only. The compressor view sets the safe colour to
  `UiColors.PRIMARY`. Whether the mixer meter follows is left to the theme follow-up
  (spec 015 §2.6).
- Volume controls share the -60 to +6 dB range of the mixer fader.
- Editor backgrounds are near-black (`#111`), not pure black. Grid lines are faint white
  (`Color(1, 1, 1, 0.06)`).
- Floating panels (tooltips, overlays) use the dark rounded style in `ValueTooltip` and
  `LabelOverlay`: `Color(0.08, 0.08, 0.1, 0.94)`, 3 px corners.

## Shared pieces

| Component | Use it for |
|---|---|
| `FineDrag.gd` | Pointer tracking with Shift precision for any drag control |
| `ValueTooltip.gd` | Floating value readout: `ValueTooltip.attach(host)`, then `place_above` / `place_below` / `place_right_of`, or `set_plain(true)` + `place_over` for text over the control |
| `LabelOverlay.gd` | Full text of a trimmed Label on hover: `LabelOverlay.attach(label, [hover sources])` |
| `FloatingValueEditor.gd` | Double-click value entry |
| `LabeledKnob.gd` | Knob plus caption (`label_position` TOP/BOTTOM, `label_width`, `knob_size`) |
| `DropIndicator.gd` | Drop position glow (see `godot-drag-and-drop.md`) |
| `core/UiColors.gd` | Colour tokens (`PRIMARY` `#624d99`, `TRACK_BG`, the meter palette). New components default to these |
| `Fader.gd` | Vertical value control (the knob's sibling): `min/max/value_default`, `logarithmic` or `to_position`/`from_position`, `fill_origin`, `scale_marks` + `scale_side`, `overlay_level`, `ghost_value`, mod contract. `value_to_position(v)` maps a value onto the track |
| `ScaleMarks.gd` | Tick/label layout through a value→0..1 Callable, so marks sit where the fill does |
| `SegmentedControl.gd` | Exclusive toggle-button row: `set_items`, `selected` / `set_selected_no_signal`, `selected_changed` |
| `meter/MeterBallistics.gd` | dB-domain peak release, hold and RMS smoothing for any meter that draws itself (`push`, `step`, `settled`) |
| `meter/LevelMeter.gd` | Configurable dB meter: N bars, `display` PEAK/RMS/BOTH, ZONES/SOLID colour, LEVEL or REDUCTION (GR from the top), scale, readout, caption. `push(index, peak_db, rms_db)`; click resets holds |

Controls built on them: `RotaryKnob` (Inspector exports grouped into Value, Appearance, Tooltip, and
Interaction; Appearance includes `arc_offset`, `shadow_width`, `knob_line_length`, plus a Modulation
subgroup for range-arc width, spacing, inset, and live-marker size/color), `HorSlider` (single) and
`HDualSlider` (pan),
`VolumeSlider` (`VSlider.gd`), `Meter` (mixer strip, optional fader), `Volumeter` (track header
meter and fader), `XYSlider`, and `EnvelopeControl` with the `Envelope` resource (any subset of
ADSR).

## Modulation display and assign mode

`RotaryKnob`, `HorSlider`, `Fader`, `VolumeSlider` and `Volumeter` share one modulation contract (there
are no traits in GDScript, so each implements it; the maths is in `ModDisplay.gd`):

- `mod_ranges: Array[Dictionary]` of `{amount, color, source, bipolar}` is drawn from the base value
  to base + amount (both ways for a bipolar source): an arc just inside the knob ring, a bar along
  the top of a `HorSlider`, a bar down the right edge of a `VolumeSlider` or `Volumeter`.
- `mod_assign_active` / `mod_assign_color` / `mod_assign_amount`: while active the control gets an
  outline, and dragging edits the amount instead of the value. It emits
  `mod_amount_changed(new_amount)` and never `value_changed`. One full-range drag moves the amount
  by 1.0 (normalized units); Shift is fine drag; a double-click emits 0, which removes the route.
  Ctrl-click reset and typed entry are off in assign mode.
- `mod_amount_text_callback` (Callable(amount) -> String) sets the assign tooltip. `ModAssign.attach`
  gives "+1.2 oct" for logarithmic parameters and "+35 %" otherwise.
- `mod_live_value` (0..1, -1 for none) is the current effective (modulated) value: on
  RotaryKnob the value arc follows it in real time while the knob line stays at the assigned
  value, and it returns to the set value when no voice is modulating (spec 018 Phase 9).
  `mod_live_values` (0..1) draws playback markers, one per sounding voice. `ModLive` feeds
  both from the engine's `modulation` data stream.

A control joins the contract through `ModAssign.attach(node, device, param_id)` (spec 018):
`SimpleControl`'s inner knobs/sliders and envelope knobs, `CompactParameterControl`'s slider, and the
custom EQ/compressor/multiband/sampler knobs call it. It wires `mod_amount_changed` to the active
modulator's route, feeds `mod_ranges` from `get_routes_into` on the device and every ancestor, and
sets `mod_assign_active`/colors while assign mode is on. Source colors are
`ModDisplay.source_color(index)`, by the modulator's index on its owning device (the tile order in
the Modulators pane). Tests: `tests/test_mod_assign_ui.gd` (the component contract),
`tests/test_modulators_ui.gd` (the pane, tiles and assign wiring).

`VolumeSlider` and `Volumeter` have the API, but nothing feeds them until channel parameters can be
modulated (mixer parameters are out of scope for spec 018).

## Checklist for a new or changed control

- [ ] Value readable at rest; handle and exact value on hover or drag; typed entry on double-click
- [ ] Shift fine drag through `FineDrag`; Ctrl/Cmd-click reset where a default exists
- [ ] Overlays are top-level and click-through; nothing shifts layout or draws outside the rect
- [ ] Captions trim with an ellipsis and use `LabelOverlay`
- [ ] Colors and ranges match the existing system; looks exposed as `@export`s
- [ ] `*_no_signal` setters for syncing from data; signals only on real changes
- [ ] Headless test for the behavior (see `tests/test_value_controls.gd`,
      `tests/test_envelope_control.gd`). The headless pointer sits at (0, 0), so place test
      controls elsewhere to avoid spurious hovers.

## Component gallery

Open `Godot/components/ComponentGallery.tscn` in the editor to preview the reusable controls together. Its `PanelContainer` holds an `HFlowContainer` of component cards with fixed sample values; `ComponentGallery.gd` seeds the meters and knob modulation ranges/live markers for a useful static preview. The gallery is presentation-only and does not bind to project or engine state.
