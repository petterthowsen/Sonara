# 025: AI score format and section tools — Requirements

Status: draft, awaiting approval.

## Problem

The assistant reads and writes MIDI one clip at a time, in one of three clip text formats (drum
grid, pitched grid, event list). None of them suits melodic or multi-track writing. The pitched
grid fits only narrow, quantized parts, and note lengths are runs of `-` that must be counted.
The event list gives every note an absolute `bar.beat.tick`, so the model has to do position
arithmetic per note and nothing checks that the rhythm adds up. In the test_metal_01 chat that
arithmetic went wrong in 7/8, and every guitar and bass note collapsed onto four positions without
the model noticing. The assistant also never sees tracks lined up against each other, and it has
to manage clips (create, find, name, place) even though composing is about time, not clips.

## Scope

| | |
|---|---|
| Subsystem | Godot (assistant tools and prompt) |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no — notes and clips are written through the existing models |

## Definitions

- **Section** — a span of whole bars on the arranger timeline, e.g. bars 5–8, given as a bar
  range. Bar lengths follow the project's signature map (spec 009), so one section can mix meters.
- **Score text** — the plain-text format both section tools use. One line per track (or voice),
  read left to right, with `|` barlines. Example:

  ```
  section bars 1-2   7/8   tempo 105   key Dmin
  Bass:   ks:Sus_Alt D1/8 D1 F1 D1 G1 G#1 D1 | D1/4. r/8 F1/8 G1/4 |
  Guitar: [D2 A2]/8 [D2 A2] [F2 C3] [D2 A2] [G2 D3] [G#2 D#3] [D2 A2] | [D2 A2]/2 r/4. |
  Lead:   r/2 r/8 A3/4~ | A3/2 G3/4. |
  Drums:
    |1 . 2 . 3 . 4 . 5 . 6 . 7 .|
    Kick L     |9 . . . 9 9 . . . . . . 9 .|
    Snare 1    |. . 9 . . . . . 9 . . . . .|
  ```

- **Token** — one item on a track line:
  - **note** `D1/8`: a pitch, then an optional duration. Pitches follow the existing convention
    (`C3` = MIDI 60, `C-2` = 0, sharps and flats).
  - **chord** `[D2 A2]/8`: several pitches with one onset and one duration.
  - **rest** `r/8`.
  - **tie** `A3/4~`: the note continues into the next token, which must have the same pitch(es).
  - **velocity** `@90`, after the duration: `D1/8@90`.
  - **keyswitch** `ks:<name>`: picks an SFZ articulation for the notes that follow. It takes no time.
- **Duration** — `/` then a note value straight after the pitch: `/4`, `/8.` (dotted), `/8t` (triplet). Longer or odd lengths are dotted values or ties.
- **Sticky values** — a token without a duration uses the previous duration on that line, and one
  without a velocity uses the previous velocity on that line (LilyPond-style).
- **Voice** — one of several independent lines on a track, written `Track.1:`, `Track.2:`.
- **Clip for a section** — the clip or clips placed on a track that cover the section's bars.
  Shared clip: a clip with placements outside the section.

## Requirements

### Reading

### REQ-001 — Read a section across tracks

The assistant shall have a read-section tool that returns score text for a section and a set of
tracks: every pitched instrument track as note lines, every drum track as an embedded drum grid,
all against the same barlines.

- **Acceptance:** Godot test — a project with a bass clip and a drum clip under bars 1–2 reads back
  as one score text with a `Bass:` line and a `Drums:` grid, each covering exactly bars 1–2.
- **Example:** `read_section(bars "1-2")` → the text in Definitions.

### REQ-002 — Default track set

WHEN no tracks are named, the read-section tool shall include every instrument track with notes in
the section, and list the instrument tracks with no notes there on one summary line.

- **Acceptance:** Godot test — three tracks, one empty in the span; the output has two score lines
  and `# empty: Pad`.

### REQ-003 — Positions come from durations

The read-section tool shall render each note as a duration token, filling the gaps between notes
with rests, so that every bar on every line adds up to exactly that bar's length.

- **Acceptance:** Godot test — notes at 1.1.000 (1/8) and 1.3.000 (1/4) in 7/8 read as
  `D1/8 r/8 D1/4 r/4.` (or an equivalent rest split), and summing the line's durations gives 3360
  ticks.

### REQ-004 — Barlines follow the signature map

The section tools shall size each bar from the project's signature map, not only the base time
signature.

- **Acceptance:** Godot test — a map with 4/4 for bar 1 and 7/8 from bar 2; a read of bars 1–2
  expects 3840 ticks in bar 1 and 3360 in bar 2, and the header shows both meters.

### REQ-005 — Chords and voices

The read-section tool shall show notes on one track with the same onset and the same duration as
one chord, and shall split overlapping notes that are not chords into numbered voices.

- **Acceptance:** Godot test — a sustained `C3/1` under a moving `E3/4 F3/4 G3/4 A3/4` reads as
  `Piano.1:` and `Piano.2:` lines. `C3,E3,G3` with one onset and length reads as `[C3 E3 G3]`.

### REQ-006 — Keyswitches read by name

WHERE a track's instrument reports keyswitches, the read-section tool shall show notes on
keyswitch keys as `ks:<name>` tokens instead of pitches.

- **Acceptance:** Godot test — an SFZ instrument with keyswitch `G-1 Sus_Alt`. A note on G-1
  before the phrase reads as `ks:Sus_Alt`, not as `G-1/64`.

### REQ-007 — Off-grid tracks fall back

IF a track's notes can't be shown as durations down to 1/32 (straight, dotted or triplet) without
moving them, THEN the read-section tool shall show that track as the existing event listing,
with a one-line reason, and keep the other tracks in score text.

- **Acceptance:** Godot test — a played-in track with notes 13 ticks off the grid comes out as
  an event listing with `# Keys: off-grid timing, shown as events`, and the other tracks stay in
  score text.

### REQ-008 — Bounded output

The read-section tool shall read at most 16 bars per call, and shall say so in the result when it
shortens a longer request.

- **Acceptance:** Godot test — a request for bars 1–40 returns bars 1–16 and a note naming the
  limit.

### Writing

### REQ-009 — Write a section across tracks

The assistant shall have a write-section tool that takes score text for a section and writes every
track line in it, in one call and one undo step.

- **Acceptance:** Godot test — writing a bass and a guitar line for bars 1–2 creates their notes;
  one undo removes both.

### REQ-010 — Replace in the span

WHEN a track appears in the score text, the write-section tool shall replace that track's notes
that start inside the section with the written notes. Tracks not in the text, and notes that start
outside the section, shall stay unchanged.

- **Acceptance:** Godot test — a track with notes in bars 1–4. Writing bars 2–3 leaves bars 1 and 4
  unchanged and replaces bars 2–3. A track left out of the text keeps all its notes.

### REQ-011 — Unchanged notes keep their detail

WHEN a written note has the same pitch, onset and length as an existing note on the grid it was
read from, and no velocity is written for it, the write-section tool shall keep the existing note
as it is: its velocity, microtiming offset and other note data.

- **Acceptance:** Godot test — read a section and write it back unchanged: zero notes change and
  the result says no changes. Edit one note's pitch: only that note changes.

### REQ-012 — Bar sums are checked

IF any bar on any track line doesn't add up to that bar's length, THEN the write-section tool
shall refuse the whole write and name the track, the bar, what it adds up to and what was
expected.

- **Acceptance:** Godot test — `Bass: D1/4 D1 D1 D1 |` in 7/8 is refused with an error like
  `Bass bar 1 adds up to 4/4 (3840 ticks); a 7/8 bar is 3360 ticks`, and no notes change on any
  track.

### REQ-013 — Line covers the section

IF a track line covers more or fewer bars than the section, THEN the write-section tool shall
refuse the write and say how many bars the line has and how many the section has.

- **Acceptance:** Godot test — a 3-bar line in a 4-bar section is refused with an error naming
  both counts.

### REQ-014 — Ties

WHEN a token ends with `~`, the write-section tool shall join it and the next token into one note,
across barlines too. IF the next token's pitches differ, THEN it shall refuse the write.

- **Acceptance:** Godot test — `A3/4~ | A3/2` makes one A3 note of 3 beats crossing the barline.
  `A3/4~ | B3/2` is refused naming the bar.

### REQ-015 — Keyswitches written by name

WHEN a line has `ks:<name>`, the write-section tool shall write a short note on that keyswitch's
key so the articulation applies to the next note on that line. IF the name doesn't match one of
the track instrument's keyswitches (ignoring case, `_` and spaces), THEN it shall refuse the write
and list the available names.

- **Acceptance:** Godot test — `ks:sus alt D2/8` on an SFZ with `G-1 Sus_Alt` writes a short G-1
  note that ends where D2 starts (or, when D2 is at the very start of its clip, starts with D2). `ks:Palm` is refused, and the
  error lists `Sus_Alt, Mute_Down, …`.

### REQ-016 — Drum grids in a section

WHEN the score text has a drum block, the write-section tool shall apply it with the existing
drum grid rules (cell diff, unchanged cells keep velocity and microtiming), across the section's
bars.

- **Acceptance:** Godot test — read a section with a drum track, change one cell, write it back:
  exactly one drum note changes.

### REQ-017 — Clips are found or created

WHEN a written track has no clip covering part of the section, the write-section tool shall create
a clip over the uncovered bars, named after the ruler marker over the section and the track
(`Verse Bass`), or after the track and bar range when there is no marker (`Bass 5-8`), unique
within the project.

- **Acceptance:** Godot test — writing bars 1–8 on an empty track under a `Verse` marker creates
  one clip `Verse Bass` placed at bar 1, 8 bars long. Without a marker it is named `Bass 1-8`.

### REQ-018 — Shared clips are not changed silently

IF a written track's notes would land in a clip that is also placed outside the section, THEN the
write-section tool shall refuse the write and name the other placements, unless the call asks to
either update every placement or give this placement its own copy first.

- **Acceptance:** Godot test — a `Verse Bass` clip placed at bars 1 and 9. Writing bars 1–4 is
  refused naming the placement at bar 9. With the "own copy" option, bar 9 is unchanged. With the
  "every placement" option, bar 9 changes too.

### REQ-019 — Errors point at the token

IF a token can't be parsed, THEN the write-section tool shall refuse the whole write and name the
track, the bar, the token, and the expected form.

- **Acceptance:** Godot test — `Bass: D1/8 X9/8 …` is refused with an error naming `Bass`, bar 1,
  `X9/8` and the note syntax.

### REQ-020 — Short results

WHEN a section write succeeds, the write-section tool shall return a short summary: one line per
track with its notes added, changed and removed, plus any clips it created or copied. It shall not
echo the score text back.

- **Acceptance:** Godot test — a two-track write returns two summary lines and no `|` barlines.

### REQ-021 — Range warnings

WHEN a written note falls outside the track instrument's playable keys, the write-section tool
shall make the write and add a warning that names the track, the bar and the note.

- **Acceptance:** Godot test — an SFZ playable from F#0 to F#5; writing `G-1/8` as a note (not a
  `ks:` token) succeeds with a warning naming it.

### Guidance

### REQ-022 — The assistant is taught the format

The system prompt and the section tools' descriptions shall describe the score text (tokens,
sticky values, barline checks, voices, keyswitch names, drum blocks) with one example, and shall
say to use the section tools for composing and `write_clip` event commands for precise edits.

- **Acceptance:** Godot test — the score text example in the system prompt, written to a test
  project with the write-section tool, succeeds. Review: the prompt covers each item listed above.

## Non-functional

- **Latency / performance:** a 16-bar read or write over 8 tracks finishes in under 50 ms in a headless test.
- **Compatibility:** `read_clip`, `write_clip` and `create_clip` keep working as they do today.
  Saved chats replay unchanged.

## Out of scope

- Swing, push, articulation lanes other than keyswitches, CC, pitch bend and automation.
- Humanize: a later note effect, not a property of the format.
- Audio tracks. They are listed as skipped, not read.
- A harmonic or chord-symbol format.
- Trimming the results of the other tools (a separate change).

## Open questions

- [ ] Should `read_clip` stop choosing the pitched grid once score text exists, with pitched parts
      going through `read_section` instead? (Recommended: yes, but after live use, so not in this spec.)
- [ ] Note that `docs/clip-text-format.md` says "never apply a returned serialization as a
      replacement" and "serve one clip per call". REQ-010 and REQ-011 replace that rule for section
      writes: replacing is allowed because notes that haven't changed are kept untouched. The doc
      will be updated to match. This isn't an ADR, so there's nothing to supersede formally.
