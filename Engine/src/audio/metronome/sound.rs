//! Metronome sound mapping (spec 053): the real-valued knobs the UI sends, turned into
//! parameters of a Kick (Beep) or Snare (Wood) drum host, and the per-level note and velocity.
//!
//! Both hosts run with Keytrack on and Velocity at 100 %, so a hit's velocity `v` gives exactly
//! the gain `v^2` and its note shifts the pitch by whole semitones (sample-accurate, no
//! parameter change between clicks). Tune is reached as a base note plus a voice Tune inside the
//! voice's own range.
//!
//! The drum host soft-clips its mix before the Output gain, which would squash a full-velocity
//! click by about 2 dB and make the emphasis steps uneven. So a level-4 click plays at a reduced
//! velocity (`headroom_db` below full scale, where the soft clip is near linear) and the host's
//! Output is raised by the same amount: the Level knob is `Output - headroom`.

use crate::audio::devices::instruments::drums::params::{HUMANIZE, OUTPUT, VELOCITY};
use crate::audio::devices::instruments::drums::{kick, snare, DrumVoice, GLOBAL_SPECS};
use crate::audio::devices::param_table::{Kind, ParamSpec};
use crate::audio::devices::{AudioDevice, ParamId};

/// Which drum voice plays the click.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SoundKind {
    /// A short tonal sine blip (Kick voice).
    Beep,
    /// A short tonal knock (Snare voice).
    Wood,
}

impl SoundKind {
    /// The `i` argument of `/metronome/sound`: 0 Beep, 1 Wood (anything else is Beep).
    pub fn from_index(index: i32) -> Self {
        if index == 1 {
            SoundKind::Wood
        } else {
            SoundKind::Beep
        }
    }

    pub fn index(self) -> usize {
        match self {
            SoundKind::Beep => 0,
            SoundKind::Wood => 1,
        }
    }

    /// The built-in drum this sound is made on.
    pub fn device_id(self) -> &'static str {
        match self {
            SoundKind::Beep => "sonara.builtin.kick",
            SoundKind::Wood => "sonara.builtin.snare",
        }
    }

    fn specs(self) -> &'static [ParamSpec] {
        match self {
            SoundKind::Beep => kick::KickVoice::specs(),
            SoundKind::Wood => snare::SnareVoice::specs(),
        }
    }

    /// The note on which the voice plays exactly its Tune with Keytrack on.
    fn root_note(self) -> u8 {
        match self {
            SoundKind::Beep => kick::KEYTRACK_ROOT,
            SoundKind::Wood => snare::KEYTRACK_ROOT,
        }
    }
}

// Beep preset (Kick): a plain sine with no pitch sweep, shape, drive or noise.
const BEEP_PUNCH_ST: f32 = 0.0;
const BEEP_SHAPE_PCT: f32 = 0.0;
const BEEP_DRIVE_DB: f32 = 0.0;
const BEEP_NOISE_PCT: f32 = 0.0;

// Wood preset (Snare): no wires, a small pitch drop, a little overtone.
const WOOD_SNAPPY_PCT: f32 = 0.0;
const WOOD_PUNCH_ST: f32 = 1.0;
const WOOD_OVERTONE_PCT: f32 = 30.0;
const WOOD_DRIVE_DB: f32 = 0.0;

/// The metronome's sound as the UI sends it, in real units. `clamped` keeps every value inside
/// the knob's range.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MetronomeSound {
    pub kind: SoundKind,
    /// Pitch of the level-4 click, Hz.
    pub tune_hz: f32,
    /// Decay, seconds.
    pub decay_s: f32,
    /// Attack brightness / click amount, 0 to 1.
    pub tone: f32,
    /// Level of a level-4 click, dB.
    pub level_db: f32,
    /// How much quieter level 1 is than level 4, dB.
    pub emphasis_volume_db: f32,
    /// How much lower level 1 sounds than level 4, semitones.
    pub emphasis_pitch_st: f32,
}

impl Default for MetronomeSound {
    fn default() -> Self {
        Self {
            kind: SoundKind::Beep,
            tune_hz: 1000.0,
            decay_s: 0.06,
            tone: 0.5,
            level_db: -6.0,
            emphasis_volume_db: 12.0,
            emphasis_pitch_st: 7.0,
        }
    }
}

impl MetronomeSound {
    /// Every value clamped to its knob's range; a non-finite one becomes the default.
    pub fn clamped(self) -> Self {
        let d = Self::default();
        let fix = |v: f32, default: f32, lo: f32, hi: f32| {
            if v.is_finite() {
                v.clamp(lo, hi)
            } else {
                default
            }
        };
        Self {
            kind: self.kind,
            tune_hz: fix(self.tune_hz, d.tune_hz, 200.0, 4000.0),
            decay_s: fix(self.decay_s, d.decay_s, 0.02, 0.5),
            tone: fix(self.tone, d.tone, 0.0, 1.0),
            level_db: fix(self.level_db, d.level_db, -60.0, 6.0),
            emphasis_volume_db: fix(self.emphasis_volume_db, d.emphasis_volume_db, 0.0, 24.0),
            emphasis_pitch_st: fix(self.emphasis_pitch_st, d.emphasis_pitch_st, 0.0, 24.0),
        }
    }
}

/// The most a level-4 click is turned down in velocity (and the host's Output turned up) to keep
/// the host's soft clip near linear.
const MAX_HEADROOM_DB: f32 = 18.0;
/// The host's Output knob tops out here.
const OUTPUT_MAX_DB: f32 = 12.0;

/// How far below full velocity a level-4 click plays for `level_db`: as much as the Output knob
/// can make up for, up to [`MAX_HEADROOM_DB`].
pub fn headroom_db(level_db: f32) -> f32 {
    (OUTPUT_MAX_DB - level_db).clamp(0.0, MAX_HEADROOM_DB)
}

fn spec_of(specs: &'static [ParamSpec], id: ParamId) -> Option<&'static ParamSpec> {
    specs.iter().find(|s| s.id == id)
}

/// Set a parameter from its real value, through the voice's own table.
fn set_real(host: &mut dyn AudioDevice, specs: &'static [ParamSpec], id: ParamId, real: f32) {
    if let Some(spec) = spec_of(specs, id) {
        host.set_parameter(id, spec.to_norm(real));
    }
}

/// Configure `host` (a drum host of `kind`'s voice) for `sound` and return the base note: the
/// note a level-4 click plays. Command thread (the host's `set_parameter` is O(1), but the
/// metronome calls this under the state lock, never from the callback).
pub fn apply(host: &mut dyn AudioDevice, kind: SoundKind, sound: &MetronomeSound) -> u8 {
    let sound = sound.clamped();
    let specs = kind.specs();
    let tone_pct = sound.tone * 100.0;
    match kind {
        SoundKind::Beep => {
            set_real(host, specs, kick::PUNCH, BEEP_PUNCH_ST);
            set_real(host, specs, kick::SHAPE, BEEP_SHAPE_PCT);
            set_real(host, specs, kick::DRIVE, BEEP_DRIVE_DB);
            set_real(host, specs, kick::NOISE, BEEP_NOISE_PCT);
            set_real(host, specs, kick::DECAY, sound.decay_s);
            set_real(host, specs, kick::CLICK, tone_pct);
            set_real(host, specs, kick::KEYTRACK, 1.0);
        }
        SoundKind::Wood => {
            set_real(host, specs, snare::SNAPPY, WOOD_SNAPPY_PCT);
            set_real(host, specs, snare::PUNCH, WOOD_PUNCH_ST);
            set_real(host, specs, snare::OVERTONE, WOOD_OVERTONE_PCT);
            set_real(host, specs, snare::DRIVE, WOOD_DRIVE_DB);
            set_real(host, specs, snare::DECAY, sound.decay_s);
            set_real(host, specs, snare::SNAP, tone_pct);
            set_real(host, specs, snare::KEYTRACK, 1.0);
        }
    }
    // The shared block: velocity follows `v^2` exactly, no humanize, Output is the Level knob.
    set_real(host, &GLOBAL_SPECS, VELOCITY, 100.0);
    set_real(host, &GLOBAL_SPECS, HUMANIZE, 0.0);
    set_real(
        host,
        &GLOBAL_SPECS,
        OUTPUT,
        sound.level_db + headroom_db(sound.level_db),
    );

    // Tune: base note = root + ceil(12 log2(tune / voice max)), voice Tune = tune / 2^(shift/12).
    let tune_id = match kind {
        SoundKind::Beep => kick::TUNE,
        SoundKind::Wood => snare::TUNE,
    };
    let voice_max = match spec_of(specs, tune_id).map(|s| s.kind) {
        Some(Kind::Float { max, .. }) => max,
        _ => 200.0,
    };
    let root = kind.root_note() as i32;
    let shift = (12.0 * (sound.tune_hz / voice_max).log2()).ceil() as i32;
    let base_note = (root + shift).clamp(0, 127);
    let shift = base_note - root;
    let voice_hz = sound.tune_hz / 2f32.powf(shift as f32 / 12.0);
    set_real(host, specs, tune_id, voice_hz);
    base_note as u8
}

/// The note a click of `level` (1 to 4) plays: `round(pitch_st * (4 - level) / 3)` semitones
/// below the base note.
pub fn note_for_level(base_note: u8, emphasis_pitch_st: f32, level: u8) -> u8 {
    let missing = 4 - level.clamp(1, 4) as i32;
    let drop = (emphasis_pitch_st * missing as f32 / 3.0).round() as i32;
    (base_note as i32 - drop).clamp(0, 127) as u8
}

/// The velocity of a click of `level` (1 to 4). With the host's Velocity at 100 % the gain is
/// `v^2`: [`headroom_db`] below full scale for level 4 (the host's Output makes it up), and
/// `emphasis_volume_db * (4 - level) / 3` dB further down for the lower levels.
pub fn velocity_for_level(sound: &MetronomeSound, level: u8) -> f32 {
    let missing = 4 - level.clamp(1, 4) as i32;
    let down_db = sound.emphasis_volume_db * missing as f32 / 3.0;
    10f32
        .powf(-(headroom_db(sound.level_db) + down_db) / 20.0)
        .sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::create_drum;
    use crate::audio::midi_types::NoteEvent;

    const SR: f32 = 48_000.0;

    fn host(kind: SoundKind) -> Box<dyn AudioDevice> {
        create_drum(kind.device_id(), SR, 512).expect("built-in drum")
    }

    /// Render one click of `level` on a fresh host configured for `sound`; the left channel.
    fn click(sound: &MetronomeSound, level: u8, frames: usize) -> Vec<f32> {
        let mut host = host(sound.kind);
        let base = apply(host.as_mut(), sound.kind, sound);
        // Let the Output smoother reach its target before the hit.
        let mut idle = vec![0.0f32; 512 * 2];
        for _ in 0..40 {
            host.process_block(&[], &mut idle, 512);
        }
        host.reset();
        let note = note_for_level(base, sound.emphasis_pitch_st, level);
        let velocity = velocity_for_level(sound, level);
        host.send_note_event(
            &NoteEvent::On {
                note_id: 1,
                key: note,
                velocity,
            },
            0,
        );
        let mut out = Vec::with_capacity(frames);
        let mut block = vec![0.0f32; 512 * 2];
        while out.len() < frames {
            let n = (frames - out.len()).min(512);
            host.process_block(&[], &mut block, n);
            out.extend((0..n).map(|i| block[i * 2]));
        }
        out
    }

    fn peak(samples: &[f32]) -> f32 {
        samples.iter().fold(0.0f32, |m, s| m.max(s.abs()))
    }

    fn db(x: f32) -> f32 {
        20.0 * x.log10()
    }

    fn zero_crossings(samples: &[f32]) -> usize {
        samples
            .windows(2)
            .filter(|w| (w[0] < 0.0) != (w[1] < 0.0))
            .count()
    }

    #[test]
    fn clamps_and_defaults() {
        let s = MetronomeSound {
            tune_hz: 99_999.0,
            decay_s: -1.0,
            tone: f32::NAN,
            level_db: 99.0,
            emphasis_volume_db: -3.0,
            emphasis_pitch_st: 1000.0,
            ..MetronomeSound::default()
        }
        .clamped();
        assert_eq!(
            (s.tune_hz, s.decay_s, s.tone, s.level_db),
            (4000.0, 0.02, 0.5, 6.0)
        );
        assert_eq!((s.emphasis_volume_db, s.emphasis_pitch_st), (0.0, 24.0));
        assert_eq!(SoundKind::from_index(1), SoundKind::Wood);
        assert_eq!(SoundKind::from_index(0), SoundKind::Beep);
        assert_eq!(SoundKind::from_index(7), SoundKind::Beep);
    }

    #[test]
    fn level_maths_matches_the_requirement_examples() {
        // 12 dB: levels 4/3/2/1 at 0/-4/-8/-12 dB relative to level 4.
        let sound = MetronomeSound::default();
        let top = velocity_for_level(&sound, 4);
        for (level, db_down) in [(4u8, 0.0f32), (3, -4.0), (2, -8.0), (1, -12.0)] {
            let v = velocity_for_level(&sound, level);
            assert!(
                (db(v * v / (top * top)) - db_down).abs() < 1e-3,
                "level {level}"
            );
        }
        // The headroom plus Output is the Level knob: -6 dB with the default 18 dB of headroom.
        assert_eq!(headroom_db(-6.0), 18.0);
        assert_eq!(headroom_db(6.0), 6.0);
        assert_eq!(headroom_db(-60.0), 18.0);
        assert!((db(top * top) + headroom_db(-6.0)).abs() < 1e-3);
        // 7 st: levels 4/3/2/1 at 0/-2/-5/-7 st.
        let notes: Vec<u8> = (1..=4).rev().map(|l| note_for_level(80, 7.0, l)).collect();
        assert_eq!(notes, vec![80, 78, 75, 73]);
        assert_eq!(note_for_level(5, 24.0, 1), 0, "clamped at the bottom");
    }

    #[test]
    fn base_note_maps_tune_exactly() {
        for kind in [SoundKind::Beep, SoundKind::Wood] {
            let specs = kind.specs();
            let (tune_id, root) = match kind {
                SoundKind::Beep => (kick::TUNE, kick::KEYTRACK_ROOT),
                SoundKind::Wood => (snare::TUNE, snare::KEYTRACK_ROOT),
            };
            let spec = spec_of(specs, tune_id).unwrap();
            let Kind::Float { min, max, .. } = spec.kind else {
                panic!("Tune is a float");
            };
            for tune_hz in [200.0f32, 1000.0, 4000.0] {
                let mut h = host(kind);
                let sound = MetronomeSound {
                    kind,
                    tune_hz,
                    ..MetronomeSound::default()
                };
                let base = apply(h.as_mut(), kind, &sound);
                let voice_hz = spec.to_real(h.get_parameter(tune_id).unwrap());
                assert!(
                    (min..=max * 1.0001).contains(&voice_hz),
                    "{kind:?} {tune_hz}: voice Tune {voice_hz} outside {min}..{max}"
                );
                let played = voice_hz * 2f32.powf((base as f32 - root as f32) / 12.0);
                assert!(
                    (played - tune_hz).abs() / tune_hz < 1e-3,
                    "{kind:?}: {tune_hz} Hz played as {played} Hz"
                );
            }
        }
    }

    #[test]
    fn emphasis_volume_ratio() {
        for kind in [SoundKind::Beep, SoundKind::Wood] {
            let sound = MetronomeSound {
                kind,
                ..MetronomeSound::default()
            };
            let loud = peak(&click(&sound, 4, 4800));
            let soft = peak(&click(&sound, 1, 4800));
            let ratio = db(soft / loud);
            assert!(
                (ratio + 12.0).abs() < 0.5,
                "{kind:?}: level 1 is {ratio} dB from level 4"
            );
        }
    }

    #[test]
    fn emphasis_pitch_octave() {
        let measure = |pitch_st: f32| {
            let sound = MetronomeSound {
                decay_s: 0.5,
                emphasis_pitch_st: pitch_st,
                ..MetronomeSound::default()
            };
            // Past the click transient, in the body's tail.
            let samples = click(&sound, 1, 4800);
            zero_crossings(&samples[960..3840]) as f32
        };
        let flat = measure(0.0);
        let octave = measure(12.0);
        let ratio = flat / octave;
        assert!((ratio - 2.0).abs() < 0.1, "zero-crossing ratio {ratio}");
    }

    #[test]
    fn level_floor() {
        for kind in [SoundKind::Beep, SoundKind::Wood] {
            let sound = MetronomeSound {
                kind,
                level_db: -60.0,
                ..MetronomeSound::default()
            };
            let p = db(peak(&click(&sound, 4, 4800)));
            assert!(p < -55.0, "{kind:?}: {p} dBFS at -60 dB");
        }
    }

    #[test]
    fn each_knob_changes_the_click() {
        let base = MetronomeSound::default();
        let reference = click(&base, 4, 4800);
        for (name, sound) in [
            (
                "tune",
                MetronomeSound {
                    tune_hz: 2000.0,
                    ..base
                },
            ),
            (
                "decay",
                MetronomeSound {
                    decay_s: 0.3,
                    ..base
                },
            ),
            ("tone", MetronomeSound { tone: 1.0, ..base }),
            (
                "level",
                MetronomeSound {
                    level_db: -20.0,
                    ..base
                },
            ),
            (
                "kind",
                MetronomeSound {
                    kind: SoundKind::Wood,
                    ..base
                },
            ),
        ] {
            let other = click(&sound, 4, 4800);
            assert_ne!(other, reference, "{name} changes the rendered click");
        }
    }
}
