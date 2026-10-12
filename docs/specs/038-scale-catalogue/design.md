# Scale catalogue — Design

Implements [requirements.md](./requirements.md).

## Context

- `Godot/data/MusicalScale.gd` — `TYPES` (ordered `{id, label, intervals}` dictionaries, "none"
  first), `make`, `is_valid_type`, `intervals_for`, `label_for`, `pitch_classes`, `mask`,
  `display_name` (uses `Midi.NOTE_NAMES[root]`). Type ids are saved in the project file
  (`Project.to_json` `"scale"`) and in key changes (`KeyChangeMap`).
- `Godot/core/Midi.gd` — `NOTE_NAMES` (sharps) and `midi_to_note_name(midi_note)`, used by
  ~20 call sites (sampler, drum pads, note maps, clip editor).
- `Godot/editor/ScalePicker.gd` — two `OptionButton`s; item id = index in `Midi.NOTE_NAMES` /
  `MusicalScale.TYPES`, selection via `select(index)`. Used by the main toolbar and
  `Godot/arranger/ruler/KeyChangeTrack.gd` (key change popup).
- `Godot/clip_editor/ScaleContext.gd` — shared clip editor scale state (`scale`, `changed`
  signal). Handed to `VPiano` (`Godot/components/VPiano.gd`, `scale_context`) and
  `NoteContainer` (`Godot/clip_editor/note_editor/NoteContainer.gd`, `scale_context`) by
  `MidiEditor.gd`.
- `Godot/clip_editor/VisualNote.gd` — note label from `Midi.midi_to_note_name` (line ~191).
- `Godot/components/VPiano.gd` — key labels from `Midi.midi_to_note_name` in `_draw` (line ~345).
- `Engine/src/audio/devices/note_fx/scale.rs` — `SCALE_TYPE_LABELS: [&str; 12]`,
  `SCALE_INTERVALS`, `ROOT_LABELS`, `mask_for(root, type_index)`, `snap`.
- `Engine/src/audio/devices/note_fx/transpose.rs` — param `SCALE_TYPE` (id 12) is
  `Kind::Enum(&SCALE_TYPE_LABELS)`; `set` stores `real as usize`.
- `Engine/src/audio/devices/params.rs` — `enum_to_norm(index, count) = index / (count − 1)`.
  This is why REQ-007 needs a migration: a stored 1.0 means "last entry" whatever the count.
- `Godot/data/Project.gd` — `FORMAT_VERSION := 2`, `from_json` reads `format_version` and builds
  channels (`Channel.from_json`, which builds `DeviceInstance`s, children included) then tracks
  (`Track.from_json`, automation lanes included).
- `Godot/data/DeviceInstance.gd` — `from_json` copies `parameter_values` into both
  `parameter_values` and `_restored_parameter_values`; children under `"children"`.
- `Godot/data/DevicePreset.gd` — `VERSION := 1`, `file_version`, `instantiate()` builds the
  instance from `device` (a `DeviceInstance.to_json()` dictionary).
- `Godot/data/AutomationTarget.gd` — `Kind.DEVICE_PARAM`, `device_path`, `param_id`,
  `resolve(channel)`; `Godot/data/AutomationLane.gd` — `target`, `points` (`AutomationPoint.value`
  normalized).
- `Godot/tests/test_project_scale_sync.gd` — `ENGINE_SCALE_TYPES` hardcoded label list checked
  against `MusicalScale.TYPES` (`_test_labels`).

## Approach

**Catalogue.** `MusicalScale.TYPES` stays the Godot source of truth. Each entry gains a
`"group"` string; the list is reordered into REQ-001's group order with the 35 new entries
inserted. Old ids are unchanged, so nothing keyed by id (project scale, key changes, `ClipTextKey`)
needs migrating. The engine's `SCALE_TYPE_LABELS` / `SCALE_INTERVALS` are extended to the same 47
entries in the same order.

**Sync check.** Instead of a third copy of the list in a Godot test, a `cargo test` in
`scale.rs` reads `../Godot/data/MusicalScale.gd` (via `env!("CARGO_MANIFEST_DIR")`), extracts
each `{"id": …, "label": …, "group": …, "intervals": [...]}` line, skips "none", and asserts the
labels and intervals equal the engine tables entry by entry. `_test_labels` and
`ENGINE_SCALE_TYPES` are removed from the Godot test. Rejected: having the engine send its table
to Godot at runtime — it adds an OSC message and a startup dependency for data that never changes
at runtime.

**Spelling.** `Midi.gd` gets `FLAT_NOTE_NAMES` and an optional `flats` argument on
`midi_to_note_name` (default false, so the ~20 existing callers don't change). `MusicalScale`
gets `uses_flats()` implementing REQ-005 (count repeated letters in each spelling of
`pitch_classes()`, tie → reference major rule), `note_name(pitch)` and `root_name()`;
`display_name()` uses `root_name()`. `ScaleContext` gets `spell_flats() -> bool`
(`highlight_active() and scale.uses_flats()`). `VPiano._draw` and `VisualNote`'s label use it.
`VisualNote` doesn't hold the context; `NoteContainer` pushes a `spell_flats` bool to each
VisualNote when it creates one and when `scale_context.changed` fires.

**Grouped picker.** `ScalePicker` adds `_type_option.add_separator(group)` before each group's
first entry. Separators take item indices, so items get `id = catalogue index` and lookups switch
from `select(i)` / `selected` to `get_item_index(id)` / `get_selected_id()`. Root items keep ids
0–11 with labels from a new `MusicalScale.ROOT_LABELS` (`"C#/Db"` …).

**Migration (REQ-007).** The old normalized value is ambiguous without knowing the old count, so
it's keyed on file versions: `Project.FORMAT_VERSION` 2 → 3 and `DevicePreset.VERSION` 1 → 2.
A static helper `MusicalScale.migrate_v1_type_norm(norm) -> float` maps
`round(norm × 11)` → old id (the 12 old ids, in old order, kept as `LEGACY_TYPE_IDS`) → new index
→ `enum_to_norm` with the new count (`TYPES.size() − 2`, i.e. 46 as the divisor). One walker,
`DeviceInstance.migrate_scale_catalogue(data: Dictionary)`, rewrites `parameter_values["12"]` of
every `"sonara.builtin.transpose"` entry in a device JSON tree (recursing into `"children"`). It
runs on the raw JSON:
- `Project.from_json`, when `format_version < 3`, on every `channels[*].devices[*]` before
  `Channel.from_json`; then, after tracks are built, on automation: for each track lane whose
  target is `DEVICE_PARAM` with `param_id == 12` and whose `resolve(channel)` is a transpose
  instance, every point value is mapped through `migrate_v1_type_norm`.
- `DevicePreset.instantiate`, when `file_version < 2`, on its duplicated `data` (and the
  returns' channel devices).

Rejected: storing Scale Type by id in the engine parameter. Parameters are normalized floats
end to end (OSC, automation, presets); an id-keyed exception would touch every one of those paths
for one parameter. Future catalogue growth would append another versioned step to the migration.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `SCALE_TYPE_LABELS`, `SCALE_INTERVALS` | static, read-only | Transpose `set`/`process` on the audio callback, param info on the command thread | yes, unchanged access pattern (static slices, no allocation) |

All other changes are Godot main thread.

## Data and protocol changes

- No OSC change. `/project/scale` and key change masks are computed from intervals as before.
  The Transpose Scale Type enum is advertised with 47 labels through the existing parameter info.
- `.sonara`: `format_version` 3. Content shape unchanged; only Transpose param 12 values (and
  automation of it) are rewritten on load from version ≤ 2.
- Device preset: `version` 2, same shape.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/data/MusicalScale.gd` | 47-entry `TYPES` with `"group"`; `GROUPS` order; `ROOT_LABELS`; `LEGACY_TYPE_IDS`; `uses_flats()`, `note_name()`, `root_name()`, `group_for()`; `display_name()` spelled; `migrate_v1_type_norm()` |
| `Godot/core/Midi.gd` | `FLAT_NOTE_NAMES`; `midi_to_note_name(midi_note, flats := false)` |
| `Godot/editor/ScalePicker.gd` | group separators, id-based selection, `ROOT_LABELS` |
| `Godot/clip_editor/ScaleContext.gd` | `spell_flats()` |
| `Godot/components/VPiano.gd` | key labels use `scale_context.spell_flats()` |
| `Godot/clip_editor/VisualNote.gd` | `spell_flats` var; label uses it |
| `Godot/clip_editor/note_editor/NoteContainer.gd` | set `spell_flats` on created notes and on `scale_context.changed` |
| `Godot/data/DeviceInstance.gd` | static `migrate_scale_catalogue(data)` |
| `Godot/data/Project.gd` | `FORMAT_VERSION := 3`; migration calls in `from_json` (devices before build, automation after tracks) |
| `Godot/data/DevicePreset.gd` | `VERSION := 2`; migration call in `instantiate` |
| `Engine/src/audio/devices/note_fx/scale.rs` | 47-entry tables; sync test reading `MusicalScale.gd`; mask tests for a few new scales |
| `Engine/src/audio/devices/note_fx/transpose.rs` | no code change expected (takes `&SCALE_TYPE_LABELS`); its tests adjusted if they hardcode normalized Scale Type values |
| `Godot/tests/test_project_scale_sync.gd` | drop `ENGINE_SCALE_TYPES` / `_test_labels` (covered by the cargo sync test) |
| `Godot/tests/test_note_values_persistence.gd` | expect `format_version` 3 |
| `Godot/tests/test_scale_catalogue.gd` (new) | REQ-001, 003, 004, 005, 006, 007 |
| `docs/specs/026-scale-support/design.md` | one-line pointer: catalogue extended by spec 038 |

## Migration and compatibility

- Projects with `format_version` 1 or 2 and presets with `version` 1: Transpose Scale Type values
  and their automation points are remapped once on load; the next save writes the new versions.
- Project scale and key changes: ids unchanged, no migration.
- Opening a new file in an older build: unknown project scale ids load as "No scale"
  (`MusicalScale.make`), unknown key changes are dropped (`KeyChangeMap.from_json`), Transpose
  values map to a wrong old entry. Accepted per requirements.

## Test plan

- **Unit:** `cargo test scale` — `catalogue_matches_godot` (REQ-002) and masks for Lydian
  Dominant, Whole Tone and Hirajoshi; `cargo test transpose` stays green.
- **Godot:** `godot --headless --path Godot -s tests/test_scale_catalogue.gd -- --test`:
  - every REQ-001 row and old ids (REQ-001)
  - picker headings, non-selectable, `set_scale_display` round-trip on a scale after a separator (REQ-003)
  - root labels (REQ-004)
  - all REQ-005 examples
  - `Midi.midi_to_note_name(70, true) == "Bb3"` and `ScaleContext.spell_flats()` for F Major vs none (REQ-006)
  - a version-2 project dict and a version-1 preset dict with Transpose Scale Type 1.0 and 4/11, plus a lane automating param 12, load as Blues / Dorian (REQ-007)
- **Godot regression:** `Godot/tests/run_all.sh scale key_change note_values` (REQ-008).
- **Live:** pick "Eb Dorian" in the toolbar picker; piano roll shows Eb/Bb labels and highlights;
  Transpose set to Follow Project snaps to the scale; Transpose Custom + "Hirajoshi" snaps
  correctly; an old project with Transpose on Blues still shows Blues.

## Risks

| Risk | Mitigation |
|---|---|
| A Transpose test or a saved fixture hardcodes `k/11` normalized values | grep tests for Scale Type values; adjust in the same task as the table change |
| The cargo sync test's line parser is fragile | keep one entry per line in `TYPES` (comment says so); the test fails loudly, never silently passes on zero entries |
| `OptionButton` separators shift indices and break `KeyChangeTrack` | `ScalePicker`'s public API (`scale_picked`, `set_scale_display`, `display_text`) stays id-based; covered by the picker round-trip test |
| A 46-entry flat Transpose dropdown is long | accepted (out of scope); order follows the groups |

## Open questions

- none
