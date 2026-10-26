# MIDI Editor Automation Lanes — Requirements

## Problem

Automation can only be seen and edited in the Arranger. While writing notes in the MIDI editor's track mode, you can't see or shape the filter sweep, CC or volume ride that plays against those notes, so you have to keep switching views. The Arranger's automation lanes also lack the selection handles the value lanes already have (tilt left, tilt right, compress). Ramping or scaling a group of points means dragging each one by hand.

## Scope

| | |
|---|---|
| Subsystem | Godot |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no. Point and lane edits go through the existing `AutomationLane` mutators and their messages. |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes, two. (1) `.sonara` gains an optional per-track list of the automation lanes open in the MIDI editor. It is additive: a project without the list opens with no lanes open in the MIDI editor, and an older build ignores the key. (2) A new lane preset store in the user library. It is a new file, so nothing needs migrating. |

## Terms

- **Automation pane:** the strip in the MIDI editor, below the value lanes, that holds automation lanes.
- **Open lane:** an automation lane of the focus track that is shown in the automation pane. Opening or closing a lane there never changes whether it shows in the Arranger, and the reverse holds too.
- **Selection handles:** the tilt-left, tilt-right and compress handles that the value lanes show over a multi-selection.
- **Shown lanes:** in the MIDI editor, the open lanes of the focus track. In the Arranger, the lanes of a track whose Arranger visibility is on.
- **Lane preset:** a named, ordered list of automation targets in the user library, for example `Strings` = `CC1 Mod Wheel`, `CC11 Expression`. It holds no points or values.

## Requirements

### Automation pane

#### REQ-001 — Track mode only

WHILE the MIDI editor is in track mode, the clip editor shall offer the automation pane. In clip mode, the automation pane and its toggle shall be hidden.

- **Acceptance:** Godot test: binding in clip mode leaves the pane and toggle hidden. Binding in track mode makes the toggle visible.

#### REQ-002 — Below the value lanes, toggleable

The automation pane shall sit below the value lanes. A toolbar toggle beside the value-lanes toggle shall show and hide the pane, and the clip editor shall remember the toggle's state across sessions as an editor preference.

- **Acceptance:** Godot test: toggling hides and shows the pane, and the state survives building a new clip editor.

#### REQ-003 — Follows the focus track

The automation pane shall show the open lanes of the focus track only. WHEN the focus track changes, the pane shall replace its lanes with the new focus track's open lanes. WHILE no track is focused, the pane shall show no lanes.

- **Acceptance:** Godot test: with tracks A (lane `Filter / Freq` open) and B (lane `Volume` open), focusing A shows only `Filter / Freq`, and focusing B shows only `Volume`.

#### REQ-004 — Aligned with the note grid

Every automation lane in the pane shall map ticks to x exactly as the note area does: the same song ticks, zoom and horizontal scroll. Its grid lines and playhead shall match the note area's.

- **Acceptance:** Godot test: a point at tick 1920 sits at the x of a note starting at tick 1920, both before and after scrolling and zooming.

### Opening, adding and closing lanes

#### REQ-005 — Lane menu

The automation pane shall have an add button that opens a menu listing every automation lane of the focus track, each checked if it is open. Choosing a lane opens or closes it. The menu shall end with an `+ Add new` entry. A lane whose target no longer resolves shall be listed as `<name> (missing)`.

- **Acceptance:** Godot test: with a track holding lanes `Volume` and `Pan`, of which `Volume` is open, the menu lists both, with `Volume` checked and `Add new` last. Choosing `Pan` opens it.

#### REQ-006 — Add a new lane

WHEN the user chooses `+ Add new`, the MIDI editor shall show the same parameter picker as the Arranger's track list. The picker leaves out targets that already have a lane on the track. Choosing a target shall create the lane on the focus track as one undo step, seeded with the parameter's current value, as the Arranger does. The new lane is open in the automation pane and also exists in the Arranger.

- **Acceptance:** Godot test: picking `Pan` on a track with no lanes adds one lane, holding one point at the current pan, to `track.automation_lanes` and opens it in the pane. Undo removes the lane.

#### REQ-007 — Close a lane

Each open lane shall have a close button that closes the lane in the automation pane only. The lane, its points and its effect on playback stay unchanged, and so does its visibility in the Arranger.

- **Acceptance:** Godot test: closing an open lane removes it from the pane, and the track still holds the lane with its points.

#### REQ-008 — Lane deleted elsewhere

IF an open lane is deleted (in the Arranger, by undo, or by the AI assistant), THEN the automation pane shall remove it and drop it from the track's open-lane list.

- **Acceptance:** Godot test: deleting an open lane through `AutomationActions.delete_lane` removes it from the pane.

#### REQ-009 — Remembered per track in the project

The project shall save, for each track, which lanes are open in the MIDI editor, in order, with each lane's height. Reopening the project shall restore them. An open-lane entry whose lane no longer exists shall be dropped when the project loads.

- **Acceptance:** Godot test: a `Track` round-trips through `to_json` / `from_json` with its open lanes and heights. JSON that names an unknown lane id loads without that entry, and JSON with no list loads with no open lanes.

#### REQ-010 — Lane height

Each lane in the automation pane shall be resizable by dragging. The height shall be clamped to the same range as the value lanes and is the open lane's own, so it is independent of the lane's Arranger height.

- **Acceptance:** Godot test: setting a pane lane's height to 120 leaves `AutomationLane.height` unchanged and stores 120 in the open-lane entry.

### Editing in the MIDI editor

#### REQ-011 — Same editing as the Arranger

An automation lane in the MIDI editor shall support every point gesture of an Arranger lane: double-click to insert, drag to move, Shift to toggle, box and Ctrl range select, tension handles and their reset, Alt-bend, typed values, the point context menu, and the value tooltip. Each gesture behaves and snaps as in the Arranger, using the MIDI editor's grid snap.

- **Acceptance:** Godot test: double-clicking a pane lane at tick 960 adds a point at the snapped tick, as one undo step, holding the lane's own value at that tick. (The other gestures are shared code covered by the Arranger tests.)

#### REQ-012 — Header

Each lane in the automation pane shall show its target's display name, its bypass toggle, and the target's value range as formatted at its extremes. A bypassed or unresolved lane shall look as it does in the Arranger.

- **Acceptance:** Godot test: a lane on `Volume` shows `Volume` in its header, and toggling bypass there sets `lane.bypassed`.

#### REQ-013 — Keyboard shortcuts follow the last press

WHEN the user presses inside an automation lane in the MIDI editor, Delete, Copy, Cut, Paste and Duplicate shall act on that lane's points, as in the Arranger, until the user next presses in the note area or a value lane. The note selection shall be kept either way.

- **Acceptance:** Godot test: with two notes and two points selected, pressing in the lane and then deleting removes the points and keeps the notes. After a press in the note area, delete removes the notes.

#### REQ-014 — One selection scope

Automation point selection in the MIDI editor shall be scoped to one lane at a time, as in the Arranger. Switching the focus track shall clear it.

- **Acceptance:** Godot test: selecting points in lane A and then clicking a point in lane B leaves only B's point selected. Switching focus track clears the selection.

### Selection handles (MIDI editor and Arranger)

#### REQ-015 — Handles over a multi-selection

WHILE two or more points of one automation lane are selected, that lane shall show three selection handles, as the value lanes do: tilt left and tilt right at the top corners of the selected points' bounds, and compress at the lane's bottom right. Hovering a handle shall show a vertical-resize cursor.

- **Acceptance:** Godot test: selecting 1 point shows no handles, selecting 2 shows 3 handles, and their rects lie at the selection's left and right edges.

#### REQ-016 — Tilt

WHEN the user drags a tilt handle vertically, every selected point shall move by the drag's value delta weighted by its tick. The point at the handle's end gets the full delta, the point at the opposite end gets none, and points in between are weighted linearly. Values are clamped to 0.0–1.0, and ticks, curves and tensions are unchanged.

- **Example:** points at ticks 0 / 960 / 1920 with values 0.5 / 0.5 / 0.5, tilt right by +0.2 → 0.5 / 0.6 / 0.7.
- **Acceptance:** unit test on the shared maths with that example.

#### REQ-017 — Compress

WHEN the user drags the compress handle vertically, every selected point's distance from the selection's mean value shall be multiplied by a factor: dragging up expands (factor above 1) and dragging down compresses (factor below 1). Values are clamped to 0.0–1.0.

- **Example:** values 0.2 / 0.8 (mean 0.5), factor 0.5 → 0.35 / 0.65.
- **Acceptance:** unit test on the shared maths with that example.

#### REQ-018 — One undo step, live feedback

A handle drag shall redraw the curve on every motion and show a signed readout (the delta, or the factor in percent) in the value tooltip. On release it shall commit as one undo step, after which the engine holds the final values. Shift shall slow the drag, as for other fine drags.

- **Acceptance:** Godot test: a tilt drag over 3 points followed by one undo restores all 3 values.

#### REQ-019 — Handles yield to points

A press on a point or a tension handle that overlaps a selection handle shall act on the point or tension handle. Selection handles take a press only where nothing else is hit.

- **Acceptance:** Godot test: a press at a selected point's centre starts a point drag even when a selection handle's rect overlaps it.

### Lane presets (MIDI editor and Arranger)

#### REQ-020 — Presets in the lane menu

The MIDI editor's lane menu (REQ-005) and the Arranger's track lane menu shall both have a `Presets` section. It lists every lane preset by name, offers `Save shown lanes as preset…`, and offers `Delete preset ▸` with one entry per preset. Both menus shall list the same presets.

- **Acceptance:** Godot test: after saving `Strings` from the MIDI editor, the Arranger's lane menu for any track lists `Strings`.

#### REQ-021 — Save

WHEN the user chooses `Save shown lanes as preset…` and enters a name, the lane preset store shall save a preset of that name holding the targets of the track's shown lanes, in their shown order. The entry shall be disabled while no lanes are shown. An empty or whitespace-only name shall be refused. IF a preset with that name exists, THEN the user shall be asked to confirm before it is overwritten.

- **Example:** MIDI editor with `CC1 Mod Wheel` and `CC11 Expression` open, saved as `Strings` → preset `Strings` = [`channel/cc/1`, `channel/cc/11`].
- **Acceptance:** Godot test: saving with two lanes shown writes a preset with those two targets in order. An empty name writes nothing. Saving an existing name with confirmation off leaves the old preset in place.

#### REQ-022 — Load: show only the preset's lanes

WHEN the user chooses a preset, the view shall show exactly the preset's lanes on the track, in the preset's order, and hide every other shown lane of that track. Hidden lanes keep their points and their effect on playback. In the MIDI editor this sets the open lanes. In the Arranger it sets each lane's Arranger visibility and expands the track's automation, so the lanes are on screen.

- **Example:** a track with shown lanes `Volume` and `CC1 Mod Wheel`, loading `Strings` → shown lanes `CC1 Mod Wheel`, `CC11 Expression`, and `Volume` is hidden.
- **Acceptance:** Godot test for both views using that example.

#### REQ-023 — Load: create missing lanes

WHEN a loaded preset names a target that has no lane on the track, the view shall create that lane, seeded with the parameter's current value as REQ-006 does. Every lane the load creates exists on the track for both views.

- **Acceptance:** Godot test: loading `Strings` on a track with no lanes creates two lanes (CC1 and CC11), each holding one point at the controller's current value.

#### REQ-024 — Load is one undo step

Loading a preset, including the lanes it creates and the show/hide changes it makes, shall be one undo step. Undo removes the created lanes and restores the shown set as it was before the load.

- **Acceptance:** Godot test: after the REQ-022 example, one undo leaves `Volume` and `CC1 Mod Wheel` shown and no CC11 lane on the track.

#### REQ-025 — Device parameters resolve by device type

A preset entry for a device parameter shall remember the device's type (built-in id or plugin id) as well as its parameter. On load, the entry shall resolve to that parameter on the device at the saved position if that device is the same type there. Otherwise it resolves to the first device of that type in the track's chain, searched depth-first. Channel-level targets (volume, pan, sends, MIDI CC, stage) always resolve.

- **Example:** a preset saved with `Filter / Freq` at chain position 2, loaded on a track whose Filter is at position 0 → a lane on position 0's `Freq`.
- **Acceptance:** Godot test with that example, and with the Filter at the saved position.

#### REQ-026 — Unresolvable entries are skipped and reported

IF a preset entry cannot be resolved on the track (no device of that type, a send index the channel lacks, a parameter that isn't automation-safe), THEN the load shall skip that entry, apply the rest, and tell the user which entries were skipped. A load that resolves nothing changes nothing.

- **Acceptance:** Godot test: loading a preset of [`CC1`, `Filter / Freq`] on a track without a Filter shows only the CC1 lane and reports `Filter / Freq` as skipped.

#### REQ-027 — Delete

WHEN the user chooses a preset under `Delete preset ▸` and confirms, the lane preset store shall remove it. Lanes on any track are unaffected.

- **Acceptance:** Godot test: deleting `Strings` removes it from both menus, and the track's lanes are unchanged.

#### REQ-028 — Presets survive restarts

Lane presets shall persist in the user library across sessions and projects. The store shall be read when a lane menu opens, so a preset saved in one window shows up in the other.

- **Acceptance:** Godot test (scratch directory): a preset saved through one store instance is read back by a new one.

## Non-functional

- **Performance:** the automation pane redraws only on lane changes, scroll, zoom and selection changes, never every frame (the playhead mirror excepted, as in the value lanes). Switching the focus track with 10 open lanes takes no visible pause.
- **Compatibility:** projects saved before this spec open with no lanes open in the MIDI editor. Arranger behaviour other than the new handles is unchanged.

## Out of scope

- Automation in clip mode or on clips (clip-level automation doesn't exist).
- Showing lanes of tracks other than the focus track.
- New automation targets, curve shapes or engine changes.
- Drawing or painting automation with a pencil tool, and the value lanes' Set / Randomize / Scale dialogs for automation (possible follow-ups).
- Moving points in time with the handles (Cubase's horizontal stretch).
- Renaming lane presets, presets that hold points or values, applying a preset to several tracks at once, sharing presets through the browser, and reordering the Arranger's lanes to match a preset (the Arranger keeps its own lane order).

## Open questions

- None. Lane owner, persistence, handles in the Arranger and the shortcut scope were settled with the user before this was written.
