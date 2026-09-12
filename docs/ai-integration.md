# Can an LLM compose?

*Sonara — assistant design note*

Yes — but with a specific shape of competence that's worth designing the tool
surface around rather than designing against. Notes on musical capability,
symbolic modality, and what that implies for an in-DAW assistant.

---

## Where the competence actually sits

| Task | Reliability | Notes |
|---|---|---|
| Harmony & form | **Strong** | Progressions, reharmonization, modal interchange, song structure and bar counts. An enormous corpus of chord charts and roman-numeral analysis sits in training data, and "correct" here is largely rule-governed. |
| Idiomatic patterns | **Strong** | A boom-bap kit pattern, a walking bassline over changes, ii–V voicings, a 16th-note arpeggiated pad. Pastiche of a named idiom is dependable. |
| Arrangement decisions | **Strong** | What drops out at bar 33, which register the counter-melody occupies, when to thin the low end. |
| Editorial critique | **Strong** | "This progression is static for sixteen bars — here are three ways to open it up." Underrated, and probably where an in-DAW assistant earns its keep. |
| Melody with surprise | **Weak** | Competent, forgettable contours. The same failure mode as prose: fluent mean-of-the-distribution output. |
| Groove & micro-timing | **Weak** | Velocity curves come out either suspiciously uniform or randomly noisy. Neither feels human. |
| Long-form coherence | **Weak** | Motivic development degrades across three minutes. |
| Judging its own output | **Absent** | It cannot hear. There is no native feedback loop, and this is the constraint everything else has to route around. |

---

## Modality

MIDI, yes — but symbolic and textual, never raw bytes.

### Note-event lists — *primary write path*

JSON or a compact DSL: pitch, start, duration, velocity, expressed in
*musical* time — bar:beat:ticks, never samples. Most controllable, best fit for
a tool API, heavy in tokens. Scope it to a single clip per call and the cost
stays reasonable.

```json
{ "clip": "bass_A", "tempo": 96, "notes": [
  { "p": 38, "at": "1:1:000", "len": "0:0:360", "vel": 104 },
  { "p": 45, "at": "1:2:240", "len": "0:0:180", "vel":  82 },
  { "p": 41, "at": "1:3:000", "len": "0:0:360", "vel":  97 }
]}
```

### Chord & roman-numeral text — *harmony ops*

Cheap in tokens, and the representation where the model is smartest. A
deterministic voicing engine expands it into notes — don't make the model place
every voice by hand.

```
Dm7 | G7alt | Cmaj7 | Cmaj7
 ii7    V7      Imaj7   Imaj7      (key: C)
```

### ASCII step grids — *drums*

Handled unreasonably well, token-cheap, and human-readable right there in the
chat transcript — the user can correct a hat placement by editing one character.

```
        1 e + a 2 e + a 3 e + a 4 e + a
KICK   |x . . . . . x . . . x . . . . .|
SNARE  |. . . . x . . . . . . . x . . x|
HAT    |x . x . x . x . x . x . x . x .|
OHAT   |. . . . . . . x . . . . . . . .|
```

### ABC notation — *monophonic melody*

Plenty of training data, but it pulls hard toward generic folk idiom. Useful as
a quick sketch format, not as the backbone.

### What to skip

MusicXML — verbose, terrible token economy for what it returns. Raw `.mid`
bytes — never. Anything sample-accurate. And audio generation is a different
model class entirely (diffusion / audio transformers); treat it as a separate
integration rather than something the chat assistant does.

---

## Split intent from realization

Let the model decide *intent* — "accent the backbeat, swing 58%, velocities
70–110 with the downbeats hot" — and let deterministic Rust DSP carry out the
*realization*. Anything that needs numerical finesse across hundreds of events
should be a parameterized function the model calls, not values it emits one at a
time. Same for humanization, quantization, voicing, transposition.

Which means the tool surface matters more than the model does. Design the verbs
at the level a musician thinks at:

**Tools shaped like musical intent**

```
set_progression(track, bars, "Dm7 | G7 | Cmaj7")
generate_pattern(track, style, bars)
reharmonize(clip, approach)
apply_groove(clip, template, amount)
thin_arrangement(bars, keep: [...])
```

**Tools that burn the context window**

```
insert_note(pitch, tick, vel)   × 400
set_param(4103, 0.6274509)
```

The other half of the engineering work is the *read* path: a compact
serialization of current project state — tempo, key, track roles, markers, what's
in the neighbouring clips — so the model writes into a context rather than into a
vacuum. Read tools deserve as much design attention as write tools.

---

## Beyond MIDI

- **Automation curves** as breakpoint lists — a clean fit, structurally identical to note events.
- **Mixer moves.** "Hi-pass the pads at 250, pull 400 Hz on the guitar, bus the drums." There is a great deal of mixing pedagogy in training data and it maps directly onto tool calls. Surprisingly strong.
- **Synth patch design** — genuinely good *if* parameters are exposed with semantic names, units and ranges. Bad with raw normalized floats on an unnamed synth.
- **Sample and preset search** — the model drives an embedding search over library metadata. High return, low risk, no musical judgement required.
- **Project hygiene** — naming, coloring, grouping, tagging, cleanup, routing. Boring, and the thing people will actually use every single day.

---

## The honest limitation

You can partially close the loop by rendering and feeding back extracted
features — pitch histogram, note density, onset distribution, LUFS, spectral
centroid. But that is reading a *description* of the music, not hearing it. It
catches "this is too dense" and misses everything that matters about whether it's
any good.

> In practice the loop is human: the model proposes, you audition, you say "too
> busy in the second half." Build the UX for that exchange rather than for
> one-shot generation, and the whole feature gets considerably more useful — and
> considerably more honest about what it is.
