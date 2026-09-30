# Time Signature Changes — Requirements

## Problem

A project has one static time signature (the top-bar field). Songs that change meter (4/4 → 7/8 →
4/4) cannot be written: bar lines, bar numbers and snapping in the arranger assume one meter, and
the engine tells devices and CLAP plugins a single signature for the whole song.

## Scope

| | |
|---|---|
| Subsystem | both |
| Touches real-time audio thread | yes — the transport info given to devices and plugins reads the signature at the current tick |
| Adds or changes an OSC message | yes — a new message carries the signature map to the engine |
| Changes the plugin subprocess protocol | no — the per-block transport info already carries a signature |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes — `.sonara` gains `time_signature_map` and a `time_signature` entry in `ruler_lanes`; older projects load with an empty map and the lane hidden |

## Definitions

- **Base signature** — the project's static signature (top-bar field). It applies from tick 0
  until the first change.
- **Signature change** — `(bar, numerator, denominator)`. It applies from the start of that bar
  until the next change. Changes sit on bar lines, so they are stored by bar number (1-based) and
  their tick follows from the changes before them.
- **Signature map** — the ordered signature changes. Empty means the base signature applies everywhere.
- **Beat** — a 1/denominator note (an eighth in 7/8), as elsewhere in Sonara.

## Requirements

### REQ-001 — Lane toggle

The arranger ruler shall have a toggle that shows or hides a time signature lane, drawn below the
beats and time rulers and above the tempo lane, in the same place and style as the marker lane.

- **Acceptance:** Godot test — toggling shows/hides the lane node. The lane sits directly below the
  bar/beat ruler and above the tempo lane. Live: lane visible only when toggled on.
- **Example:** default off in a new project.

### REQ-002 — Lane state persists

The project shall save whether the lane is shown, and shall restore it on load.

- **Acceptance:** extend `test_ruler_lanes_persist.gd` with `time_signature`.

### REQ-003 — Signature changes are shown as labeled items

The lane shall draw each signature change as an item at its bar line, labeled `N/D`.

- **Acceptance:** live/screenshot; unit test that the lane holds one item per change.
- **Example:** change at bar 5 of 7/8 → item at the x of bar 5 labeled `7/8`.

### REQ-004 — Add a change

WHEN the user double-clicks empty lane space or chooses Add from the lane's right-click menu, the
arranger shall add a signature change at the nearest bar line and open its value for editing. The
new change starts equal to the signature in effect there.

- **Acceptance:** Godot test on the model action; undo removes it.
- **Example:** double-click near bar 5 while 4/4 is in effect → change `(5, 4, 4)` opened for editing.

### REQ-005 — Edit the value as text

WHEN the user double-clicks a change (or chooses Edit in its menu), the arranger shall let them type
a value as `N/D` (e.g. `4/4`, `7/8`) and apply it on Enter. IF the text is not a valid signature,
THEN the arranger shall keep the old value.

- **Acceptance:** unit test on the parser: `7/8`, ` 3 / 4 ` valid; `0/4`, `4/3`, `4`, `a/b`, `33/4` invalid.
  Valid: numerator 1–32, denominator a power of two 1–32.
- **Undo:** each edit is one undo step.

### REQ-006 — Move a change

WHEN the user drags a change, the arranger shall move it to the bar line under the pointer, staying
between its neighbours. Moving one change shifts every later bar line in time; the changes after it
keep their bar numbers, and everything else (clips, markers, tempo points) keeps its tick.

- **Acceptance:** unit test — moving `(5, 7, 8)` to bar 3 puts it at the tick of bar 3 under the
  earlier map; undo restores. Move is one undo step.

### REQ-007 — Delete a change

WHEN the user chooses Delete in a change's menu, the arranger shall remove it, so the previous
signature applies through to the next change.

- **Acceptance:** Godot test; undo restores.

### REQ-008 — Arranger grid follows the map

The arranger's ruler, grid lines, bar numbers, snapping and the transport position readout (BBT)
shall use the signature in effect at each tick.

- **Acceptance:** unit tests on `GridHelper`: with base 4/4 and change `(3, 7, 8)`, bar 3 starts at
  tick 7680 (two 4/4 bars at 960 PPQ), bar 4 at 7680 + 7 × 480 = 11040; `bbt_of(11040)` = bar 4, beat 1;
  beat lines inside bar 3 are 480 ticks apart.
- **Example:** as above, tick 7680 + 480 → bar 3, beat 2.

### REQ-009 — Base signature edits

WHEN the user edits the top-bar signature field, the base signature shall change, and the changes
in the lane shall keep their bar numbers.

- **Acceptance:** unit test — base 4/4 → 3/4 with change `(3, 7, 8)`: bar 3 now starts at tick 5760.

### REQ-010 — Engine receives the map

WHEN the project connects to the engine, or the signature map or base signature changes (add, move,
edit, delete, undo, redo, project load), the engine shall hold a signature map equal to Godot's.

- **Acceptance:** engine log line on receipt reports the change count; unit test on the handler
  parses N changes into N engine entries in bar order.

### REQ-011 — Devices and plugins see the signature in effect

WHILE the transport is playing or stopped, the transport info the audio callback gives devices and
CLAP plugins shall carry the signature in effect at the current tick.

- **Acceptance:** engine unit test on the transport snapshot: base 4/4 with change `(3, 7, 8)`,
  snapshot at tick 7680 reports 7/8, at tick 7679 reports 4/4. Live: a tempo-synced plugin's bar
  position follows.

### REQ-012 — Empty map keeps today's behaviour

IF the signature map is empty, THEN Godot and the engine shall behave exactly as they do today
with the base signature.

- **Acceptance:** existing `Godot/tests/run_all.sh` and `cargo test` pass unchanged.

### REQ-013 — Unchanged callers of the static signature

Places that read one static signature for a sequence of bars (clip editor grid, AI clip text bar
length) shall keep using the base signature; only the arranger and the engine transport follow the map.

- **Acceptance:** documented in the design; no behaviour change in those tests.

## Non-functional

- **Real-time safety:** the audio callback reads the map with no allocation, lock or I/O (same
  rules as the tempo map). Lookup per block, not per frame.
- **Compatibility:** projects without `time_signature_map` load unchanged; an engine without the new
  message ignores it (unknown OSC address), so the base signature still plays.

## Out of scope

- Key signature changes (separate item in STATUS.md).
- Metronome accents by bar (the engine has no metronome that reads the signature).
- Time signature changes in the clip editor's own grid.
- Changing the beat unit while keeping the tempo's meaning (tempo stays quarter-note BPM).
- Moving other content (clips, markers) when a signature moves.

## Open questions

- [x] Lane position. Resolved: the arranger header today is time ruler, marker lane, bar/beat
      ruler, tempo lane. The signature lane goes between the bar/beat ruler and the tempo lane.
