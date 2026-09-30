# DAWproject Import and Export (core) — Tasks

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Test commands below are shortened: `T <script>` means
`godot --headless --path Godot -s tests/<script> -- --test`.

## Phase 1 — foundations

- [x] **T-001** [REQ-003, REQ-026] Add the fixtures and schemas.
  - _Files_: `Godot/tests/fixtures/dawproject/sonara_test_01.dawproject`,
    `Godot/tests/fixtures/dawproject/Project.xsd`, `Godot/tests/fixtures/dawproject/MetaData.xsd`
  - _Output_: Bitwig fixture copied from `~/Bitwig Studio/Projects/`; both XSDs extracted verbatim
    from the appendices of `docs/dawproject/specification.md`.
  - _Verify_: `xmllint --noout --schema Project.xsd` on the fixture's own `project.xml` passes
    (needs `libxml2-utils`; if Bitwig's file fails, note why in `STATUS.md`)
  - _Depends on_: —

- [x] **T-002** [REQ-008] XML DOM and writer.
  - _Files_: `Godot/dawproject/DawXml.gd`, `Godot/tests/test_dawproject_units.gd`
  - _Output_: `DawXml.parse(buffer)` → `Node` tree or error with line; `DawXml.Writer` with
    escaping (`& < > "`), indentation and number formatting.
  - _Verify_: `T test_dawproject_units.gd` — parses the fixture's `project.xml` (root `Project`,
    4 `Track`s under `Structure`); malformed XML reports an error; writer output re-parses to
    the same tree, including escaped names like `A & "B"`.
  - _Depends on_: T-001

- [x] **T-003** [REQ-014, REQ-015, REQ-016, REQ-019] Unit conversions and resampling.
  - _Files_: `Godot/dawproject/DawUnits.gd`, `Godot/tests/test_dawproject_units.gd`
  - _Output_: dB ↔ linear, pan, velocity, ticks ↔ beats, param normalized ↔ real,
    `resample(...)`.
  - _Verify_: `T test_dawproject_units.gd` — −6 dB ↔ 0.501187; linear 0 → −60 dB; +20 dB
    clamps to +12; pan −0.5 ↔ 0.25; velocity 100 ↔ 0.787402 ↔ 100; a tension 0.7 segment
    resampled stays within 1% at 100 samples; a straight linear segment through a linear map
    emits no extra points; a −60 → 0 dB linear ramp resampled to gain stays within 1%.
  - _Depends on_: —

- [x] **T-004** [REQ-021] `.clap-preset` wrap/unwrap.
  - _Files_: `Godot/dawproject/ClapPreset.gd`, `Godot/tests/test_dawproject_units.gd`
  - _Output_: `wrap(clap_id, state)`, `unwrap(bytes)`.
  - _Verify_: `T test_dawproject_units.gd` — unwrap of the fixture's preset gives
    `nakst.Apricot` and 16 133 state bytes; `wrap` of that result is byte-identical to the file;
    a file without the `clap` magic returns an error.
  - _Depends on_: T-001

- [x] **T-005** [REQ-023, REQ-024] Transfer report.
  - _Files_: `Godot/dawproject/TransferReport.gd`, `Godot/tests/test_dawproject_units.gd`
  - _Output_: kind constants for every REQ-023/024 item; aggregation by `(kind, subject)` with
    counts; `to_text()`.
  - _Verify_: `T test_dawproject_units.gd` — 212 adds of one kind on one track give one entry
    reading like *"Lead: 212 notes on MIDI channel 2 moved to channel 0"*.
  - _Depends on_: —

- [x] **T-006** [REQ-022] SFZ file collection.
  - _Files_: `Godot/dawproject/SfzFiles.gd`, `Godot/tests/test_dawproject_units.gd`
  - _Output_: `collect(sfz_path)` → referenced files and missing files.
  - _Verify_: `T test_dawproject_units.gd` — an SFZ written to `user://` with `default_path`, an
    `#include`, a `sample=` with spaces in the name, and one missing sample yields the right
    lists.
  - _Depends on_: —

## Phase 2 — export

- [x] **T-007** [REQ-002, REQ-004, REQ-005, REQ-010, REQ-013, REQ-014, REQ-015] Export skeleton:
  container, transport, structure, channels, routing, sends.
  - _Files_: `Godot/dawproject/DawProjectExporter.gd`, `Godot/tests/test_dawproject_export.gd`
  - _Output_: `export_project(project, path)` writing `project.xml` + `metadata.xml` through
    `<path>.partial`; id pre-pass; tracks (nested folders/groups), channels, master, bus tracks
    with `effect`/`submix`, `destination`, sends; hardware outputs → master (report).
  - _Verify_: `T test_dawproject_export.gd` — both entries present; `Title` = project name;
    folder → group → 2 tracks nest in XML; a send-only bus is `effect`, a routed bus `submix`;
    `project.to_json()` and `is_modified` unchanged; export to an unwritable dir returns an error
    and leaves no file.
  - _Depends on_: T-002, T-003, T-005

- [x] **T-008** [REQ-016, REQ-017, REQ-018, REQ-020] Export clips, notes, audio and markers.
  - _Files_: `Godot/dawproject/DawProjectExporter.gd`, `Godot/tests/test_dawproject_export.gd`
  - _Output_: per-track `Lanes` with `Clips`; MIDI `Notes`; pooled clips as `id` + `reference`;
    audio `Warps` + `Audio` with the file embedded once under `audio/`; transpose/gain offset
    handled and reported; `Markers`.
  - _Verify_: `T test_dawproject_export.gd` — three instances of one clip → one `Notes id` and
    two `reference`s; a transposed instance writes inline notes and one report entry; one WAV used
    by two clips is in the ZIP once; a 120 BPM clip's warps are `(0,0)` and `(B, B × 0.5)`;
    marker with a duration → report entry.
  - _Depends on_: T-007

- [x] **T-009** [REQ-011, REQ-012, REQ-019] Export tempo, signature and track automation.
  - _Files_: `Godot/dawproject/DawProjectExporter.gd`, `Godot/tests/test_dawproject_export.gd`
  - _Output_: `TempoAutomation`, `TimeSignatureAutomation` (beat position of each bar), `Points`
    per lane targeting the channel/send/device parameter ids, resampled through `DawUnits`.
  - _Verify_: `T test_dawproject_export.gd` — 3-point tempo map → 3 `RealPoint`s at the right
    beats; 7/8 at bar 5 in 4/4 → point at beat 16; volume lane targets the channel's `Volume`
    id with linear-gain values; a STEP point → `hold`.
  - _Depends on_: T-008

- [x] **T-010** [REQ-021, REQ-022, REQ-024] Export devices.
  - _Files_: `Godot/dawproject/DawProjectExporter.gd`, `Godot/tests/test_dawproject_export.gd`
  - _Output_: `ClapPlugin` with `.clap-preset` state and `Parameters` for automated params;
    `BuiltinDevice sonara.<id>` with JSON state, rewritten `loaded_file_path`s and embedded
    files (SFZ via `SfzFiles`); roles; `refresh_plugin_states` awaited first; plugins without
    state reported.
  - _Verify_: `T test_dawproject_export.gd` — a fake CLAP device with a state blob → preset
    entry that unwraps to the same bytes; polysynth → delay chain → two `BuiltinDevice`s whose
    JSON re-parses; a sampler pad's WAV is embedded under `files/` and the JSON points at it.
  - _Depends on_: T-004, T-006, T-009

- [x] **T-011** [REQ-003] Schema check script.
  - _Files_: `Godot/tests/validate_dawproject.sh`, `Godot/tests/test_dawproject_export.gd`
  - _Output_: the export test leaves its outputs in `user://dawproject_export/`; the script runs
    that test, then `xmllint --noout --schema` over every exported file, failing when `xmllint`
    is missing.
  - _Verify_: `Godot/tests/validate_dawproject.sh` exits 0.
  - _Depends on_: T-010

## Phase 3 — import

- [x] **T-012** [REQ-007, REQ-008, REQ-010, REQ-011, REQ-012, REQ-013, REQ-014] Import skeleton:
  container, errors, transport, maps, structure.
  - _Files_: `Godot/dawproject/DawProjectImporter.gd`, `Godot/tests/test_dawproject_import.gd`
  - _Output_: `import_file(path, audio_dir)` → `{ok, error, project_json, report,
    audio_dir_failed}`; id map with forward refs; tempo map (same-time points and `hold`), time
    signature map (off-bar → next bar + report); tracks, folders/groups, master, effect/submix
    tracks → buses; channel volume/pan/mute/solo.
  - _Verify_: `T test_dawproject_import.gd` — Bitwig fixture: `Project.from_json` of the result
    has 2 tracks + *Reverb* bus + master, Apricot at −6.02 dB, tempo 110 at tick 3839 and 79.02
    at tick 3840, name = file name (empty `Title`). Not-a-ZIP, missing `project.xml`, bad XML,
    dangling IDREF each return `ok = false` with a message.
  - _Depends on_: T-002, T-003, T-005

- [x] **T-013** [REQ-015, REQ-021, REQ-022, REQ-023] Import routing, sends and devices.
  - _Files_: `Godot/dawproject/DawProjectImporter.gd`, `Godot/tests/test_dawproject_import.gd`
  - _Output_: `destination` → `output_channel_id`; sends (skipping default and self sends);
    `ClapPlugin` → device JSON with base64 `plugin_state` when `AssetService.get_device` knows the
    id, otherwise report; `BuiltinDevice sonara.*` → embedded JSON with extracted files; other
    devices → report.
  - _Verify_: `T test_dawproject_import.gd` — Apricot (fake-registered) has one send to *Reverb*
    at −22.85 dB, other channels none; Apricot's `plugin_state` equals the preset's state bytes;
    exactly one report entry (*Reverb* BuiltinDevice); with Apricot unregistered, a
    missing-plugin entry instead.
  - _Depends on_: T-004, T-012

- [x] **T-014** [REQ-009, REQ-016, REQ-017, REQ-018, REQ-020] Import clips, audio and markers.
  - _Files_: `Godot/dawproject/DawProjectImporter.gd`, `Godot/tests/test_dawproject_import.gd`
  - _Output_: arrangement walk with scopes; nested clip flattening; `Notes` → MIDI clips;
    `Warps`/bare `Audio` → audio clips with `recorded_bpm`; `reference` → pooled clips; audio
    extraction to `<name> Audio/` (or `audio_dir`), `audio_dir_failed` when not writable;
    external paths; markers.
  - _Verify_: `T test_dawproject_import.gd` (fixture copied to a temp dir first) — two MIDI
    clips of 4 notes at ticks 0 and 3840, velocity 100; crash at tick 3840, duration 1760 ticks,
    `recorded_bpm` 110; WAV extracted to `<tmp>/sonara_test_01 Audio/audio/…` and referenced; an
    unwritable dir sets `audio_dir_failed`; a synthetic file with two `reference`s to one
    `Notes` gives one pooled clip.
  - _Depends on_: T-013

- [x] **T-015** [REQ-019, REQ-023] Import automation and the remaining report items.
  - _Files_: `Godot/dawproject/DawProjectImporter.gd`, `Godot/tests/test_dawproject_import.gd`
  - _Output_: `Points` → lanes for volume/pan/send/device params (resampled); every REQ-023 item
    detected and reported; `rel` only when ≠ `vel`; empty scenes ignored.
  - _Verify_: `T test_dawproject_import.gd` — fixture: Apricot send lane 0 → 0 dB over ticks
    0–7680, crash volume lane −6.02 dB → −60 dB over ticks 3840–7680; a synthetic file holding
    one of each REQ-023 item gives one entry per item and still imports the rest.
  - _Depends on_: T-014

## Phase 4 — UI and round trip

- [x] **T-016** [REQ-001, REQ-006, REQ-007, REQ-009, REQ-023, REQ-024] Menu, editor entry points
  and report dialog.
  - _Files_: `Godot/editor/MainMenu.gd`, `Godot/editor/Editor.gd`,
    `Godot/dawproject/TransferReportDialog.gd`, `Godot/tests/test_dawproject_import.gd`
  - _Output_: *Import DAWproject…* / *Export DAWproject…* items; dialog modes; extension
    appended; `Editor.import_dawproject` / `export_dawproject`; folder picker retry on
    `audio_dir_failed`; report and error dialogs.
  - _Verify_: `T test_dawproject_import.gd` — `Editor.import_dawproject` on the fixture opens a
    project with `project_path == ""`; on a broken file the previous project stays open and
    unchanged. `Godot/tests/run_all.sh` passes.
  - _Depends on_: T-011, T-015

- [x] **T-017** [REQ-025] Round-trip test.
  - _Files_: `Godot/tests/test_dawproject_roundtrip.gd`
  - _Output_: one project using every core-subset feature (folder/group nesting, bus + send,
    routing, pooled + transposed clips, audio clip at 120 BPM in a 100 BPM project, all lane
    kinds with a curved and a step point, markers, tempo ramp, signature change, CLAP with state,
    polysynth → delay, drum machine with sampler pads), exported, imported, compared.
  - _Verify_: `T test_dawproject_roundtrip.gd` passes with the REQ-014…022 tolerances.
  - _Depends on_: T-016

## Phase 5 — docs

- [x] **T-018** [REQ-all] Documentation and tracking.
  - _Files_: `docs/subsystems/dawproject.md`, `AGENTS.md`, `docs/dawproject/sonara-gaps.md`,
    `TODO.md`, `STATUS.md`
  - _Output_: subsystem doc (code map, mapping tables, report kinds, the `sonara.` BuiltinDevice
    convention); AGENTS table row; core gap items ticked; TODO entry updated; STATUS notes.
  - _Verify_: every file in the design's change list is mentioned in `dawproject.md`; no OSC
    doc change needed (none added).
  - _Depends on_: T-017

## Phase 6 — live verification

- [ ] **T-019** [REQ-021, REQ-026] Live check with the engine and Bitwig.
  - _Files_: —
  - _Output_: `TODO.md` entry `[x]`; `STATUS.md` records what was and wasn't checked.
  - _Verify_:
    1. Engine + Godot running. *Import DAWproject…* → `sonara_test_01.dawproject`. The report
       lists only *Reverb*. Play: Apricot plays *Elder's Wisdom*, the crash hits at bar 2, the
       reverb send ramps up over two bars, the tempo drops at bar 2, the crash fades out.
    2. In Sonara build Apricot + a patch, an audio loop, a bus with a send, volume automation and
       a tempo change. *Export DAWproject…*, open in Bitwig: tracks, clips, notes, audio position
       and length, send, automation, tempo change and the Apricot patch match.
    3. Save the imported project as `.sonara`, reopen: identical.
    4. Export a 50-track project and time it (non-functional budget).
  - _Depends on_: T-018
