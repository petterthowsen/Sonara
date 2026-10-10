# Modulator panel — Requirements

Requirements for restructuring the Modulators pane of the DevicePanel (spec 018) into a
square-panel grid with per-kind live displays and drag-to-reorder. Written against
`docs/specs/_templates/requirements.md`. No file names or technology choices here; those
belong in `design.md`.

Context: spec 018 shipped modulators as a 2-column list of small wide tiles (86×42) with a
"+ Add modulator" menu button and a separate detail column to the right. The tiles carry no
visual identity per kind, give no live feedback, and cannot be rearranged. The engine already
supports routing one modulator to another modulator's parameter (route target
`mod/{mod_id}/param/{param_id}`), but neither is reachable from the current tiles. The
`modulation` data stream carries only routed-parameter contributions, not each modulator's
own live value, so a per-modulator display has no data source yet. The engine also stores
modulator-to-modulator routes without evaluating them, so making them reachable needs engine
work, not only UI.

## Problem

The Modulators pane is a flat text list: modulators cannot be told apart at a glance (name +
colour strip only), there is no live feedback on what a modulator is doing (the user must
route it somewhere and watch a knob), the "+" header button wastes vertical space, and the
tile order is fixed at creation order — there is no way to reorganize modulators that belong
together. Routing a modulator to another modulator's parameter, which the engine supports, has
no UI affordance at all.

## Scope

| | |
|---|---|
| Subsystem | Godot (modulators pane) + Engine (modulation data-stream payload) |
| Touches real-time audio thread | yes — the `modulation` device-data payload gains per-modulator live-state records, built in the existing payload on the callback with no additional allocation; modulator evaluation gains modulator-to-modulator offsets (fixed-size, one control step of delay), on both the mono path and the per-voice path of voice-modulating devices |
| Adds or changes an OSC message | no new address; the `modulation` data stream gains a record kind — protocol docs are part of the definition of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no — modulator order is the existing array order in the saved project; reordering rewrites that order, no new keys |

## Requirements

### Layout

**REQ-001 — Square panel grid.** The Modulators pane shall lay its modulators out as a grid
of square panels, fixed at 3 rows, with the column count computed from the number of
modulators, and a panel-to-panel spacing of 1–2 px.

- **Acceptance:** every modulator panel measures as wide as it is tall at the pane's natural
  size; visual gap between adjacent panels is 1 or 2 px.
- **Example:** 4 modulators → 2 columns × 3 rows with 2 cells free.

**REQ-002 — Always a placeholder.** The pane shall always show at least one empty placeholder
cell (a square panel whose entire content is a large **+** icon button), and, WHEN a
placeholder is the last free cell in the grid, the pane shall add one column of 3 new
placeholders. WHILE the device holds the maximum number of modulators (8), the remaining
placeholder shall be shown disabled.

- **Acceptance:** after adding a modulator into the last free cell, the grid is one column
  wider; there is never a state with zero placeholders; at 8 modulators the placeholder is
  disabled and explains the limit in its tooltip.
- **Example:** the "no modulators exist" case shows 1 column of 3 placeholder panels; filling
  all 3 grows the grid to a second column.

**REQ-003 — Placeholder replaces the Add button.** The pane shall have no separate
"Add modulator" header button; WHEN a placeholder's **+** is activated, it shall open a menu
listing the available modulator kinds, and WHEN a kind is chosen, a modulator of that kind
shall be created in the first free cell and selected.

- **Acceptance:** the header shows only the title; every available kind (registry-driven,
  including future kinds) appears in the placeholder menu; the new modulator occupies the
  first free cell (the order has no gaps: array order is the only position, REQ-008).
- **Example:** a device with no modulators, click any **+**, pick "LFO" → an LFO panel sits in
  the top-left cell and its settings show in the detail column.

**REQ-004 — Grid shrink.** WHEN deleting modulators leaves an entire trailing column unused,
the pane shall remove that column (down to a minimum of 1 column).

- **Acceptance:** deleting down from 4 modulators to 3 keeps 1 column of panels + 1 column of
  placeholders; column count equals `max(1, ceil(count / 3))` for panels, plus placeholder
  fill of the last panel column.

**REQ-005 — Panel styling and selection.** Each modulator panel shall be styled as a panel
consistent with the app's other panels; WHILE a modulator is selected, its panel shall show a
light border in the app's standard selection style.

- **Acceptance:** selected panel has a 1 px light border (same treatment as other selected
  app elements); unselected panels have no border emphasis.

**REQ-006 — Connect button.** Each modulator panel shall place its connect (assign) button
centered at the bottom of the panel.

- **Acceptance:** the button's horizontal center matches the panel's center; it remains
  reachable without covering the display area.

### Ordering

**REQ-007 — Rearrangeable order.** The pane shall give each modulator a position in a
user-rearrangeable order, and WHEN a modulator panel is dragged onto another panel's cell,
the two modulators' positions shall swap so the dragged one lands in the target cell.

- **Acceptance:** drag panel A onto panel B → A occupies B's former cell and vice versa; the
  new order is reflected in colour assignment, saved projects, and (for equal settings) audible
  evaluation order-independent behaviour is unchanged.
- **Example:** dragging the third LFO onto the first cell makes it the first modulator in the
  saved project's modulator array.

**REQ-008 — Order persists.** The modulator order shall round-trip through project save/load
and engine↔UI sync without a new persisted key (array order is the order).

- **Acceptance:** save a project with modulators rearranged, reload it, the panels appear in
  the rearranged order.

### Displays

**REQ-009 — Live display area.** The main area of each modulator panel shall render a
kind-specific display, and the pane shall update it from live modulator values, including a
position marker (a white dot) that follows the live value, matching the live-feedback language
of knobs.

- **Acceptance:** for an LFO, the display draws the current waveform as a primary-coloured
  line and the white dot rides the waveform at the current phase; for envelope modulators
  (ADSR, AD), the display draws the envelope shape and the dot rides the current
  envelope stage/value.
- **Example:** playing a note with an ADSR modulator selected shows the dot sweeping attack →
  sustain and returning on release.

**REQ-010 — Display fallback.** Modulator kinds without a meaningful shape (velocity,
keytrack, random, release velocity, MIDI CC and any future kind) shall show a generic live display (the kind's
current value as a level/curve), and an unknown kind shall never break the pane.

- **Acceptance:** every advertised kind renders something live; adding a hypothetical new kind
  via the registry shows the generic display without code changes to this requirement.

### Modulator-to-modulator routing

**REQ-011 — Assign to another modulator.** The assign flow (connect button → drag onto a
control) shall accept a target modulator's parameter as a drop target, producing the engine's
existing modulator-to-modulator route.

- **Acceptance:** while assign mode is active for modulator A, dragging onto modulator B's
  parameter control creates a route from A to that parameter of B; B's parameter knob shows
  A's modulation amount while hovering, as device parameters already do; the route is
  audible, including on voice-modulating devices (PolySynth). A modulator's own knobs are
  not targets for itself; envelope stage handles (EnvelopeControl) are not targets in this
  spec; deleting a modulator removes every route into it.
- **Example:** LFO "A" wired to LFO "B" Rate at +0.5 makes B's rate knob breathe at A's tempo.

### Detail column

**REQ-012 — Detail column unchanged in role.** The pane shall keep the selected modulator's
parameter controls in the existing detail column beside the grid.

- **Acceptance:** selecting a panel shows its settings on the right; deselecting hides them;
  existing controls (EnvelopeControl, knobs, enum selectors) continue to work unchanged.

## Non-functional

- **Real-time safety:** the display records add no engine-side state and are fixed-capacity;
  they are written into the existing `modulation` payload, which `poll_device_data` builds on
  the audio callback, without any allocation beyond the payload's existing pre-sized buffer
  (moving device-data serialization off the callback is out of scope). Modulator-to-modulator
  evaluation adds only fixed-size per-modulator offset arrays. Reorder
  is a Godot-model array move that only changes save order: the engine stores modulators as
  fixed slots keyed by mod id, so evaluation is order-independent and no reorder command
  exists.
- **Performance:** displays redraw at the existing modulator data-stream rate; the pane must
  not subscribe or redraw when no view of the device is shown (existing stream rules).
- **Compatibility:** old projects load unchanged (modulator array order is already the
  storage); the spec-032 `cc` kind renders in the generic display until given a bespoke one.

## Out of scope

- New modulator kinds, or changing any kind's parameters.
- Engine-side evaluation-order semantics of modulator chains beyond preserving current
  behaviour under reorder (evaluation is by route, not by slot order).
- Custom/user-authored display widgets or per-kind display settings.
- Changing the detail column's control set, layout or the automation-lane integration.

## Open questions

- [ ] None blocking. Display content per kind beyond LFO and envelopes (e.g. MIDI CC level,
      random walk) is decided in design.md under REQ-010's generic display.
