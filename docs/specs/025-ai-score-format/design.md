# 025: AI score format and section tools — Design

Status: draft, awaiting approval.

Implements [requirements.md](./requirements.md).

## Context

- `Godot/ai/clip_text/` — the existing clip text formats. `ClipText.gd` (`serialize`, `apply`,
  `parse_header`), `ClipTextGrid.gd` (drum and pitched grids: `serialize`, `parse`, `apply`, cell
  diff that keeps velocity and microtiming), `ClipTextEvents.gd` (event listing and ops),
  `ClipTextTime.gd` (`parse_duration`, `format_duration`, `check_bbt`, `DURATION_FORMS`),
  `ClipTextKey.gd` (`parse_pitch`, `pitch_name` with flat spelling from a key, `parse_key`,
  `TIER_VEL`).
- `Godot/ai/tools/AiTool.gd` — base tool: `ok`, `ok_text`, `fail`, `require_project`,
  `resolve_track`, `find_clip_instances`, `track_prefers_drums`, `drum_names_for_track`,
  `clip_text_opts`, `position_error`. `ToolRegistry.gd` `create_default()` registers tools.
- `Godot/ai/tools/SfzKeyInfoUtil.gd` — keyswitch names (`_switch_name`) and playable ranges from
  a `DeviceInstance`'s `key_labels` / `playable_ranges`.
- `Godot/data/NoteMapResolver.gd` — `find_auto_source(channel)` (the SFZ, Drum Machine or zoned
  Layer a channel's note names come from), `wants_drum_view(channel)`.
- `Godot/data/TimeSignatureMap.gd` — `segments(base_num, base_den, ppq)` gives bar-aligned
  stretches with `bar`, `tick`, `bar_ticks`, `end_tick`. `tick_of_bar(...)`.
  `Project.time_signature_map`, `Project.time_numerator` / `time_denominator` (base signature).
- `Godot/data/ClipInstance.gd` — `start_ticks`, `duration_ticks`, `clip_offset`, `transpose`,
  `loop_enabled`, `song_to_clip_ticks`, `clip_to_song_ticks`, `first_run_range`.
- `Godot/data/MidiNote.gd` (`MidiNoteData`) — `id`, `note`, `velocity` (0–1 float), `release`,
  `start_tick` (clip-local), `duration_ticks`. `Clip.add_midi_note`, `remove_midi_note`,
  `update_midi_note`, `allocate_note_id`.
- `Godot/data/Project.gd` — `markers` (`SongMarker`: `name`, `start_ticks`, `duration_ticks`),
  `create_clip`, `unique_clip_name`.
- `Godot/history/` — `ClipRangeActions.overlapping(track, start, end)`,
  `commands/ClipInstanceCreateCommand.gd`, `commands/MakeClipUniqueCommand.gd`,
  `commands/ClipNotesStateCommand.gd` (`capture_clip_notes`, `snapshots_equal`),
  `commands/MacroCommand.gd` (undo runs in reverse), `HistoryUtil.record_many`.

## Approach

**Two layers: a pure text layer and a project layer.** The text layer (`ScoreText`) knows nothing
about clips. It turns score text into a list of *section notes* `{pitch, start, length, velocity,
voice, keyswitch}` in section-local ticks, and back, given a **bar plan** (each bar's start tick and
length, from the signature map). Barline sums, ties, sticky values, chords, voices and token errors
all live here and are tested without a project. The project layer (`ScoreSection`) gathers a
track's notes in a song span from whichever clip placements cover it, as section notes, and writes
a list of section notes back as a diff against what is there. The two tools are thin: parse
arguments, build the bar plan, call the two layers, format the short result.

**Writing is a diff, not delete-and-re-add.** For each track, existing notes that start in the
section are matched against the written notes by pitch, onset and length (within `SNAP_TICKS`, the
same tolerance the reader rounds with). Matched notes are left untouched, unless a written velocity
differs from theirs, in which case only the velocity changes. Unmatched existing notes are removed
and unmatched written notes are added. This gives REQ-011 (read and write back unchanged is a
no-op) and the readable added/changed/removed summary for REQ-020. It's also why replacing is safe
despite the rule in `docs/clip-text-format.md`. **Drum blocks** reuse `ClipTextGrid` unchanged: the
span's drum notes are copied into an unpooled scratch clip starting at tick 0, the grid is applied
to the scratch clip with its normal cell diff, and the scratch result is fed through the same note
diff. The grid code never has to learn about clip offsets.

**Rejected: extending `ClipText` with a fourth clip-local kind.** It would keep the one-clip view,
so the model would still have to find and create clips and work in clip-local time, and the
existing `kind` dispatch (`_select_kind`, `looks_like_ops`, `_looks_like_grid`) would get a fourth
heuristic to guess between. Section tools are a separate entry point with their own grammar. They
only reuse leaf helpers (durations, pitches, grids).

## Thread and ownership

All new code runs on the Godot main thread inside tool `execute()`, like every other assistant
tool. No engine state, no audio-thread path. Notes reach the engine through the existing
`Clip.add_midi_note` / `update_midi_note` / `remove_midi_note` OSC sync.

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| Bar plan, parsed section notes | Godot main (tool call, temporary) | — | n/a |
| Clip notes and placements | Godot main (`data/` models) | existing OSC sync | n/a (unchanged) |

## Score text grammar

```
section   := header? (comment | system)*
header    := "section bars" N "-" M (meter | "tempo" X | "key" K)*      # informational on write
system    := line+                                                        # usually 4 bars per system
line      := label ":" token* ("|" token*)* "|"      # note line
           | label ":" NEWLINE grid_line+           # drum block (existing grid syntax, indented)
label     := track name, optionally "." voice number (Piano.2)
token     := note | chord | rest | keyswitch
note      := pitch dur? vel? "~"?        e.g. D1/8   A3/4.~   F#2@90
chord     := "[" pitch (" " pitch)+ "]" dur? vel? "~"?
rest      := "r" dur?
keyswitch := "ks:" name                   # name may contain spaces up to the next token; quoted form ks:"Mute Down"
dur       := "/" N ("." | "t")?           # "1" + dur goes to ClipTextTime.parse_duration (1/4, 1/8., 1/8t)
vel       := "@" 1..127
```

- A label seen again in a later system continues that line where it stopped, so long sections
  wrap like systems on a page. Each system starts with a `# bars 5-8` comment on read. On write,
  the comment is informational.
- A duration is always `/<value>` straight after the pitch, optionally dotted or triplet
  (`D1/8`, `D1/4.`, `D1/8t`). There is no `3/8` form: longer values are dotted values or ties
  (`D1/4.`, `D1/4~ D1/8`). That keeps one spelling per length and avoids `D13/8` (D1 + 3/8, or
  D13?). The reader only ever emits these forms.
- Sticky duration and velocity reset at the start of each line (each track or voice), not at each
  barline. The first token on a line with no duration is an error naming the line. The default
  velocity is 100.
- `section bars N-M` in the header must match the tool's `bars` argument when both are given.
  Otherwise the header supplies it.
- A voice label (`Piano.2`) resolves to its track only after the full label (`Piano.2`) fails to
  match a track name, so a track that is really called `Piano.2` still works.

### Reading: notes → tokens

1. **Snap.** Every onset and end is rounded to the nearest multiple of the finest step (1/32 straight
   = 120 ticks, or 1/32 triplet = 80 ticks, whichever is closer) when it is within `SNAP_TICKS` (20)
   of one. If any note on a track is further off than that, the whole track falls back to the event
   listing (REQ-007), rendered by `ClipTextEvents.serialize` over a scratch clip with section-local
   ticks.
2. **Voices.** Notes sorted by onset. Notes with the same onset and length form a chord. Each chord or
   note goes to the lowest voice whose previous note has ended. A track that needs more than one
   voice renders `Track.1:`, `Track.2:`, and so on.
3. **Keyswitches.** Notes on a key that the track's instrument names as a keyswitch are removed from
   the voices and emitted as `ks:<name>` on voice 1, immediately before the first token that starts
   at or after the keyswitch note.
4. **Durations.** The timeline of each voice (notes and the gaps between them) is cut at barlines.
   Each piece is written as the fewest tokens from the value table (whole, half, quarter, 1/8, 1/16,
   1/32, each straight, dotted or triplet), longest first, so that every piece starts on a multiple
   of its own value where possible (no dotted quarter starting on an off-beat 16th). A note cut by a
   barline becomes `X~ | X`. Gaps become rests.
5. **Velocity** is printed only where it changes from the previous token on that line, as
   `round(velocity * 127)`.
6. **Pitch spelling** uses `ClipTextKey.pitch_name(note, key)` when the call passes `key`.

### Writing: tokens → notes

Parse each line into a section-note list, checking as it goes: unknown token (REQ-019), a bar that
doesn't add up (REQ-012, the error gives both the musical value and ticks), a line with the wrong
bar count (REQ-013), and a tie to a different pitch, or a tie with nothing after it (REQ-014). The
first error aborts the whole write before any model is touched. Bar sums are compared exactly in
ticks, so triplets have to complete within the bar.

## Project layer: clips for a section

**Gathering (read and write).** For a track and song span `[s, e)`: `ClipRangeActions.overlapping`
gives the placements. For each, clip notes whose song onset
(`clip_to_song_ticks(note.start_tick)`) falls in `[s, e)` and inside the placement's played range
(`first_run_range`) become section notes. The pitch is `note + transpose` and the record is
`{note_ref, clip, instance}`. Looped placements whose loop wraps inside the span are treated as
shared (below).

**Ownership on write.** A written note goes to the placement whose span contains its onset. A
note that runs past its placement's end is shortened to the end, with a warning. Onsets not
covered by any placement are grouped into contiguous uncovered bar runs. Each run that receives at
least one note gets a new clip covering the whole run (REQ-017). The name comes from the marker
whose span contains the run's start (`"<Marker> <Track>"`), else `"<Track> <first>-<last>"`, then
`Project.unique_clip_name`. Uncovered runs with no written notes get no clip.

**Shared clips (REQ-018).** A clip is shared when `find_clip_instances` returns placements of it
that don't overlap the section, or a placement loops within the span. The tool's `shared_clips`
argument decides:
- absent: refuse, naming each other placement (`Bass @ 9.1.000`) and both options.
- `"unique"`: run `MakeClipUniqueCommand` on each placement in the span first, then write.
- `"all"`: write into the shared clip. Every placement changes.

**One undo step (REQ-009).** Structural commands (`ClipInstanceCreateCommand`,
`MakeClipUniqueCommand`) are run with `do()` as they are built and collected into a list. Then
`ClipNotesStateCommand.capture_clip_notes` snapshots every touched clip, notes are added, updated and
removed through the `Clip` methods, and one `ClipNotesStateCommand` per changed clip is appended.
`HistoryUtil.record_many("Write Section", cmds)` records the list as one `MacroCommand`, and undo
reverses it: notes first, then clip creation. If anything fails after parsing (it shouldn't, because
parsing validates everything first), the collected commands are undone in reverse before the error
is returned.

**Drum tracks.** A track is a drum track when `NoteMapResolver.wants_drum_view` on its channel, or
`track_prefers_drums`, is true. Reading renders the span through a scratch clip with
`ClipTextGrid.serialize` and `drum_names_for_track` lane names. Writing applies the block to a
scratch clip holding the span's current drum notes, then diffs the scratch result as above.
**Limit:** the grid assumes one meter, so a section with a drum block must have a constant meter.
Otherwise the tool refuses with "split the section at bar N where the meter changes". Note lines
are unaffected.

## Tool surface

`read_section`:

| arg | type | |
|---|---|---|
| `bars` | string | `"5-8"`, required unless the selected range is used |
| `tracks` | string[] | default: tracks with notes in the span (REQ-002) |
| `key` | string | optional, for flat spelling |

`write_section`:

| arg | type | |
|---|---|---|
| `text` | string | score text, required |
| `bars` | string | optional if the header has `section bars` |
| `shared_clips` | enum `unique` / `all` | optional, REQ-018 |

Results are `ok_text`: a header line, the score text (for a read), and warnings as `- ` Markdown
bullets. A write returns one line per track (`Bass: +7 notes, 2 changed, 3 removed`), created and
copied clips, and warnings. No JSON `data` payload beyond counts.

## Data and protocol changes

None. No OSC messages, no persisted keys, no engine changes. Notes and clips go through existing
models and commands.

## File-by-file change list

| File | Change |
|---|---|
| `Godot/ai/clip_text/ScoreText.gd` | **New.** Pure text layer: `parse(text, plan, ctx) -> {lines: {label: {track, voice, notes, keyswitches}}, error}`, `serialize(tracks, plan, ctx) -> String`, bar-plan helpers, the value table and duration splitting, `SNAP_TICKS`. `ctx` carries ppq, key, and per-track keyswitch name ↔ key maps. |
| `Godot/ai/clip_text/ScoreSection.gd` | **New.** Project layer: `bar_plan(project, first_bar, last_bar)` from `TimeSignatureMap.segments`, `gather(project, track, s, e)`, `write(project, track, s, e, notes, opts) -> {cmds, summary, warnings, error}`, shared-clip detection, clip creation and naming, the note diff, drum scratch-clip round trip, keyswitch and playable-range lookup through `NoteMapResolver.find_auto_source` + `DeviceInstance.key_labels` / `playable_ranges`. |
| `Godot/ai/tools/ReadSectionTool.gd` | **New.** `read_section`. Resolves tracks, the bar range (or the selected range, as `resolve_time_span` does), the 16-bar cap (REQ-008), per-track fallback reasons, and the empty-tracks line. |
| `Godot/ai/tools/WriteSectionTool.gd` | **New.** `write_section`. Parses, checks the constant meter for drum blocks, writes each track, records one history step, and formats the summary (REQ-020, REQ-021). |
| `Godot/ai/tools/ToolRegistry.gd` | Register both tools in `create_default()`. |
| `Godot/ai/tools/SfzKeyInfoUtil.gd` | Make the keyswitch name lookup public (`switch_name`, plus a `keyswitch_map(inst) -> {norm_name: key}` helper that normalizes case, `_` and spaces) so `ScoreSection` and the existing text share one spelling. |
| `Godot/ai/prompt/system_prompt.md` | New "Composing with sections" block (REQ-022): format summary, one example, when to use the section tools and when to use `write_clip` ops. Trim the MIDI clips block so it doesn't repeat it. |
| `docs/clip-text-format.md` | New "Score text (sections)" chapter: grammar, reading rules, the diff rule replacing "never apply a serialization as a replacement" for sections. Drop "serve one clip per call" from Limits. |
| `Godot/ai/tests/test_score_text.gd` | **New.** Pure text-layer tests. |
| `Godot/ai/tests/test_section_tools.gd` | **New.** Tool and project tests. |
| `TODO.md` | AI Assistant entry pointing at this spec. |

## Migration and compatibility

Nothing is persisted. `read_clip`, `write_clip` and `create_clip` are unchanged, so saved chats
that call them replay as before. Section tools are additive.

## Test plan

- **Godot, text layer** — `godot --headless --path Godot -s ai/tests/test_score_text.gd -- --test`:
  sticky duration and velocity; chords; ties across barlines (REQ-014); bar sum errors in 4/4 and
  7/8 with the exact message (REQ-012); line bar count (REQ-013); token errors (REQ-019); `D1/8`
  parsing, and `D13/8` refused with the `/<value>` form; duration splitting (`1/8 + 1/4.` in 7/8, notes cut by barlines become ties);
  voice split (REQ-005); a mixed 4/4 + 7/8 bar plan (REQ-004); snap and fallback detection (REQ-007);
  keyswitch name normalization (`sus alt` = `Sus_Alt`).
- **Godot, tools** — `godot --headless --path Godot -s ai/tests/test_section_tools.gd -- --test`,
  set up like `test_clip_range_tools.gd` (`Project`, `Editor`, `HistoryUtil.test_recorder` for
  undo): REQ-001, 002, 003, 006, 008, 009 (one undo step removes everything, including created
  clips), 010, 011 (round trip is a no-op, and microtiming within `SNAP_TICKS` survives), 015 (an
  SFZ-like `DeviceInstance` with `key_labels` set directly), 016, 017, 018 (all three branches), 020,
  021; the system prompt example writes cleanly (REQ-022); a 16-bar × 8-track read/write timing
  check (< 50 ms).
- **Regression** — `Godot/tests/run_all.sh clip_text section score` while working, then the full
  `Godot/tests/run_all.sh` once.
- **Live** — with the engine running, ask the assistant for a 4-bar 7/8 verse with bass, guitar
  and drums on test_metal_01. Check that it uses `write_section`, that the parts line up in the
  arranger, that the keyswitch is audible as an articulation and not as a note, and that undo
  removes the whole write.

## Risks

| Risk | Mitigation |
|---|---|
| A keyswitch at the same tick as the first note of a clip (no room before it) may be processed after the note, so that note plays the old articulation. | Place keyswitches `1/64` before the note whenever the clip has room. Check the same-tick case live with the metal guitar SFZ. If it's wrong, give new clips a one-beat lead-in or extend the clip start. |
| Models misread `D1/8` (pitch D1, eighth) as something else, or write `D18`. | The token error shows the form (`<pitch>/<value>, e.g. D1/8`). The prompt example uses it heavily. Check the transcript in live verification. |
| Duration splitting produces ugly but valid spellings (rests split oddly), which the model then copies. | Splitting aligns values to their own grid. Tests pin the spelling of common 4/4 and 7/8 cases. |
| Many placements and odd instance states (trimmed, transposed, looped) make gathering wrong. | Gathering uses only `clip_to_song_ticks`, `first_run_range` and `transpose`, the same ones the arranger draws with. Looping inside the span counts as shared. Tests cover a trimmed and a transposed placement. |
| Drum blocks can't span meter changes. | An explicit refusal with the bar to split at. Revisit if live use needs it. |

## Open questions

- [x] `3/8`-style values: no colon form. Non-unit lengths are dotted values or ties (decided 2026-10-07).
