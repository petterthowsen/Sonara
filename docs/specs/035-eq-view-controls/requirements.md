# CompactHSlider and EQ view controls — Requirements

## Problem

The EQ's panel footer and companion strips use tall knob stacks (`LabeledKnob`, 34×34 knob + label
each) that eat vertical space in the device panel, and the companion view (`EqBandsCompanionView`)
cannot solo a band or change a band's type — you must open the window view and use the selected-band
footer. A compact, text-first slider component would fit the footer better and is generally useful,
but no such component exists yet.

## Scope

| | |
|---|---|
| Subsystem | Godot (components, EQ device views, gallery); no engine changes |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no — all controls bind to existing EQ parameters (`P_ENABLED`, `P_TYPE`, `LISTEN_BAND`) |

## Requirements

### REQ-001 — CompactHSlider component

The Godot components library shall provide a `CompactHSlider` control that shows only a formatted
value (e.g. "2.4 kHz", "+1.2 dB", "0.71") with a thin horizontal value bar below it.

- **Acceptance:** `Godot/components/CompactHSlider.gd` exists with `class_name CompactSlider`; a new
  gallery card in `ComponentGallery.tscn` previews it with a demo value.
- **Example:** value 2400 with the freq formatter renders "2.4 kHz".

### REQ-002 — CompactHSlider editing

WHEN the user left-clicks and drags vertically on a `CompactHSlider`, the component shall change
its value proportionally to the vertical drag distance, with `Shift` applying the shared fine-drag
scale (FineDrag), `Ctrl/Cmd+click` resetting to `default_value` (emitting `reset_requested`), and
a double-click opening the floating value editor (`FloatingValueEditor`) for typed entry.

- **Acceptance:** headless test drives `_gui_input` with synthetic mouse events and checks the
  resulting values/signals; Ctrl+click on a non-default value restores `default_value`.
- **Example:** drag of −60 px with the default sensitivity lowers the value; double-click opens the
  editor pre-filled with the current value text.

### REQ-003 — CompactHSlider value formatting

The `CompactHSlider` shall format its value through a `value_text_callback` (falling back to
`"%g"` + optional `unit`), support `min_value`/`max_value`/`step`/`default_value` and an optional
logarithmic drag-and-bar mapping, and render the bar fill bidirectionally from the centre when the
range spans negative and positive values.

- **Acceptance:** headless test checks formatted text, log mapping (freq 20 Hz–20 kHz), snapping to
  `step`, and bidirectional fill position.
- **Example:** min −24, max +24, value 0 → bar fills from the centre; value +12 → right half.

### REQ-004 — CompactHSlider modulation

The `CompactHSlider` shall support the modulation surface used by `RotaryKnob`/`HorSlider`:
`mod_ranges` (route bars), `mod_live_values` (live markers), `mod_hint_active`/`mod_hint_color`,
and `mod_assign_active` drag-to-assign with `mod_amount_changed` and the assign tooltip, so
`ModAssign.attach()` works unchanged.

- **Acceptance:** headless test sets `mod_ranges`/`mod_assign_active` and drives a drag; the amount
  signal fires and no exception is raised; `ModAssign.attach(compact_slider, device, param_id)`
  wires it (verified in REQ-008 tests by reusing the attach path).
- **Example:** assigning a modulator and dragging vertically changes only the routed amount.

### REQ-005 — CompactHSlider theming

The `CompactHSlider` shall theme through `ThemedColors` with the component prefix
`CompactSlider`, exposing at least `text`, `bar_bg`, `bar_fill` and `mod_live` colors, and refresh on
`NOTIFICATION_THEME_CHANGED`.

- **Acceptance:** the gallery card renders with the active theme; a theme switch re-colours it
  (live check).

### REQ-006 — Reusable band type icons

The band type icons (currently `EqTypeIcon`, drawn procedurally from `EqResponse` magnitude curves)
shall be standardized as a reusable API: the `EqTypeIcon` control stays, and a new
`EqTypeIcon.texture(type, color) -> ImageTexture` renders the same curve for use as item icons in
`OptionButton` dropdowns.

- **Acceptance:** both the footer and companion type dropdowns show per-type icons; the texture
  path is covered by a headless test asserting non-empty icons for all 8 types.
- **Example:** "Low Cut" item shows the procedural cut curve, drawn in the band's colour.

### REQ-007 — EQ footer

The EQ panel view (`EqDefaultView`) footer shall contain, in order: a band selector dropdown
(1–8, synced with the curve editor's selection), a solo toggle using the Lucide speaker icon
(`volume-2.svg`) bound to the `LISTEN_BAND` parameter (81), an enabled toggle using the Lucide
power icon (download `power.svg` if missing) bound to the selected band's `P_ENABLED`, a type
dropdown with band type icons (REQ-006) bound to `P_TYPE`, and `CompactHSlider`s for frequency,
gain and Q. The output gain knob stays.

- **Acceptance:** headless test `test_eq_view.gd`-style assertions: band selection updates the
  sliders, solo/enabled/type toggles write the right parameter ids, gain slider dims for
  non-gain types.
- **Example:** selecting band 3, soloing it and dragging frequency writes 30/31/33 params and 81.

### REQ-008 — EQ companion (auxiliary) view

The companion view (`EqBandsCompanionView`) shall add a per-band solo toggle (speaker icon, bound to
`LISTEN_BAND`: pressing solo for band n sets it to n+1, pressing the active solo again sets Off)
and shall replace the static type icon with a type dropdown using the band's colour and the icons
from REQ-006, bound to the band's `P_TYPE`.

- **Acceptance:** headless test drives the toggles/dropdowns and asserts the parameter writes and
  the refresh on `_on_device_parameter_changed`.
- **Example:** changing band 5's type to Notch updates the dropdown selection and the icon colour.


### REQ-009 — Always-selected band

The footer's band selector shall always have a band selected (1–8, no "none" state). WHILE a band
is disabled, its footer controls shall remain interactive (adjustable, toggleable, solo-able) and
only dimmed; the footer row shall not enter a fully inert state.

- **Acceptance:** headless test disables the selected band and asserts the controls still write
  parameters (e.g. a frequency drag while disabled still writes `P_FREQ`); no `-1`/none selection
  is reachable from the selector.
- **Example:** band 2 disabled → dragging its Freq slider still updates parameter 22.


## Non-functional

- **Real-time safety:** untouched — all changes are Godot-side and bind to existing parameters.
- **Compatibility:** no persisted state changes; the companion view gains controls only.
- **Standard look:** the new component follows the interaction conventions of `RotaryKnob`/
  `HorSlider` (FineDrag, Ctrl reset, ValueEditKind, HotkeyActions `control_knob` context).

## Out of scope

- Engine changes (solo already exists as the `LISTEN_BAND` parameter).
- Replacing other views' knobs with `CompactHSlider`.
- New OSC messages or protocol changes.

## Open questions

- [x] Are the auxiliary view's band type icons icons or procedural? — **Procedural**: `EqTypeIcon`
      draws the band's magnitude curve with `EqResponse.filter_db` (verified in source). The spec
      keeps this and standardizes it (REQ-006).

## Resolved questions

- The footer's band selector always has a selection (1–8, no "none" state); a disabled band stays
  selectable and its controls stay adjustable, only dimmed — the current no-band dimming of the
  footer row is removed.
