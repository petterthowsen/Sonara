//! Kick drum (spec 013, Phase 1).
//!
//! Three layers are summed: a swept-sine **Body**, a short **Click** transient and a filtered
//! **Noise** layer. The Body is driven by [`DriveStage`] after its amplitude envelope; a
//! [`DcBlocker`] cleans the sum, since the body's start phase and the drive both introduce DC.
//!
//! The controls are musical rather than per-layer: **Punch** is the pitch drop at the start of
//! the hit, **Click** sets the click layer and, over its upper half, how hard the body starts
//! (its start phase, 0° at 50 % up to 90° at 100 %), and the Noise layer's decay follows the
//! body's Decay.
//!
//! Tuning: **Tune** is always the pitch you hear on the reference note C1 (MIDI 36). With
//! **Keytrack** on, other notes transpose from there, so the knob means the same in both modes.
//!
//! **Gate** mode makes the amplitude envelope sustain while the note is held and release on
//! note-off (an 808 bass), and **Glide** (Gate + Keytrack only) slides the pitch exponentially to
//! the next note over the Glide time.

use super::layers::{ClickLayer, ClickType, DriveStage};
use super::{DrumParams, DrumVoice, GLOBAL_SPECS};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::ParamId;
use crate::audio::dsp::gain::DcBlocker;
use crate::audio::dsp::svf::{compensation_coef, cutoff_to_g, resonance_to_k};
use crate::audio::dsp::{
    sweep_hz, FilterMode, OneShotEnvelope, PinkNoise, Rng, Svf, SvfCoefs, SweepOsc, SweepShape,
};

// Parameter IDs, grouped in tens by module.
const TUNE: ParamId = 0;
const DECAY: ParamId = 1;
const SHAPE: ParamId = 2;
const DRIVE: ParamId = 3;
const KEYTRACK: ParamId = 4;
const PUNCH: ParamId = 10;
const PUNCH_TIME: ParamId = 11;
const CLICK: ParamId = 20;
const CLICK_TONE: ParamId = 21;
const CLICK_TYPE: ParamId = 22;
const NOISE: ParamId = 30;
const NOISE_TONE: ParamId = 31;
const GATE: ParamId = 40;
const RELEASE: ParamId = 41;
const GLIDE: ParamId = 42;

/// Kick module (IDs 0–9): the drum itself.
const KICK: [ParamSpec; 5] = [
    spec(TUNE, "Tune", "Kick", "Hz", log(20.0, 200.0), 41.2),
    spec(DECAY, "Decay", "Kick", "s", log(0.03, 3.0), 0.4),
    spec(SHAPE, "Shape", "Kick", "%", linear(-100.0, 100.0), 0.0),
    spec(DRIVE, "Drive", "Kick", "dB", linear(0.0, 24.0), 0.0),
    spec(KEYTRACK, "Keytrack", "Kick", "", Kind::Bool, 0.0),
];

/// Punch module (IDs 10–19): the pitch drop.
const PUNCH_SPECS: [ParamSpec; 2] = [
    spec(PUNCH, "Punch", "Punch", "st", linear(0.0, 48.0), 24.0),
    spec(
        PUNCH_TIME,
        "Punch Time",
        "Punch",
        "s",
        log(0.005, 0.2),
        0.04,
    ),
];

/// Click module (IDs 20–29).
const CLICK_TYPES: &[&str] = &["Noise", "Tick"];
const CLICK_SPECS: [ParamSpec; 3] = [
    spec(CLICK, "Click", "Click", "%", linear(0.0, 100.0), 30.0),
    spec(
        CLICK_TONE,
        "Click Tone",
        "Click",
        "Hz",
        log(1000.0, 8000.0),
        3000.0,
    ),
    spec(
        CLICK_TYPE,
        "Click Type",
        "Click",
        "",
        Kind::Enum(CLICK_TYPES),
        0.0,
    ),
];

/// Noise module (IDs 30–39).
const NOISE_SPECS: [ParamSpec; 2] = [
    spec(NOISE, "Noise", "Noise", "%", linear(0.0, 100.0), 0.0),
    spec(
        NOISE_TONE,
        "Noise Tone",
        "Noise",
        "Hz",
        log(200.0, 12000.0),
        4000.0,
    ),
];

/// 808 module (IDs 40–49): sustained, gliding bass kicks.
const MODE_808: [ParamSpec; 3] = [
    spec(GATE, "Gate", "808", "", Kind::Bool, 0.0),
    spec(RELEASE, "Release", "808", "s", log(0.01, 2.0), 0.2),
    spec(GLIDE, "Glide", "808", "s", linear(0.0, 0.5), 0.0),
];

const SPECS: [ParamSpec; 18] = flatten(&[
    &KICK,
    &PUNCH_SPECS,
    &CLICK_SPECS,
    &NOISE_SPECS,
    &MODE_808,
    &GLOBAL_SPECS,
]);
/// ID → slot lookup. `100` is above the highest ID (92, the last global).
const SLOTS: [u8; 100] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// With Keytrack on, this note plays exactly Tune (C1, the GM kick note).
const KEYTRACK_ROOT: u8 = 36;
/// The Noise layer decays this fraction of the body's Decay.
const NOISE_DECAY_RATIO: f32 = 0.2;
/// Body start phase at full Click: a sine starting at its peak is the hardest attack.
const MAX_START_PHASE: f32 = 90.0;
/// Click above this amount also hardens the body's start; below it the body starts at 0°.
const START_PHASE_FROM: f32 = 0.5;
/// Fixed resonance of the Noise layer's band-pass.
const NOISE_RESONANCE: f32 = 0.4;
/// Body frames processed per inner chunk, so the drive stage never needs a block-sized buffer.
const BODY_CHUNK: usize = 32;
/// The DC blocker's cutoff: low enough to leave the kick's own sub-bass alone.
const DC_HZ: f32 = 5.0;

/// The synthesized kick voice.
pub struct KickVoice {
    values: ParamValues<18>,
    params: DrumParams,
    sample_rate: f32,

    // Body.
    body_osc: SweepOsc,
    pitch_env: OneShotEnvelope,
    amp_env: OneShotEnvelope,
    drive: DriveStage,
    body_scratch: [f32; BODY_CHUNK],

    // Click.
    click: ClickLayer,

    // Noise.
    noise: PinkNoise,
    noise_filter: Svf,
    noise_coefs: SvfCoefs,
    noise_comp: f32,
    noise_env: OneShotEnvelope,

    // Output.
    dc: DcBlocker,

    // Decoded parameters (refreshed in `sync`, off the per-sample path).
    tune_hz: f32,
    keytrack: bool,
    body_decay: f32,
    body_curve: f32,
    start_phase: f32,
    drive_db: f32,
    sweep_st: f32,
    sweep_time: f32,
    click_level: f32,
    click_tone: f32,
    click_type: ClickType,
    noise_level: f32,
    noise_decay: f32,
    noise_color: f32,
    gate: bool,
    release_s: f32,
    glide_s: f32,

    // Per-hit state.
    hit_base: f32,
    hit_sweep_st: f32,
    hit_click_level: f32,
    /// The base of this voice's previous hit, kept across `reset` so Glide can span retriggers.
    last_base: Option<f32>,
    glide_pos: f32,
    glide_total: f32,
    glide_st: f32,
}

impl KickVoice {
    /// Recompute every decoded parameter and hand it to the DSP. Off the per-sample path.
    fn sync(&mut self) {
        self.tune_hz = self.values.real(TUNE).unwrap_or(41.2);
        self.keytrack = self.values.real(KEYTRACK).unwrap_or(0.0) >= 0.5;
        self.body_decay = self.values.real(DECAY).unwrap_or(0.4);
        self.body_curve = self.values.real(SHAPE).unwrap_or(0.0) / 100.0;
        self.drive_db = self.values.real(DRIVE).unwrap_or(0.0);
        self.sweep_st = self.values.real(PUNCH).unwrap_or(24.0);
        self.sweep_time = self.values.real(PUNCH_TIME).unwrap_or(0.04);
        self.click_level = self.values.real(CLICK).unwrap_or(30.0) / 100.0;
        self.click_tone = self.values.real(CLICK_TONE).unwrap_or(3_000.0);
        self.click_type = if self.values.real(CLICK_TYPE).unwrap_or(0.0) >= 0.5 {
            ClickType::Tick
        } else {
            ClickType::Noise
        };
        self.noise_level = self.values.real(NOISE).unwrap_or(0.0) / 100.0;
        self.noise_color = self.values.real(NOISE_TONE).unwrap_or(4_000.0);
        self.gate = self.values.real(GATE).unwrap_or(0.0) >= 0.5;
        self.release_s = self.values.real(RELEASE).unwrap_or(0.2);
        self.glide_s = self.values.real(GLIDE).unwrap_or(0.0);
        // Click is the whole attack: the click layer, plus (over its upper half) how hard the
        // body starts.
        let hardness = ((self.click_level - START_PHASE_FROM) / (1.0 - START_PHASE_FROM)).max(0.0);
        self.start_phase = MAX_START_PHASE * hardness;
        self.noise_decay = (self.body_decay * NOISE_DECAY_RATIO).clamp(0.01, 1.0);

        self.pitch_env.set_decay(self.sweep_time);
        self.pitch_env.set_curve(0.0);
        self.amp_env.set_attack(0.0);
        self.amp_env.set_decay(self.body_decay);
        self.amp_env.set_curve(self.body_curve);
        self.amp_env.set_release(self.release_s);
        self.amp_env.set_gated(self.gate);

        // The click is shorter at a higher tone; the Tick is a fixed 2 ms sine.
        let tone_norm = self.values.effective_norm(CLICK_TONE).unwrap_or(0.0);
        let click_decay = match self.click_type {
            ClickType::Noise => 0.010 - 0.008 * tone_norm,
            ClickType::Tick => 0.002,
        };
        self.click.set_type(self.click_type);
        self.click.set_tone(self.click_tone, click_decay);

        self.noise_env.set_decay(self.noise_decay);
        self.noise_env.set_curve(0.0);
        self.update_noise_filter();
        self.drive.set_drive_db(self.drive_db);
        self.body_osc.set_start_phase_deg(self.start_phase);
    }

    /// Re-derive the noise band-pass coefficients (cutoff is static within a hit).
    fn update_noise_filter(&mut self) {
        let k = resonance_to_k(NOISE_RESONANCE, FilterMode::Bp12);
        self.noise_coefs = SvfCoefs::new(
            cutoff_to_g(self.noise_color, self.sample_rate),
            k,
            FilterMode::Bp12,
        );
        self.noise_comp = compensation_coef(self.noise_color, self.sample_rate);
    }
}

impl DrumVoice for KickVoice {
    fn new(sample_rate: f32) -> Self {
        let sample_rate = sample_rate.max(1.0);
        let mut voice = Self {
            values: ParamValues::new(&TABLE),
            params: DrumParams::default(),
            sample_rate,
            body_osc: SweepOsc::new(),
            pitch_env: OneShotEnvelope::new(sample_rate),
            amp_env: OneShotEnvelope::new(sample_rate),
            drive: DriveStage::new(),
            body_scratch: [0.0; BODY_CHUNK],
            click: ClickLayer::new(sample_rate, 0x10c3_0001),
            noise: PinkNoise::new(0x10c3_0002),
            noise_filter: Svf::new(),
            noise_coefs: SvfCoefs::default(),
            noise_comp: 0.0,
            noise_env: OneShotEnvelope::new(sample_rate),
            dc: DcBlocker::new(DC_HZ, sample_rate),
            tune_hz: 41.2,
            keytrack: false,
            body_decay: 0.4,
            body_curve: 0.0,
            start_phase: 0.0,
            drive_db: 0.0,
            sweep_st: 24.0,
            sweep_time: 0.04,
            click_level: 0.3,
            click_tone: 3_000.0,
            click_type: ClickType::Noise,
            noise_level: 0.0,
            noise_decay: 0.08,
            noise_color: 4_000.0,
            gate: false,
            release_s: 0.2,
            glide_s: 0.0,
            hit_base: 41.2,
            hit_sweep_st: 24.0,
            hit_click_level: 0.3,
            last_base: None,
            glide_pos: 0.0,
            glide_total: 1.0,
            glide_st: 0.0,
        };
        voice.sync();
        voice
    }

    fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate.max(1.0);
        self.pitch_env.set_sample_rate(self.sample_rate);
        self.amp_env.set_sample_rate(self.sample_rate);
        self.noise_env.set_sample_rate(self.sample_rate);
        self.click.set_sample_rate(self.sample_rate);
        self.update_noise_filter();
        self.dc = DcBlocker::new(DC_HZ, self.sample_rate);
    }

    fn specs() -> &'static [ParamSpec] {
        &SPECS
    }

    fn set_parameter(&mut self, id: ParamId, norm: f32) {
        if self.values.set(id, norm).is_some() {
            self.sync();
        }
    }

    fn set_param_mod(&mut self, id: ParamId, offset: f32) {
        if self.values.set_offset(id, offset).is_some() {
            self.sync();
        }
    }

    fn get_parameter(&self, id: ParamId) -> Option<f32> {
        self.values.get(id)
    }

    fn set_params(&mut self, params: &DrumParams) {
        self.params = *params;
    }

    fn trigger(&mut self, note: u8, velocity: f32, rng: &mut Rng) {
        let v = velocity.clamp(0.0, 1.0);
        let sens = self.params.velocity_sens.clamp(0.0, 1.0);
        let humanize = self.params.humanize.clamp(0.0, 1.0);
        let cents = humanize * 10.0 * rng.bipolar();
        let decay_scale = 1.0 + humanize * 0.05 * rng.bipolar();

        // Tuning: Tune is the pitch of the root note; Keytrack transposes the other notes from it.
        let transpose = if self.keytrack {
            (note as f32 - KEYTRACK_ROOT as f32) / 12.0
        } else {
            0.0
        };
        let base = self.tune_hz * 2f32.powf(transpose + cents / 1200.0);

        // Glide (Gate + Keytrack only): slide exponentially from the previous hit's base.
        self.glide_pos = 0.0;
        if self.gate && self.keytrack && self.glide_s > 0.0 {
            if let Some(src) = self.last_base {
                if src > 0.0 && base > 0.0 {
                    self.glide_st = 12.0 * (src / base).log2();
                    self.glide_total = (self.glide_s * self.sample_rate).max(1.0);
                    self.glide_pos = self.glide_total;
                }
            }
        }
        self.last_base = Some(base);
        self.hit_base = base;

        // Velocity adds brightness, scaled by sensitivity: at sens 0 the hit is velocity-independent.
        let click_bright = 1.0 - sens * 0.5 * (1.0 - v);
        let sweep_bright = 1.0 - sens * 0.25 * (1.0 - v);
        self.hit_click_level = self.click_level * click_bright;
        self.hit_sweep_st = self.sweep_st * sweep_bright;

        self.amp_env
            .set_decay((self.body_decay * decay_scale).max(1.0e-4));

        self.body_osc.set_start_phase_deg(self.start_phase);
        self.body_osc.reset();
        self.pitch_env.trigger();
        self.amp_env.trigger();
        // A layer at Level 0 is left idle so it costs nothing (and doesn't keep the voice awake).
        if self.hit_click_level > 0.0 {
            self.click.trigger();
        }
        if self.noise_level > 0.0 {
            self.noise_env.trigger();
            self.noise_filter.reset();
        }
    }

    fn render(&mut self, out: &mut [f32]) {
        // Body: swept sine, amplitude envelope, then the drive stage. Skipped once both envelopes
        // are idle (they stay idle, so nothing is lost). The pitch sweep is skipped too when it
        // has decayed to zero, which drops two `exp2` per sample from the tail.
        if self.amp_env.is_active() || self.pitch_env.is_active() {
            for chunk in out.chunks_mut(BODY_CHUNK) {
                let n = chunk.len();
                for i in 0..n {
                    let pitch = self.pitch_env.process_sample();
                    let amp = self.amp_env.process_sample();
                    let base = if self.glide_pos > 0.0 {
                        let t = (self.glide_pos / self.glide_total).clamp(0.0, 1.0);
                        self.glide_pos -= 1.0;
                        sweep_hz(self.hit_base, self.glide_st, t)
                    } else {
                        self.hit_base
                    };
                    let hz = if pitch > 0.0 {
                        sweep_hz(base, self.hit_sweep_st, pitch)
                    } else {
                        base
                    };
                    self.body_scratch[i] =
                        self.body_osc.next(SweepShape::Sine, hz, self.sample_rate) * amp;
                }
                self.drive.process(&mut self.body_scratch[..n]);
                for i in 0..n {
                    chunk[i] += self.body_scratch[i];
                }
            }
        }

        // Click.
        self.click.render(out, self.hit_click_level);

        // Noise: pink → band-pass → its own decay.
        if self.noise_env.is_active() {
            for sample in out.iter_mut() {
                let env = self.noise_env.process_sample();
                let x = self.noise_filter.process(
                    self.noise.next(),
                    FilterMode::Bp12,
                    &self.noise_coefs,
                    self.noise_comp,
                    NOISE_RESONANCE,
                );
                *sample += x * env * self.noise_level;
            }
        }

        // A DC blocker on the sum: the 90° start phase and the drive both introduce DC.
        for sample in out.iter_mut() {
            *sample = self.dc.process(*sample);
        }
    }

    fn release(&mut self) {
        self.amp_env.gate_off();
    }

    fn is_active(&self) -> bool {
        self.amp_env.is_active() || self.click.is_active() || self.noise_env.is_active()
    }

    fn reset(&mut self) {
        self.pitch_env.reset();
        self.amp_env.reset();
        self.click.reset();
        self.noise_env.reset();
        self.noise_filter.reset();
        self.body_osc.reset();
        self.drive.reset();
        self.dc.reset();
        self.glide_pos = 0.0;
        self.hit_base = self.tune_hz;
        // `last_base` is deliberately kept: Glide spans retriggers through `reset`.
    }

    fn device_id() -> &'static str {
        "sonara.builtin.kick"
    }

    fn device_name() -> &'static str {
        "Kick"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::drums::host::DrumHost;
    use crate::audio::devices::AudioDevice;
    use crate::audio::dsp::test_util::{
        instantaneous_freq, left, peak, spectrum_db, time_to_db, to_db,
    };
    use crate::audio::midi_types::NoteEvent;

    const SR: f32 = 48_000.0;

    /// Frequency of a MIDI note, with A4 (69) = 440 Hz.
    fn note_hz(note: u8) -> f32 {
        440.0 * 2f32.powf((note as f32 - 69.0) / 12.0)
    }

    /// Set a parameter by its real value (via the spec's own scaling).
    fn set_real(voice: &mut KickVoice, id: ParamId, real: f32) {
        let spec = KickVoice::specs()
            .iter()
            .find(|s| s.id == id)
            .expect("parameter exists");
        voice.set_parameter(id, spec.to_norm(real));
    }

    /// A voice with the given velocity sensitivity and no humanize.
    fn voice(sens: f32) -> KickVoice {
        let mut v = KickVoice::new(SR);
        v.set_sample_rate(SR);
        v.set_params(&DrumParams {
            velocity_sens: sens,
            output_db: 0.0,
            humanize: 0.0,
        });
        v
    }

    /// Render `frames` mono samples in 512-frame blocks.
    fn render_voice(v: &mut KickVoice, frames: usize) -> Vec<f32> {
        let mut out = vec![0.0f32; frames];
        for chunk in out.chunks_mut(512) {
            chunk.fill(0.0);
            v.render(chunk);
        }
        out
    }

    /// Render `frames` stereo frames through a host, with one note-on at frame 0.
    fn render_host(host: &mut DrumHost<KickVoice>, frames: usize, note: u8, vel: u8) -> Vec<f32> {
        let mut out = vec![0.0f32; frames * 2];
        host.send_note_event(&NoteEvent::test_on(note, vel), 0);
        let mut done = 0;
        while done < frames {
            let n = (frames - done).min(512);
            let mut block = vec![0.0f32; n * 2];
            host.process_block(&[], &mut block, n);
            out[done * 2..(done + n) * 2].copy_from_slice(&block);
            done += n;
        }
        out
    }

    /// (a) The tail sits on the Tune frequency.
    #[test]
    fn tail_frequency_is_the_tune() {
        let mut v = voice(0.0);
        v.trigger(36, 1.0, &mut Rng::new(1));
        let sig = render_voice(&mut v, (0.5 * SR) as usize);
        let tail = &sig[(0.2 * SR) as usize..(0.35 * SR) as usize];
        let f = instantaneous_freq(tail, SR);
        assert!((f - 41.2).abs() / 41.2 < 0.01, "{f} Hz");
    }

    /// (b) The punch starts about four times higher (24 st) than the base.
    ///
    /// Measuring the "first 1 ms" with a zero-crossing estimator needs a base high enough to
    /// have cycles inside the window, so the test keys a high note (C6) and uses the longest
    /// Sweep Time (200 ms) to keep the pitch near-constant over the measured window.
    #[test]
    fn first_window_starts_a_fourth_higher() {
        let mut v = voice(0.0);
        set_real(&mut v, TUNE, note_hz(KEYTRACK_ROOT)); // the root plays its own note
        set_real(&mut v, KEYTRACK, 1.0);
        set_real(&mut v, PUNCH_TIME, 0.2); // 200 ms
        set_real(&mut v, CLICK, 0.0); // Click off, so only the body's pitch is measured
        set_real(&mut v, NOISE, 0.0);
        v.trigger(84, 1.0, &mut Rng::new(1));
        let sig = render_voice(&mut v, 4_800);

        let base = note_hz(84);
        let early = instantaneous_freq(&sig[..24], SR);
        let ratio = early / base;
        assert!((ratio - 4.0).abs() < 0.12, "ratio {ratio}");
    }

    /// (c) Keytrack: the root note (C1) plays Tune, and an octave up plays twice Tune.
    #[test]
    fn keytrack_transposes_from_tune_at_the_root() {
        let tail_hz = |note: u8| {
            let mut v = voice(0.0);
            set_real(&mut v, KEYTRACK, 1.0);
            v.trigger(note, 1.0, &mut Rng::new(1));
            let sig = render_voice(&mut v, (0.5 * SR) as usize);
            instantaneous_freq(&sig[(0.2 * SR) as usize..(0.35 * SR) as usize], SR)
        };
        let root = tail_hz(KEYTRACK_ROOT);
        assert!((root - 41.2).abs() / 41.2 < 0.01, "root {root} Hz");
        let octave = tail_hz(KEYTRACK_ROOT + 12);
        assert!((octave - 82.4).abs() / 82.4 < 0.01, "octave {octave} Hz");
    }

    /// (d) Curve 0 reaches −60 dB at the set decay time, within 5 %.
    #[test]
    fn body_decay_reaches_minus_60_db() {
        let mut v = voice(0.0);
        set_real(&mut v, NOISE, 0.0);
        set_real(&mut v, CLICK, 0.0);
        set_real(&mut v, PUNCH, 0.0); // no sweep: a steady tail
        set_real(&mut v, DECAY, 0.5); // 500 ms
        v.trigger(36, 1.0, &mut Rng::new(1));
        let sig = render_voice(&mut v, (1.2 * SR) as usize);
        let t = time_to_db(&sig, -60.0, SR);
        assert!((t - 0.5).abs() / 0.5 < 0.05, "{t} s");
    }

    /// (e) With velocity sensitivity 0 the voice ignores velocity entirely.
    #[test]
    fn zero_velocity_sensitivity_keeps_hits_identical() {
        let mut a = voice(0.0);
        a.trigger(36, 1.0 / 127.0, &mut Rng::new(1));
        let sa = render_voice(&mut a, 9_600);

        let mut b = voice(0.0);
        b.trigger(36, 127.0 / 127.0, &mut Rng::new(1));
        let sb = render_voice(&mut b, 9_600);

        assert!((peak(&sa) - peak(&sb)).abs() < 1e-9);
    }

    /// (e) At full sensitivity the host's velocity curve follows `v²`: halving the velocity
    /// is about −12 dB. Velocities 64 and 32 keep the peaks low enough that the host's
    /// `soft_clip` stays linear and does not skew the ratio.
    #[test]
    fn velocity_curve_scales_the_peak() {
        let make = |sens_norm: f32, vel: u8| {
            let mut host = DrumHost::<KickVoice>::new(SR, 4_096);
            host.prepare(SR, 4_096);
            host.set_parameter(90, sens_norm); // Velocity
            host.set_parameter(CLICK, 0.0);
            host.set_parameter(NOISE, 0.0);
            left(&render_host(&mut host, 2_048, 36, vel))
        };

        let quiet = peak(&make(0.0, 1));
        let loud = peak(&make(0.0, 127));
        assert!((quiet - loud).abs() < 1e-6, "{quiet} vs {loud}");

        let mid = peak(&make(1.0, 64));
        let soft = peak(&make(1.0, 32));
        let ratio_db = to_db(soft / mid);
        assert!((ratio_db + 12.0).abs() < 1.5, "{ratio_db} dB");
    }

    /// (f) The click's energy above 1 kHz is concentrated in the first 10 ms.
    #[test]
    fn click_energy_above_1khz_is_early() {
        // A short, low, unswept body: after the 1 kHz high-pass almost only the click remains.
        let mut v = voice(0.0);
        set_real(&mut v, TUNE, 20.0);
        set_real(&mut v, DECAY, 0.03);
        set_real(&mut v, PUNCH, 0.0);
        set_real(&mut v, NOISE, 0.0);
        set_real(&mut v, CLICK, 100.0);
        v.trigger(36, 1.0, &mut Rng::new(1));
        let sig = render_voice(&mut v, (0.1 * SR) as usize);

        let mut hp = Svf::new();
        let coefs = SvfCoefs::new(
            cutoff_to_g(1_000.0, SR),
            resonance_to_k(0.0, FilterMode::Hp12),
            FilterMode::Hp12,
        );
        let comp = compensation_coef(1_000.0, SR);
        let filtered: Vec<f32> = sig
            .iter()
            .map(|&x| hp.process(x, FilterMode::Hp12, &coefs, comp, 0.0))
            .collect();
        let early: f32 = filtered[..(0.010 * SR) as usize]
            .iter()
            .map(|x| x * x)
            .sum();
        let total: f32 = filtered.iter().map(|x| x * x).sum();
        assert!(early / total > 0.9, "ratio {}", early / total);
    }

    /// (g) With 24 dB of drive on a 197 Hz tune, nothing inharmonic rises above −60 dB of the
    /// fundamental (the 2× oversampler keeps the folded harmonics down).
    #[test]
    fn high_drive_does_not_alias() {
        let mut v = voice(0.0);
        set_real(&mut v, TUNE, 197.0);
        set_real(&mut v, DRIVE, 24.0);
        set_real(&mut v, PUNCH, 0.0); // no sweep
        set_real(&mut v, CLICK, 0.0);
        set_real(&mut v, NOISE, 0.0);
        set_real(&mut v, DECAY, 3.0); // long decay
        v.trigger(36, 1.0, &mut Rng::new(1));
        let sig = render_voice(&mut v, (1.5 * SR) as usize);

        let fft_len = 32_768;
        let start = (0.4 * SR) as usize;
        let window = &sig[start..start + fft_len];
        let db = spectrum_db(window);
        let bin_hz = SR / window.len() as f32;
        let peak_db = db.iter().cloned().fold(f32::MIN, f32::max);
        // Bins within this many Hz of a harmonic are the harmonic's own peak/leakage skirt.
        let excluded = 10.0 * bin_hz;
        let mut inharmonic = 0;
        for (bin, &level) in db.iter().enumerate().skip(1) {
            if level <= peak_db - 60.0 {
                continue;
            }
            let f = bin as f32 * bin_hz;
            let harmonic = (f / 197.0).round();
            if (f - harmonic * 197.0).abs() > excluded {
                inharmonic += 1;
            }
        }
        assert_eq!(inharmonic, 0, "{inharmonic} inharmonic bins above −60 dB");
    }

    /// (h) Gate mode sustains while held, then releases on note-off.
    #[test]
    fn gate_mode_holds_and_releases() {
        let mut v = voice(0.0);
        set_real(&mut v, GATE, 1.0);
        set_real(&mut v, CLICK, 0.0);
        set_real(&mut v, NOISE, 0.0);
        set_real(&mut v, RELEASE, 0.2); // 200 ms
        v.trigger(36, 1.0, &mut Rng::new(1));

        let held = render_voice(&mut v, (1.1 * SR) as usize);
        let at_one_second = &held[(0.95 * SR) as usize..(1.0 * SR) as usize];
        assert!(
            to_db(peak(at_one_second)) > -6.0,
            "{} dB",
            to_db(peak(at_one_second))
        );
        assert!(v.is_active());

        v.release();
        let after = render_voice(&mut v, (0.5 * SR) as usize);
        assert!(to_db(peak(&after[(0.4 * SR) as usize..])) < -40.0);
        assert!(!v.is_active());
    }
}
