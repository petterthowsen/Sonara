# TODO-ranked

UI/UX tasks from `TODO.md`, ranked by code category and difficulty.

Scope: "included" = tasks whose work lands in the Godot UI surface. Excluded (engine-internal,
not UI/UX): plugin subfolder scanning, audio-thread items, built-in device DSP, send curve, solo
routing, MIDI-in-engine. Items marked **UI+engine** have a UI half but need engine work.

Effort scale: **XS** <2 h · **S** ≤1 d · **M** 2–4 d · **L** 1–2 w · **XL** open-ended.

## XS — localized, single file

| Task | Category / file | Status |
|---|---|---|
| NoteEditor: modifier+right-click opens context menu | `clip_editor/note_editor/NoteEditor.gd` | deferred |
| Settings: scroll-zoom sensitivity Slow/Normal/Fast | `settings/Settings.gd` + zoom consumers | deferred |

Shipped (see `TODO.md` for the implementation notes):

- TrackItem context menu: Delete moved below the duplicate actions.
- Tracklist context menu: bare "New Track" removed.
- Ctrl+A selects all notes (clip mode: the clip; track mode: the active track).
- Ctrl+A clips on the active track; Ctrl+double-A within 400 ms selects all tracks.
- Bug: the blue selection-range line no longer paints outside the note area
  (`MidiEditorOverlays` clips its drawing; the marker X math was verified against the
  projected note position).
- Mixer split offset across strips — confirmed implemented (`_shared_vsplit_offset`,
  `_on_vsplit_dragged`, `_apply_shared_vsplit_offset`); stale `TODO.md` line deleted.

## S — self-contained feature, existing patterns

| Task | Category / file |
|---|---|
| Instance count badge on `TimelineClip` header | `arranger/timeline/clip/TimelineClip.gd` (depends on M item below) |
| "Select All Instances" / "Select Tracks" in clip menu | `timeline/ClipContextMenu.gd`, `ClipSelectionManager.gd` |
| Master track accepts device drops (lane + compact list) | `devices/device_lane/DeviceLane.gd`, `DeviceDropTarget.gd`, `data/Channel.gd` (master = id 1) |
| Note lane: hover color + MIDI/live input depresses keys | `note_editor/NoteEditor.gd`, `midi/MidiManager.gd` |
| Tracklist multi-track create popup (alternative to removal) | `tracklist/TrackListContextMenu.gd` |
| Move asset settings → top-level Assets category + CLAP search paths | `settings/Settings.gd`, `browser/AssetPaths.gd` |
| Fuzzy settings search bar | `settings/Settings.gd` (reuse `browser/AssetSearch.gd`) |
| Browser tree icons (audio/midi/device, lucide) | `browser/Browser.gd` (29.8 KB), `assets/icons/` |
| AI assistant personality presets | `settings/Settings.gd`, `ai/prompt/` |

## M — data-model change or multi-file interaction logic

| Task | Category / file |
|---|---|
| Instance count as observable state (signal on add/remove/move/unique) | `data/Project.gd` (62.9 KB), `data/Track.gd`, `history/` |
| Rename clips that lose their last instance (+undo, collision) | `data/Clip.gd`, `history/commands/ClipInstanceDeleteCommand` |
| Move note-ID ownership from `NoteContainer` to `Clip` | `note_editor/NoteContainer.gd` (28.4 KB), `data/Clip.gd` |
| Ctrl+drag on VisualNote → drag-to-duplicate | `clip_editor/VisualNote.gd`, `NoteEditor.gd` |
| Double-click clip → MIDI editor scrolled to clip/pitch | `timeline/clip/TimelineClip.gd`, `ClipEditor.gd`, `MidiEditor.gd` (40.9 KB) |
| Header vs body click differentiation + paint-delete (Behavior settings) | `TimelineClip.gd`, `timeline/ClipContextMenu.gd`, settings |
| Simple View edit mode pt.2 (T-015: context menu, add parameter) | `devices/simple_view/SimpleControl.gd` (11.5 KB), `SimpleLayout.gd` |
| Per-device volume control | `data/DeviceInstance.gd` (36.6 KB), `devices/device_lane/DevicePanel.gd`, engine param |
| Device lane animated signal icon (audio/MIDI) | `DeviceLane.gd`, `DevicePanel.gd`, `DeviceView` streams |
| Each asset path as its own top-level tree folder | `browser/Browser.gd`, `FileSystemAssetProvider.gd` |
| Track mode: notes from all clips visible | `note_editor/NoteEditor.gd`, `MidiEditor.gd` |
| AI conversation compaction + settings | `ai/Assistant.gd`, `ai/prompt/`, settings |
| Track user edits and summarize into next message | `history/`, `data/` diffing, `ai/prompt/` |

## L — new subsystem or cross-cutting UI

| Task | Category / file |
|---|---|
| Export MIDI (**UI+engine**) | engine + export UI |
| Export menu with stem selection (**UI+engine**) | engine + export UI |
| Export/render: bounce clip/track, bounce in-place (**UI+engine**) | engine + UI |
| Welcome screen (recent projects, templates) | new scene, `Sonara.gd` config, `editor/MainMenu.gd` |
| AI question tool + element highlight/scroll/select | `ai/tools/`, `ai/ui/ChatComposer.gd`, `Editor` selection |
| Data-driven settings registry + generated UI (2 sub-items) | `settings/Settings.gd` (18.8 KB), `SettingRow.gd` (12.2 KB), `SettingsDialog.gd`; `tests/test_settings_registry.gd` exists |
| Simple View edit mode pt.1 (T-014, new `SimpleEditOverlay.gd`) | `devices/simple_view/` (SimpleLayout, SimpleLayoutStore, SimpleControl) |
| Track vs clip context mode (4 bullets: ruler, order, overlays) | `note_editor/NoteEditor.gd`, `MidiEditor.gd`, ruler |
| Unify arranger/note-editor ruler | `arranger/ruler/` (`MarkerTrack.gd` 15.7 KB precedent) + note editor |
| Chord track with visual notation | `arranger/ruler/` + new data model + history |
| Modulation Phase 1: automation lanes (spec 003) | `data/AutomationLane.gd`, `timeline/AutomationLaneRow.gd` (18.6 KB), `arranger/AutomationRowOrder.gd` |
| Asset Browser split: tree top / details bottom + waveform preview | `browser/Browser.gd`, `support/waveform/`, engine preview route |

## XL — investigation, no fixed endpoint

| Task | Category / file |
|---|---|
| Waveform generation/drawing profiling on long clips | `AudioFileService` (waveform caches), `support/waveform/` |
| Frontend architecture audit (style/best-practice deviations) | whole `Godot/` tree |

## Verification-only backlog (`[x?]`, UI)

Cheap; no new design — each is a live UI check. Batch into one session rather than ranking
individually: clip resize snapping, clip Cut/Copy, Make Unique disabled state, SmartLineEdit
blur-commit, note maps/drum view, `TrackItem` height sync (narrow/widen), Ctrl+scroll vertical
zoom feel, Simple View panel integration (T-013), device rename, device drag-reorder, crash popup.

## Notes / risks

- Dependency edge: instance-count badge (S) and "Select All Instances" (S) are gated on
  instance-count observable state (M) — do the M item first.
- Dual-nature: export/bounce/stem items are ranked L for the UI half alone; engine work dominates
  their real cost.
- Difficulty for Simple View items assumes the spec `docs/specs/004-simple-view/`
  (T-014/T-015) is the plan of record.