# Metronome — Requirements

## Problem

Sonara has no metronome. The metronome icon in the arranger's tracklist header only toggles the
bar/beat ruler row. Anyone playing or recording against the timeline has to load a drum
instrument on a track and program a click pattern by hand. That pattern then ends up in exports
and has to follow every time signature change by hand.

## Scope

| | |
|---|---|
| Subsystem | both |
| Touches real-time audio thread | yes: clicks are scheduled and rendered on the audio callback; the design must respect the audio-thread contract |
| Adds or changes an OSC message | yes: protocol docs are part of the definition of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes: new user settings (on/off, sound) and a new project field (patterns). Additive; older projects load with defaults and need no migration |

## Terms

- **Emphasis level**: the strength of one metronome step: Off, or 1 (weakest) to 4 (strongest).
  Each of the four levels has its own colour in the step grid.
- **Pattern**: one bar of steps for one time signature, each holding an emphasis level.
- **Resolution**: the note length of one step. It is 1/4, 1/8 or 1/16, as a fraction of a whole
  note.

## Requirements

### Transport controls

### REQ-001: Metronome toggle

The transport area shall show a metronome on/off toggle button. Its pressed state is whether the
metronome is enabled.

- **Acceptance:** Godot test: pressing the toggle flips the metronome model's `enabled` and the
  button follows a model change made elsewhere.

### REQ-002: Configuration popup

WHEN the user presses the metronome settings button next to the toggle, the transport area shall
open a popup panel below it holding the step grid (REQ-010 to REQ-014) and the sound controls
(REQ-020 to REQ-024). WHEN the user clicks outside the popup, it shall close.

- **Acceptance:** live: the popup opens under the button and closes on an outside click; Godot test
  instantiates the popup scene without errors.

### REQ-003: Hotkey

The Hotkeys registry shall have a rebindable `transport_metronome_toggle` action that toggles the
metronome. It has no default chord.

- **Acceptance:** Godot test: the action is registered, and dispatching it flips `enabled`.

### Click playback

### REQ-004: Clicks while playing

WHILE the metronome is enabled and the transport is playing, the audio engine shall play one click
at the exact frame of every step whose emphasis level is not Off.

- **Acceptance:** `cargo test`: at 120 BPM, 4/4, quarter resolution and 48 kHz, the clicks trigger at
  frames 0, 24 000, 48 000 and 72 000 (±0) across block sizes 64, 256 and 1024.

### REQ-005: Silent while stopped or disabled

WHILE the transport is stopped, or the metronome is disabled, the audio engine shall trigger no
clicks. A click already sounding shall finish its natural decay.

- **Acceptance:** `cargo test`: no trigger with transport stopped; no trigger after disable; no
  hard cut of an in-flight click (no sample jumps above the click's own slope).

### REQ-006: Follows the timeline

The audio engine shall place clicks on the song's bar grid. This includes tempo ramps, time
signature changes (each bar uses the pattern of its own signature, REQ-012) and loop wraps (a
click on the loop start plays right after the wrap). A seek shall not cause a missed or doubled
click.

- **Acceptance:** `cargo test`: (a) with 4/4 for bar 1 and 3/4 from bar 2, the bar-2 downbeat
  uses the 3/4 pattern; (b) a loop of bar 2 plays the bar-2 downbeat on every wrap; (c) a tempo
  ramp's clicks land on `frames_before_tick` of each beat tick.

### REQ-007: Heard, never exported

The audio engine shall add the metronome into the hardware output pair the master channel plays
on. The click comes after master's devices and fader. The engine shall delay it by the same output
latency as master, so it lines up with the audio. Offline renders (export) shall never contain the
click.

- **Acceptance:** `cargo test`: master fader at −inf still lets the click through on the output; a
  render of a range with the metronome enabled is bit-identical to one with it disabled.

### REQ-008: No dropouts

Enabling, disabling or reconfiguring the metronome while playing shall not glitch the audio
engine's output. This covers pattern edits, sound changes and parameter moves.

- **Acceptance:** live: drag knobs and paint steps during playback with `/engine/load` visible.
  There are no xruns and no clicks other than the scheduled ones.

### Step grid

### REQ-010: Grid shape

The step grid shall show one bar of the time signature at the playhead, split into steps of the
chosen resolution. Steps shall be grouped visually by beat (the signature's denominator).

- **Example:** 4/4 at 1/8 → 8 steps in 4 groups of 2; 7/8 at 1/8 → 7 steps; 6/8 at 1/16 → 12 steps.
- **Acceptance:** Godot model test computes the step count and grouping for the three examples.

### REQ-011: Resolution choice

The popup shall offer resolutions 1/4, 1/8 and 1/16, except any resolution coarser than the
signature's beat (1/4 is not offered in 7/8). Each pattern stores its own resolution.

- **Acceptance:** Godot model test: 7/8 offers 1/8 and 1/16 only.

### REQ-012: One pattern per signature

The project shall keep one pattern per time signature. Editing the grid shall change only the
pattern of the signature shown. A signature that has never been edited shall use the default
pattern (REQ-013).

- **Acceptance:** Godot model test: editing the 4/4 pattern leaves 3/4 at the default; the engine
  test from REQ-006(a) proves the engine picks per bar.

### REQ-013: Default pattern

A signature with no edited pattern shall play at beat resolution with level 4 on the first beat
and level 2 on every other beat.

- **Example:** 4/4 → `[4, 2, 2, 2]`; 6/8 → `[4, 2, 2, 2, 2, 2]`.
- **Acceptance:** Godot model test and engine unit test agree on both examples.

### REQ-014: Editing steps and colours

The step grid shall let the user set each step to Off or to levels 1 to 4. The design picks the
gesture. Each level shall be drawn in its own colour from the UI theme, and Off as an empty cell.
While playing, the step under the playhead shall be highlighted. A "Reset" button shall return
the current signature's pattern to the default.

- **Acceptance:** Godot test: setting step 2 to level 3 updates the model and sends the pattern;
  Reset restores REQ-013; colours come from four distinct theme entries.

### Sound

### REQ-020: Sound choice

The popup shall offer two sounds: **Beep**, a short tonal sine blip, and **Wood**, a short tonal
knock. Both shall be built on the engine's existing drum instruments.

- **Acceptance:** live: both sounds are clearly distinct, short and click-like at default settings.

### REQ-021: Sound knobs

The popup shall offer knobs for **Tune** (pitch of the level-4 click), **Decay**, **Tone**
(attack brightness/click amount) and **Level** (−60 to +6 dB, default −6 dB). Changes shall apply
from the next click.

- **Acceptance:** `cargo test`: each knob changes the rendered click; Level −60 dB gives
  near-silence (< −55 dBFS peak).

### REQ-022: Emphasis → volume

The popup shall offer an **Emphasis Volume** knob, 0–24 dB, default 12 dB. A level-4 click shall
play at Level. Lower levels shall play quieter, by the knob's amount times `(4 − level) / 3`.

- **Example:** 12 dB → levels 4/3/2/1 at 0/−4/−8/−12 dB relative to Level.
- **Acceptance:** `cargo test`: the peak ratio between a level-1 and a level-4 click matches −12 dB
  ±0.5 dB at the default.

### REQ-023: Emphasis → pitch

The popup shall offer an **Emphasis Pitch** knob, 0–24 semitones, default 7. A level-4 click shall
sound at Tune. Lower levels shall sound lower by `round(amount × (4 − level) / 3)` semitones.

- **Example:** 7 st → levels 4/3/2/1 at 0/−2/−5/−7 st.
- **Acceptance:** `cargo test`: the fundamental of a level-1 click at 0 st and at 12 st differ by
  an octave, measured by zero-crossing rate on a Beep click.

### REQ-024: Live audition

WHEN the user changes a sound knob, the sound choice or a step's level while the transport is
stopped, the audio engine shall play one preview click at level 4, or at the edited step's level,
so the change can be heard. Previews shall be rate-limited to one per 150 ms.

- **Acceptance:** live: turning Tune while stopped plays spaced preview clicks; painting a step
  plays it at its level.

### Persistence

### REQ-030: Global on/off and sound

The metronome's enabled state, sound choice and the six knob values (Tune, Decay, Tone, Level,
Emphasis Volume, Emphasis Pitch) shall be user settings. They persist across sessions and are the
same in every project.

- **Acceptance:** Godot test (test mode config): set values, reload the settings, values are
  restored; defaults match REQ-021 to REQ-023.

### REQ-031: Patterns in the project

The project file shall store the edited patterns, keyed by signature, each with its resolution and
step levels. Saving and reloading a project shall restore them. Undo and redo shall cover pattern
edits.

- **Acceptance:** Godot test: round-trip a project with a 4/4 and a 7/8 pattern through
  `to_dict`/`from_dict`; undo of a step edit restores the previous level.

### REQ-032: Engine sync

WHEN the UI connects to an engine, or loads a project, the UI shall send the full metronome state
(settings and every pattern) to the engine.

- **Acceptance:** Godot test: `sync_to_engine()` emits the metronome messages; live: restart the
  engine with the UI open, and the click comes back with the same pattern and sound.

## Non-functional

- **Real-time safety:** the audio callback shall not allocate, block or lock to play the
  metronome. Pattern and parameter updates reach it through the existing command path. A pattern
  update replaces a preallocated table; no `Vec` grows on the callback.
- **Latency / performance:** an idle metronome (disabled, or no click sounding) costs nothing
  measurable. A sounding click costs no more than one drum instrument.
- **Compatibility:** projects saved before this spec load with default patterns. An engine
  without the metronome ignores the new OSC addresses. An older engine already logs unknown routes
  harmlessly.

## Out of scope

- Count-in / pre-roll before playback or recording.
- "Only while recording" mode. The engine has no recording state yet.
- A separate cue/headphone output pair for the click (option kept for later).
- Hat- and Clap-based sounds. Neither keytracks, so emphasis→pitch would need new voice work.
- Per-step pitch or sound overrides beyond the four emphasis levels.
- Fractional-semitone emphasis pitch.
- A metronome lane in the arranger, or showing clicks in the clip editor.

## Open questions

- [ ] Should the existing tracklist-header metronome icon (it toggles the beats ruler) get a
  different icon, so it isn't confused with the new transport toggle? Proposed: switch it to a
  ruler/bars icon in this spec.
