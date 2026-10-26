# Clip Editor Clip Strip — Requirements

## Problem

The clip editor's ruler doubles as a clip display: it shades the bound clip (clip mode) or every clip of the shown tracks (track mode) with track-coloured regions. You can't act on those regions. To move, trim, resize, add or make a clip unique while editing notes in track mode, you have to switch back to the arranger. Nothing in the clip editor or the arranger shows whether a clip is shared by several instances, so an edit that changes every instance comes as a surprise. The clip context menu also has no icons on most of its entries.

## Scope

| | |
|---|---|
| Subsystem | Godot |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no. Clip edits go through the existing `ClipInstance` / `Clip` setters. |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no |

## Requirements

### Ruler

#### REQ-001 — Plain ruler

The clip editor's ruler shall draw no clip regions in either mode. It keeps its bars/beats, start-position arrow, selection band and click gestures.

- **Acceptance:** Godot test: after binding in clip mode and in track mode, the ruler holds no regions.

### Clip strip: shared

#### REQ-002 — Clip strip below the ruler

The clip editor shall show a clip strip, one row high, between the ruler and the note area. Its horizontal coordinates match the ruler's and the note grid's at every scroll and zoom.

- **Acceptance:** live: at any zoom and scroll, a clip's left edge lines up with the ruler's tick and the note grid's line at the clip's start.

#### REQ-003 — Clip appearance

The clip strip shall draw each clip as a bar filled with its effective colour (track colour, or the clip's override), with corners rounded by the theme's corner radius. A selected clip is drawn brighter than an unselected one.

- **Acceptance:** live: change `appearance/theme/corner_radius`, and the strip's bars change radius without a restart.

#### REQ-004 — Shared-clip icon

WHEN a clip shown in the clip strip has more than one instance in the project, the clip strip shall draw a link icon on its bar. WHEN the count drops to one (Make Unique, delete), the icon shall disappear.

- **Acceptance:** Godot test: a clip with two instances reports as shared; after Make Unique on one, neither reports as shared.
- **Example:** clip "Bass" placed at bar 1 and bar 5 → both bars show the link icon. Make Unique on the second → neither shows it.

#### REQ-005 — Context menu

WHEN the user right-clicks a clip in the clip strip, the clip editor shall open the arranger's clip context menu for it, docked to the bar. Every action does what it does in the arranger (rename, loop, mute, cut, copy, split at the click, merge, transpose, scale, legato, split to tracks, make unique, make unique per track, delete), with the same undo steps.

- **Acceptance:** live: each menu entry used from the strip has the same result as the same entry in the arranger.

#### REQ-006 — Snapping and undo

The clip strip's drags shall snap to the clip editor's grid, with Shift for free movement. Each completed gesture shall be one undo step, under the same name the arranger uses for that edit.

- **Acceptance:** Godot test: one move gesture records exactly one history entry; undo restores the start position.

### Clip mode

#### REQ-010 — Bound clip only

WHILE the clip editor is in clip mode, the clip strip shall show only the bound clip instance: its played window, in the clip-content ticks the ruler uses. For a looped instance it shows the loop region, with any part of the first run before the loop start drawn fainter.

- **Acceptance:** Godot test: in clip mode the strip shows one bar from `clip_offset` to `clip_offset + duration_ticks` (unlooped), or from `loop_start_ticks` to `loop_start_ticks + loop_length_ticks` (looped).

#### REQ-011 — Resize the right end

WHILE in clip mode, WHEN the user drags the bar's right end, the clip editor shall:
- for an unlooped instance, change the instance's length and grow the clip's content when the end goes past it, as the arranger's right-edge resize does;
- for a looped instance, change the loop length, as the arranger's loop-divider drag does.

The bar's left end and body shall not be draggable in clip mode.

- **Acceptance:** Godot test: dragging the right end by one bar adds one bar to `duration_ticks` (unlooped) or to `loop_length_ticks` (looped). The instance's `start_ticks` stays put.

#### REQ-012 — Deleting the bound clip

IF the bound instance is deleted from the clip strip's context menu, THEN the clip editor shall stop showing it and behave as it does when the bound clip is deleted in the arranger.

- **Acceptance:** live: Delete from the strip menu in clip mode leaves no stale bar or notes, and no errors are logged.

### Track mode

#### REQ-020 — Focus track's clips

WHILE the clip editor is in track mode, the clip strip shall show every clip instance of the focus track, in song ticks, and no clips of other tracks. WHEN the focus track changes, the strip shall show the new focus track's clips. WHEN no track is focused, the strip is empty and ignores input.

- **Acceptance:** Godot test: switching the focus track from A to B swaps the strip's bars from A's instances to B's.

#### REQ-021 — Clip names

WHILE in track mode, the clip strip shall draw each clip's name on its bar, cut off with an ellipsis when it doesn't fit and left out when the bar is too narrow for any text.

- **Acceptance:** live: renaming a clip from the context menu updates its label on the strip at once.

#### REQ-022 — Move

WHILE in track mode, WHEN the user drags a clip's body, the clip editor shall move the selected clips along the timeline, held back where they would overlap another clip on the track or go before tick 0, as an arranger move along one track is.

- **Acceptance:** Godot test: dragging a clip one bar right adds one bar to its `start_ticks`. A drag towards a neighbouring clip stops at the neighbour.

#### REQ-023 — Trim and resize either end

WHILE in track mode, WHEN the user drags a clip's left or right end, the clip editor shall trim or extend that end with the arranger's edge-resize rules: the left end moves `start_ticks` and `clip_offset` together so the content stays where it is, the right end changes the length, both are held back by neighbouring clips, and the length never drops below one snap step. With several clips selected, the edge resize applies to all of them, as in the arranger.

- **Acceptance:** Godot test: dragging the left end one beat right adds one beat to `start_ticks` and to `clip_offset`, takes one beat off `duration_ticks`, and leaves the song position of every note unchanged.

#### REQ-024 — Create a clip

WHILE in track mode, WHEN the user double-clicks empty strip space, the clip editor shall create a new empty clip on the focus track at the snapped click position, as a double-click on an empty arranger lane does: one bar long, or shorter when the next clip leaves less room.

- **Acceptance:** Godot test: double-click at bar 3 on an empty track creates one instance at bar 3, one bar long, as one undo step.

#### REQ-025 — Double-click on a clip

WHILE in track mode, a double-click on a clip in the clip strip shall do nothing more than a single click.

- **Acceptance:** live: double-clicking a bar selects it and leaves the mode and binding unchanged.

#### REQ-026 — Strip selection

WHILE in track mode, the clip strip shall keep its own clip selection, separate from the arranger's. A click selects one clip, Shift+click adds to the selection, Ctrl/Cmd+click toggles a clip, and a click on empty space clears the selection. A drag on a selected clip moves every selected clip. The context menu acts on the selection when the clicked clip is in it, and on the clicked clip alone otherwise.

- **Acceptance:** Godot test: after Shift+click on two clips, dragging one moves both by the same amount, as one undo step.

#### REQ-028 — Automation follows a move

WHERE the arranger's "automation follows clips" is on, WHEN a clip strip move finishes, the clip editor shall shift the focus track's automation points under the moved clips by the same amount, in the same undo step as the move, as an arranger move does.

- **Acceptance:** Godot test: with "automation follows clips" on and a lane point inside the clip, moving the clip one bar right moves the point one bar right. One undo restores both. With the option off, the point stays put.

#### REQ-027 — Notes follow clip edits

WHEN a clip strip edit changes a focus-track instance (move, trim, resize, create, delete), the note editor shall show the focus track's notes at their new song positions without a rebind by hand.

- **Acceptance:** live: moving a clip in the strip moves its notes in the note area during the drag.

#### REQ-029 — Jump over clips

WHILE in track mode, a move may jump over other clips and land in any gap that fits. Only the landing spot is checked, as in the arranger.

- **Acceptance:** Godot test: a clip dragged past a neighbour lands in the free gap beyond it; a drag that would land on the neighbour stops against it.

#### REQ-040 — Range select

WHILE in track mode, WHEN the user Shift+clicks a clip and the strip has an anchor (the last clip clicked without Shift), the strip shall select every clip of the focus track from the anchor to the clicked clip, whichever comes first.

- **Acceptance:** Godot test: with four clips, click the first and Shift+click the third selects three; the range also works backwards.

#### REQ-041 — Copy, paste, duplicate

WHILE in track mode with the strip focused, Ctrl+C (`edit_copy`) shall copy the selected clips to the arranger's clip clipboard, Ctrl+V (`edit_paste`) shall paste them on the focus track by the arranger's paste rules (refused when the clips would overlap; at the note range start, else a pending ruler range start, else the playhead), and Ctrl+D (`edit_duplicate`) shall copy the selection directly after itself. Duplicate overwrites whatever is in the target span: clips there are removed, trimmed or split, in the same undo step. (The arranger's own duplicate refuses an occupied target and is unchanged.) A paste or duplicate selects the new clips in the strip and leaves the arranger's selection alone.

- **Acceptance:** Godot test: duplicating a clip onto a span holding a clip inside it and one crossing its end leaves only the copy there, as one undo step that restores both.

#### REQ-042 — Ctrl+drag copies

WHILE in track mode, WHEN the user Ctrl/Cmd+drags a clip, the copies shall move and the originals stay; a copy that would land on one of the dragged clips, or before tick 0, is refused. The copies overwrite their target like a duplicate. A Ctrl/Cmd+click without a drag still toggles the clip in the selection.

- **Acceptance:** Godot test: Ctrl+drag by one bar adds a copy there as one undo step and selects it; Ctrl+click without a drag toggles.

### Arranger and menu

#### REQ-030 — Shared-clip icon in the arranger

WHEN an arranger clip's source clip has more than one instance in the project, the arranger shall draw a link icon in that clip's header band, next to the name. The icon follows the same appear/disappear rule as REQ-004.

- **Acceptance:** Godot test: with two instances of one clip on the timeline, both `TimelineClip`s report as shared. After Make Unique, neither does.

#### REQ-031 — Context menu icons

Every action entry in the clip context menu shall have an icon: Merge, Transpose down/up, Scale ½/×2, Make Legato, Merge Same Notes, Split to Tracks, Make Unique, Make Unique Per Track and Mute (Cut, Copy, Split, Loop and Delete already have one). Make Unique and Make Unique Per Track use an icon that reads as breaking a link.

- **Acceptance:** Godot test: every `Button` in the instantiated `ClipContextMenu` has a non-null `icon`.

## Non-functional

- **Performance:** working out the shared state shall not walk every track's instances each time a bar is drawn. It is recomputed only when instances are added, removed or retargeted. Arranger draw time (`TimelineClip._draw` in `PerfRecorder`) is not noticeably higher with 200 clips.
- **Compatibility:** nothing is persisted, and projects load unchanged.

## Out of scope

- Moving clips to other tracks from the strip (vertical drag).
- Loop dividers and Alt+drag-to-loop inside the strip (the arranger keeps them).
- Showing other tracks' clips in the strip.
- Audio clips: the clip editor only binds note clips today, and the strip follows it.
- Inline rename on the strip (the context menu title renames).

## Open questions

- [x] Right end of a looped clip in clip mode → loop length (REQ-011).
- [x] Double-click on a clip in track mode → nothing (REQ-025).
- [x] Selection → the strip's own multi-selection (REQ-026).
- [ ] Should the strip's selection be cleared when the focus track changes? Proposed: yes.
