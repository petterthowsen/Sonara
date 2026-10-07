# Clip text format

Serialization used between Sonara and the assistant. The read tool picks one
representation per clip. All are **diff-safe** — see [Round-tripping](#round-tripping).

Phase 3 implements **drums**, **pitched grid**, and **event list** only. Composing across
tracks uses the separate [score text](#score-text-sections) of `read_section` /
`write_section` (spec 025). Swing,
push, and articulation lanes are omitted. Harmonic clips are not used — every
clip is MIDI so it stays editable. Refer to clips by **name**; the same named
clip may be placed many times.

Companion to [`ai-integration.md`](ai-integration.md).

---

## Common header

```
clip <name>   type <kind>   res 1/16   bars 5-8
key Cmin      tempo 96      swing 56%
```

- `res` — grid resolution. `1/16` default; `1/12`, `1/24` for triplets.
- `key` — enables scale-degree labels. Omit for atonal/percussive.
- `swing`, `push` — groove directives. **Never** expressed per-step.

---

## 1. Drum grid — `type drums`

One lane per drum. One character per step. `|` every beat (required — it's
what keeps step counting reliable).

```
        |1 e & a|2 e & a|3 e & a|4 e & a|
KICK    |9 . . .|. . 6 .|. . 8 .|. . . .|
SNARE   |. . 2 .|8 . . 3|. 2 . .|9 . . 4|
HAT     |7 . 4 .|6 . 4 .|7 . 4 .|6 . 4 5|
OHAT    |. . . .|. . . .|. . . .|. . 7 .|
```

| char | meaning |
|---|---|
| `.` | rest |
| `1`–`9` | note-on at dynamic tier |
| `x` / `*` | hit at the default tier (7) |

**Tier → velocity** (per-kit curve, this is the default):

```
tier   1    2    3    4    5    6    7    8    9
vel   17   30   43   56   69   82   95  108  121
      └ ghost ┘   └ body ┘   └ accent ┘
```

Humanization jitter (±3–6, wider on hats than kick) is applied below this layer
and is never in the text.

**Articulation** gets its own optional lane, emitted only when non-empty:

```
SNARE   |. . 2 .|8 . . 3|. 2 . .|9 . . 4|
  art   |. . . .|f . . .|. . . .|. . . .|
```

`f` flam · `r` roll · `c` choke · `s` rimshot.

---

## 2. Pitch grid — `type pitched`, narrow range

Same grid, lanes are pitches. Only pitches in use are emitted. Right column is
scale degree.

```
         |1 e & a|2 e & a|3 e & a|4 e & a|
 Bb3  b7 |. . . .|. . . .|7 - - -|- - . .|
 G3    5 |. . . .|8 - - -|- - - -|- - . .|
 Eb3  b3 |. . . .|. . . .|. . . .|. . 6 -|
 C3    1 |9 - - -|- - - -|- - - -|- - . .|
```

| char | meaning |
|---|---|
| `.` | silent |
| `1`–`9` | note-on at dynamic tier |
| `-` | previous note held |

Lanes are ordered high → low. The model may write degrees (`b7`) or pitch
names (`Bb3`); both are accepted on input, degrees are always served on output.

---

## 3. Event list — `type pitched`, wide or unquantized

Fallback when the grid doesn't fit.

```
n01  5.1.000  C2    1/4.   v104
n02  5.3.000  G2    1/8    v88   -12t
n03  5.3.240  Bb2   1/8    v72
n04  6.1.000  Eb2   1/2    v96
```

`id  bar.beat.tick  pitch  duration  velocity  [offset]`

- ticks at project PPQ; `-12t` is microtiming offset in ticks
- `id` is stable within one serialization, regenerated on each read
- durations: `1/4`, `1/4.` dotted, `1/4t` triplet, or `Nt` raw ticks

---

## 4. Harmonic clip — `type harmonic`

Notes are a *render*; the progression is the source of truth. Preferred for
pads, keys and comping.

```
prog     | Cm7 | Fm9 | Bb7sus | Ebmaj7 |
voicing  rootless-A, range G3-D5, top-note-smooth
rhythm   dotted-8 anticipation
```

User can freeze to plain MIDI at any point, which converts the clip to
`type pitched` and drops the directives.

---

## Format selection

Applied by the read tool, deterministically. On fallback, emit a one-line
reason so the model doesn't re-ask.

```
harmonic     if clip carries a progression and has not been frozen
drums        if track role is percussive
pitch grid   if  pitch_span   ≤ 16 semitones
             and note_count   ≤ 64
             and max|offset|  <  res/8
             and no overlapping notes within a lane
event list   otherwise
```

```
# 23-semitone span, serving event list
```

---

## Round-tripping

Never apply a returned serialization as a replacement — it is lossy by design
and a naive write destroys hand-programmed nuance. (Score text section writes are
the exception: they replace, but as a diff that leaves every unchanged note
untouched — see [Score text](#score-text-sections).)

**Grids** round-trip whole, diffed character by character:

| change | effect |
|---|---|
| unchanged | note untouched — exact velocity and microtiming preserved |
| `.` → digit | new note at tier's curve value |
| digit → `.` | delete |
| digit → digit | retarget velocity; **keep existing microtiming offset** |
| `.` → `-` | extend preceding note |
| `-` → `.` | shorten preceding note |

Read → unmodified write is therefore a no-op.

**Event lists** round-trip as operations, not as a rewritten list:

```
move n03  +1/16
vel  n01  88
len  n04  1/4
del  n07
add  6.3.000  Ab2  1/8  v76
```

Cheaper, inherently diff-safe, and gives a readable log of what the assistant
did plus natural undo granularity. Notes are addressed by `id` only — never by
index into a list.

---

## Limits

- Grids above 32 steps per line wrap badly; split into bar blocks or fall back.
- Deeply polyrhythmic or rolled material is not grid-shaped. Don't force it.
- Clip formats serve one clip per call; score text serves a section across tracks.
  Project-level context goes in the state summary, not here.

---

## Score text (sections)

Spec: [`specs/025-ai-score-format/`](specs/025-ai-score-format/). Used by `read_section` /
`write_section`, implemented in `Godot/ai/clip_text/ScoreText.gd` (text) and
`ScoreSection.gd` (clips). Works on bars of the song, not clips: the tools find the clips
under those bars, or create them.

```
section bars 1-2   7/8   tempo 105
Bass:   ks:Sus_Alt D1/8 D1 F1 D1 G1 G#1 D1 | D1/4. r/8 F1/8 G1/4 |
Lead:   r/2 r/8 A3/4~                      | A3/2 G3/4.          |
Keys.1: E3/4 F3 G3/8 r/4                  | E3/2 r/4.           |
Keys.2: C3/2 r/4.                          | C3/2~ C3/4.         |
Drums:
           |1 .|2 .|3 .|4 .|5 .|6 .|7 .|
  KICK     |9 .|. .|9 9|. .|. .|. .|9 .|
```

### Grammar

| token | meaning |
|---|---|
| `D1/8` | note: pitch, then its value right after it (`/1 /2 /4 /8 /16 /32`) |
| `D1/4.` · `D1/8t` | dotted · triplet |
| `[D2 A2]/8` | chord: one onset, one value |
| `r/8` | rest |
| `A3/4~` | tie into the next token, which must be the same pitch(es); also across `|` |
| `@90` | velocity 1–127, after the value |
| `ks:Sus_Alt`, `ks:"Mute Down"` | keyswitch by name (case, `_`, `-` and spaces ignored); takes no time |
| `\|` | barline |

- **Sticky values:** a token without a value or velocity repeats the previous one on its line
  (default velocity 100; the first note or rest needs a value).
- There is no `3/8`: longer values are dotted or tied. One spelling per length, and no `D13/8`
  ambiguity.
- **Lines:** `Track:` (or `Track.N:` for a voice) then tokens. A label seen again later continues
  its line, so long sections wrap into systems (`# bars 5-8` comments are informational). A label
  with nothing after the colon starts a drum block: the indented lines below it are a drum grid
  (section 1) covering the section's bars.
- **Checks on write:** every bar adds up to exactly its length from the signature map
  (`Bass bar 1 adds up to 8/8 (3840 ticks); a 7/8 bar is 3360 ticks`); each line covers exactly
  the section's bars; a tie joins the same pitches. Any error refuses the whole write before
  anything changes.

### Reading

- Notes snap to the 1/32 straight or triplet grid when within 20 ticks; a track with notes
  further off is shown as an event listing (positions counted from the section start) with a
  reason.
- Notes with the same onset and length are a chord; overlapping notes that aren't are split
  into numbered voices.
- Values are split at barlines and tied. A value starts on a multiple of its alignment within
  the bar: half its length for straight values, the undotted half for dotted ones, its own
  length for triplets. A note running past the section end ends with `~`.
- Velocity is printed only where it changes. Keyswitch notes are shown as `ks:` tokens.
- A note belongs to the section its snapped onset falls in, so an early downbeat stays with its
  own bar.

### Writing

A write replaces the notes that start in the section on the tracks it names, **as a diff**:
written notes are matched to existing ones by pitch and by onset and length *as the reader shows
them*. Matched notes stay untouched (exact velocity, microtiming and id); a different written
velocity changes only the velocity. Unmatched existing notes are removed, unmatched written notes
added. A read written back unchanged is a no-op. Drum blocks use the grid cell diff through a
scratch clip. Uncovered bars that receive notes get a new clip (`Verse Bass` under a marker, else
`Bass 5-8`); clips also placed elsewhere need `shared_clips` `unique` or `all`. One write is one
undo step.

