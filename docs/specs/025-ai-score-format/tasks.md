# 025: AI score format and section tools — Tasks

Status: draft, awaiting approval.

Implements [design.md](./design.md).

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Test commands (from `AGENTS.md`):
- text layer: `godot --headless --path Godot -s ai/tests/test_score_text.gd -- --test`
- tools: `godot --headless --path Godot -s ai/tests/test_section_tools.gd -- --test`

## Phase 1 — text layer (no project)

- [x] **T-001** [REQ-003, REQ-004] Bar plan and duration splitting in `ScoreText`.
  - _Files_: `Godot/ai/clip_text/ScoreText.gd` (new), `Godot/ai/tests/test_score_text.gd` (new)
  - _Output_: the bar plan type (`[{start, length, numerator, denominator}]` in section-local
    ticks), the value table (whole to 1/32, each straight, dotted or triplet), and
    `split_span(start, length, plan)`, which gives tokens cut at barlines and aligned to their own
    grid. `SNAP_TICKS = 20`.
  - _Verify_: test_score_text passes. A 4/4 + 7/8 plan has bar lengths 3840 and 3360. A gap of
    1.1.240–1.3.000 in 7/8 splits as `/8.`, and no dotted quarter starts on an off-beat 16th. A 1.5-bar note in 4/4 splits into a
    tie across the barline.
  - _Depends on_: —

- [x] **T-002** [REQ-012, REQ-013, REQ-014, REQ-019] `ScoreText.parse` for note lines.
  - _Files_: `Godot/ai/clip_text/ScoreText.gd`, `Godot/ai/tests/test_score_text.gd`
  - _Output_: parsing of labels (with `.N` voices, and continuation across systems), notes, chords,
    rests, `~` ties (across barlines), `@vel`, sticky duration and velocity per line (default 100,
    and an error when the first token has no duration), and `# …` comments. A `section bars N-M`
    header is read. Errors name the track, bar, token and expected form. Bar-sum errors give the
    musical value and ticks. Line bar-count errors give both counts.
  - _Verify_: test_score_text passes. `Bass: D1/4 D1 D1 D1 |` in 7/8 gives
    `Bass bar 1 adds up to 4/4 (3840 ticks); a 7/8 bar is 3360 ticks`. `A3/4~ | A3/2` gives one
    note of 2880 ticks. `A3/4~ | B3/2` is an error. `X9/8` is an error naming the token. `D13/8`
    is an error showing the `<pitch>/<value>` form.
  - _Depends on_: T-001

- [x] **T-003** [REQ-003, REQ-005, REQ-007] `ScoreText.serialize` for note lines.
  - _Files_: `Godot/ai/clip_text/ScoreText.gd`, `Godot/ai/tests/test_score_text.gd`
  - _Output_: snapping to the 1/32 straight or triplet grid within `SNAP_TICKS`, and an
    `off_grid` result for a track that can't be snapped. Chords (same onset and length), voice
    split, rests, ties at barlines, velocity shown only when it changes, key-aware spelling,
    systems of 4 bars with `# bars N-M` comments, and the `section …` header with its meters.
  - _Verify_: test_score_text passes. Serialize → parse returns the same notes for a set of 4/4,
    7/8 and mixed-meter fixtures. A sustained C3 under a moving line gives `.1` and `.2` voices. A
    note 30 ticks off gives `off_grid`. A note 8 ticks off snaps.
  - _Depends on_: T-002

- [x] **T-004** [REQ-006, REQ-015] Keyswitch tokens in the text layer, and a shared name lookup.
  - _Files_: `Godot/ai/clip_text/ScoreText.gd`, `Godot/ai/tools/SfzKeyInfoUtil.gd`,
    `Godot/ai/tests/test_score_text.gd`
  - _Output_: `ks:<name>` and `ks:"<name>"` parsed against a per-track `{norm_name: key}` map
    (normalized for case, `_` and spaces). An unknown name is an error listing the available names.
    Serialize emits `ks:` before the next token. `SfzKeyInfoUtil.switch_name` is public, and a new
    `keyswitch_map(inst)` returns the map. Existing callers are unchanged.
  - _Verify_: test_score_text passes (`ks:sus alt` resolves to the `Sus_Alt` key, and `ks:Palm` is
    an error listing the names). `Godot/tests/run_all.sh sfz device_tools` still passes.
  - _Depends on_: T-003

## Phase 2 — project layer

- [ ] **T-005** [REQ-001, REQ-004] `ScoreSection.bar_plan` and `gather`.
  - _Files_: `Godot/ai/clip_text/ScoreSection.gd` (new), `Godot/ai/tests/test_section_tools.gd` (new)
  - _Output_: a bar plan for song bars N–M from `TimeSignatureMap.segments`. `gather(project,
    track, s, e)` returns section notes from overlapping placements using `clip_to_song_ticks`,
    `first_run_range` and `transpose`, each with `{note_ref, clip, instance}`, plus a flag for a
    placement that loops inside the span.
  - _Verify_: test_section_tools passes. A trimmed placement (`clip_offset` > 0) and a transposed
    one (+12) gather the right song positions and pitches. A signature map with 7/8 from bar 2
    gives bar 2 = 3360 ticks.
  - _Depends on_: T-001

- [ ] **T-006** [REQ-010, REQ-011, REQ-017, REQ-021] `ScoreSection.write`: diff, clip ownership,
  clip creation.
  - _Files_: `Godot/ai/clip_text/ScoreSection.gd`, `Godot/ai/tests/test_section_tools.gd`
  - _Output_: matching by pitch, onset and length within `SNAP_TICKS`, where a matched note is left
    untouched and a different written velocity changes only the velocity. Unmatched notes are
    removed or added. A written note goes to the placement under its onset, and a note running past
    its placement's end is shortened with a warning. Uncovered bar runs that get notes get a new
    clip named `<Marker> <Track>` or `<Track> N-M` via `unique_clip_name`. Notes outside the
    playable range produce warnings. The result is `{cmds, summary, warnings}`, with structural
    commands already run.
  - _Verify_: test_section_tools passes. Writing bars 2–3 leaves bars 1 and 4 alone. Writing a read
    back unchanged gives zero changes, and a note 8 ticks late keeps its offset. A `Verse` marker
    gives clip `Verse Bass`. Without a marker the clip is `Bass 1-8`. `G-1` as a note on an SFZ
    playable from F#0 gives a warning.
  - _Depends on_: T-005, T-003

- [ ] **T-007** [REQ-018] Shared-clip detection with the `unique` and `all` options.
  - _Files_: `Godot/ai/clip_text/ScoreSection.gd`, `Godot/ai/tests/test_section_tools.gd`
  - _Output_: a clip counts as shared when it has placements outside the span or loops inside it.
    By default the write is refused, naming the placements (`Bass @ 9.1.000`) and both options.
    `unique` runs `MakeClipUniqueCommand` first. `all` writes into the shared clip.
  - _Verify_: test_section_tools passes all three branches, with a clip placed at bars 1 and 9.
  - _Depends on_: T-006

- [ ] **T-008** [REQ-016, REQ-004] Drum blocks through a scratch clip.
  - _Files_: `Godot/ai/clip_text/ScoreSection.gd`, `Godot/ai/clip_text/ScoreText.gd`,
    `Godot/ai/tests/test_section_tools.gd`
  - _Output_: a drum track is detected by `NoteMapResolver.wants_drum_view` or
    `track_prefers_drums`. On read, the span is rendered via a scratch clip and
    `ClipTextGrid.serialize` with `drum_names_for_track` lane names, as an indented block. On write,
    the block is applied to a scratch clip of the current span notes, and the result goes through
    the T-006 diff. A section with a meter change and a drum block is refused, naming the bar to
    split at.
  - _Verify_: test_section_tools passes. Read, change one cell, write gives exactly one drum note
    changed. Drum Machine pad names (`Kick L`) round-trip with no changes. A 4/4 → 7/8 section with
    a drum block is refused.
  - _Depends on_: T-006

- [ ] **T-009** [REQ-015] Keyswitch placement on write.
  - _Files_: `Godot/ai/clip_text/ScoreSection.gd`, `Godot/ai/tests/test_section_tools.gd`
  - _Output_: a `ks:` becomes a note on the switch key, 1/64 long and ending at the next note's
    onset, or starting at the onset when the clip has no room before it. On read, keyswitch notes
    are taken out of the voices.
  - _Verify_: test_section_tools passes, with a `DeviceInstance` given `key_labels` directly:
    `ks:Sus_Alt D2/8` at 1.2.000 puts G-1 at onset − 60 ticks, 60 ticks long. At clip tick 0 it
    starts at 0. Reading back shows `ks:Sus_Alt`.
  - _Depends on_: T-006, T-004

## Phase 3 — tools

- [ ] **T-010** [REQ-001, REQ-002, REQ-006, REQ-007, REQ-008] `read_section` tool.
  - _Files_: `Godot/ai/tools/ReadSectionTool.gd` (new), `Godot/ai/tools/ToolRegistry.gd`,
    `Godot/ai/tests/test_section_tools.gd`
  - _Output_: arguments `bars` (or the selected range), `tracks` and `key`. The default track set
    plus a `# empty:` line. Audio tracks are listed as skipped. Off-grid tracks are shown as an
    event listing with a reason. A 16-bar cap with a note. The result is `ok_text` with no JSON
    payload. Registered in `create_default()`.
  - _Verify_: test_section_tools passes the REQ-001, 002, 006, 007 and 008 acceptance checks.
  - _Depends on_: T-008, T-009

- [ ] **T-011** [REQ-009, REQ-020, REQ-021] `write_section` tool and one undo step.
  - _Files_: `Godot/ai/tools/WriteSectionTool.gd` (new), `Godot/ai/tools/ToolRegistry.gd`,
    `Godot/ai/tests/test_section_tools.gd`
  - _Output_: arguments `text`, `bars` and `shared_clips`, with a header/`bars` mismatch as an
    error. Every line is parsed before any model changes. Each track's commands are collected and
    recorded with one `HistoryUtil.record_many("Write Section", …)`. If a later step fails, the
    collected commands are rolled back. The summary is one line per track, created or copied clips,
    and warnings as bullets.
  - _Verify_: test_section_tools passes. One undo (via `HistoryUtil.test_recorder`) removes the
    notes and the created clips of a two-track write. The result has no `|` characters. A parse
    error on track 2 leaves track 1 unchanged.
  - _Depends on_: T-010

- [ ] **T-012** [non-functional] Performance check.
  - _Files_: `Godot/ai/tests/test_section_tools.gd`
  - _Output_: a timed test that reads and then writes 16 bars × 8 tracks.
  - _Verify_: the test asserts each is under 50 ms headless.
  - _Depends on_: T-011

## Phase 4 — guidance and docs

- [ ] **T-013** [REQ-022] System prompt and tool descriptions.
  - _Files_: `Godot/ai/prompt/system_prompt.md`, `Godot/ai/tools/ReadSectionTool.gd`,
    `Godot/ai/tools/WriteSectionTool.gd`, `Godot/ai/tests/test_section_tools.gd`
  - _Output_: a "Composing with sections" block (tokens, sticky values, barline checks, voices,
    `ks:` names, drum blocks, when to use `write_clip` ops) with one example. The MIDI clips block
    is trimmed so it doesn't repeat this.
  - _Verify_: a test extracts the prompt's score example and writes it to a test project with
    `write_section`, with no error. Review against the REQ-022 list.
  - _Depends on_: T-011

- [ ] **T-014** [REQ-010, REQ-011] Update `docs/clip-text-format.md`.
  - _Files_: `docs/clip-text-format.md`
  - _Output_: a "Score text (sections)" chapter covering the grammar, reading rules and the diff
    rule for section writes. The Round-tripping section notes the exception. "Serve one clip per
    call" is removed from Limits.
  - _Verify_: review. Every grammar item in design.md appears in the doc.
  - _Depends on_: T-011

## Phase 5 — verification

- [ ] **T-015** [REQ-all] Full regression run.
  - _Files_: —
  - _Output_: a clean suite apart from known failures.
  - _Verify_: `Godot/tests/run_all.sh` passes. The only failure allowed is the existing
    `tests/test_grid_levels.gd` compile failure, if it hasn't been fixed by then.
  - _Depends on_: T-013

- [ ] **T-016** [REQ-all] Live verification with a real model.
  - _Files_: `TODO.md`, `STATUS.md` (if anything fails)
  - _Output_: the `TODO.md` entry marked `[x]`.
  - _Verify_: with the engine running, open test_metal_01 and ask for "a 4-bar 7/8 verse with bass,
    rhythm guitar and drums, Tool-like, with a keyswitch on the guitars". Check that the assistant
    uses `write_section` and that the parts line up in the arranger as 7 eighths per bar. Listen:
    the articulation changes and there's no stray low note, including when the guitar's first note
    is at the start of its clip (the same-tick keyswitch risk). One undo removes the whole write.
  - _Depends on_: T-015
