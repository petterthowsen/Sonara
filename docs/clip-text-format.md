# Clip text format

Serialization used between Sonara and the assistant. The read tool picks one
representation per clip. All are **diff-safe** — see [Round-tripping](#round-tripping).

Phase 3 implements **drums**, **pitched grid**, and **event list** only. Swing,
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
and a naive write destroys hand-programmed nuance.

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
- Serve one clip per call. Project-level context goes in the state summary, not here.
