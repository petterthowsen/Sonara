//! Utility effect (spec 017): gain staging and stereo tools.
//!
//! Signal path, per sample: `phase invert → bass mono → width → pan (balance) → gain × mute`.
//!
//! - Phase invert is a smoothed ±1 gain per channel, so flipping it ramps through zero instead
//!   of stepping.
//! - Bass Mono splits off the low band with a one-crossover `MultibandSplitter` (LR4), sums it to
//!   mono and adds it back to the high band. It fades in and out over the ramp; the splitter runs
//!   only while it is on or fading, and starts from a clean state when switched on.
//! - Width works in M/S with M = (L+R)/2 and S = (L−R)/2. Up to 100 % only the side is scaled,
//!   so narrowing never changes the mono sum. Above 100 % mid and side are scaled by
//!   `1/n` and `w/n` with `n = sqrt((1 + w²)/2)`, which keeps the level of uncorrelated M/S
//!   constant. Mono forces the width to 0.
//! - Pan is a balance control: the far side follows a cos curve to silence at ±100 %, the near
//!   side stays at unity.
//! - Gain at the bottom of its range (−60 dB) is silence. Mute is a smoothed fade to 0.
//! - With every control at its default and settled, the block is passed through bit-exact.

use super::effect::{pass_through, TailSleep};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
};
use crate::audio::dsp::crossover::{MultibandSplitter, MAX_BANDS};
use crate::audio::dsp::gain::db_to_gain;
use crate::audio::dsp::smoothing::SmoothedParam;
use std::f32::consts::FRAC_PI_2;

// === Parameters ===

pub const GAIN: ParamId = 0;
pub const PAN: ParamId = 1;
pub const WIDTH: ParamId = 2;
pub const MUTE: ParamId = 30;

pub const MONO: ParamId = 10;
pub const BASS_MONO: ParamId = 11;
pub const BASS_MONO_FREQ: ParamId = 12;

pub const INVERT_L: ParamId = 20;
pub const INVERT_R: ParamId = 21;

/// Bottom of the Gain range; this value and below is silence.
const GAIN_FLOOR_DB: f32 = -60.0;

const MAIN_MODULE: [ParamSpec; 4] = [
    spec(GAIN, "Gain", "Main", "dB", linear(GAIN_FLOOR_DB, 24.0), 0.0),
    spec(PAN, "Pan", "Main", "%", linear(-100.0, 100.0), 0.0),
    spec(WIDTH, "Width", "Main", "%", linear(0.0, 200.0), 100.0),
    spec(MUTE, "Mute", "Main", "", Kind::Bool, 0.0),
];

const STEREO_MODULE: [ParamSpec; 3] = [
    spec(MONO, "Mono", "Stereo", "", Kind::Bool, 0.0),
    spec(BASS_MONO, "Bass Mono", "Stereo", "", Kind::Bool, 0.0),
    spec(
        BASS_MONO_FREQ,
        "Bass Mono Freq",
        "Stereo",
        "Hz",
        log(20.0, 500.0),
        120.0,
    ),
];

const PHASE_MODULE: [ParamSpec; 2] = [
    spec(INVERT_L, "Invert L", "Phase", "", Kind::Bool, 0.0),
    spec(INVERT_R, "Invert R", "Phase", "", Kind::Bool, 0.0),
];

const PARAM_COUNT: usize = 9;
const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[&MAIN_MODULE, &STEREO_MODULE, &PHASE_MODULE]);
const SLOTS: [u8; 31] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

// === Constants ===

/// Smoothing time for gain, pan, width, polarity and the mute and bass-mono fades.
const RAMP_MS: f32 = 20.0;
/// Frames the bass-mono splitter processes at a time (its scratch buffers hold this many).
const CHUNK: usize = 64;

/// Decoded (real-valued) parameters.
#[derive(Clone, Copy, Debug)]
struct Params {
    /// Linear gain; 0 at the bottom of the range.
    gain: f32,
    /// −1..1.
    pan: f32,
    /// 0..2.
    width: f32,
    mute: bool,
    mono: bool,
    bass_mono: bool,
    bass_hz: f32,
    invert: [bool; 2],
}

impl Params {
    fn defaults(values: &ParamValues<PARAM_COUNT>) -> Self {
        let mut p = Self {
            gain: 1.0,
            pan: 0.0,
            width: 1.0,
            mute: false,
            mono: false,
            bass_mono: false,
            bass_hz: 120.0,
            invert: [false; 2],
        };
        for spec in &SPECS {
            if let Some(real) = values.real(spec.id) {
                p.apply(spec.id, real);
            }
        }
        p
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            GAIN => self.gain = gain_from_db(real),
            PAN => self.pan = real * 0.01,
            WIDTH => self.width = real * 0.01,
            MUTE => self.mute = real >= 0.5,
            MONO => self.mono = real >= 0.5,
            BASS_MONO => self.bass_mono = real >= 0.5,
            BASS_MONO_FREQ => self.bass_hz = real,
            INVERT_L => self.invert[0] = real >= 0.5,
            INVERT_R => self.invert[1] = real >= 0.5,
            _ => {}
        }
    }

    /// Width the smoother aims for: Mono forces 0.
    fn width_target(&self) -> f32 {
        if self.mono {
            0.0
        } else {
            self.width
        }
    }

    fn mute_target(&self) -> f32 {
        if self.mute {
            0.0
        } else {
            1.0
        }
    }

    fn polarity(&self, ch: usize) -> f32 {
        if self.invert[ch] {
            -1.0
        } else {
            1.0
        }
    }
}

fn gain_from_db(db: f32) -> f32 {
    if db <= GAIN_FLOOR_DB {
        0.0
    } else {
        db_to_gain(db)
    }
}

/// Mid and side gains for width `w` (0..2). Exactly (1, 1) at `w = 1`.
#[inline]
fn width_gains(w: f32) -> (f32, f32) {
    if w <= 1.0 {
        (1.0, w)
    } else {
        let n = ((1.0 + w * w) * 0.5).sqrt();
        (1.0 / n, w / n)
    }
}

/// Left and right gains for balance `pan` (−1..1). Exactly (1, 1) at the center and exactly 0
/// on the far side at ±1.
#[inline]
fn balance_gains(pan: f32) -> (f32, f32) {
    let far = |amount: f32| {
        if amount >= 1.0 {
            0.0
        } else {
            (amount * FRAC_PI_2).cos()
        }
    };
    if pan > 0.0 {
        (far(pan), 1.0)
    } else if pan < 0.0 {
        (1.0, far(-pan))
    } else {
        (1.0, 1.0)
    }
}

// === Device ===

pub struct UtilityDevice {
    sample_rate: f32,
    values: ParamValues<PARAM_COUNT>,
    p: Params,

    sm_gain: SmoothedParam,
    sm_mute: SmoothedParam,
    sm_pan: SmoothedParam,
    sm_width: SmoothedParam,
    sm_polarity: [SmoothedParam; 2],
    /// Bass-mono amount, 0 (off) to 1 (on).
    sm_bass: SmoothedParam,

    splitter: MultibandSplitter,
    /// True while the splitter is in use (Bass Mono on, or fading out).
    bass_running: bool,
    scratch: Vec<f32>,
    bands: [Vec<f32>; MAX_BANDS],
    dry_aligned: Vec<f32>,

    sleep: TailSleep,
    is_active: bool,
    is_enabled: bool,
}

impl UtilityDevice {
    pub fn new(sample_rate: f32) -> Self {
        let values = ParamValues::<PARAM_COUNT>::new(&TABLE);
        let p = Params::defaults(&values);
        let smoother = |v: f32| SmoothedParam::new(v, sample_rate, RAMP_MS);
        let mut splitter = MultibandSplitter::new(sample_rate);
        splitter.set_topology(1);
        splitter.set_targets(&[p.bass_hz]);
        splitter.snap();
        Self {
            sample_rate,
            values,
            p,
            sm_gain: smoother(p.gain),
            sm_mute: smoother(p.mute_target()),
            sm_pan: smoother(p.pan),
            sm_width: smoother(p.width_target()),
            sm_polarity: [smoother(p.polarity(0)), smoother(p.polarity(1))],
            sm_bass: smoother(if p.bass_mono { 1.0 } else { 0.0 }),
            splitter,
            bass_running: p.bass_mono,
            scratch: vec![0.0; CHUNK * 2],
            bands: std::array::from_fn(|_| vec![0.0; CHUNK * 2]),
            dry_aligned: vec![0.0; CHUNK * 2],
            sleep: TailSleep::new(sample_rate),
            is_active: true,
            is_enabled: true,
        }
    }

    /// Every control is at its identity value and not moving, so the output is the input.
    fn is_identity(&self) -> bool {
        let at = |sm: &SmoothedParam, v: f32| sm.is_settled() && sm.current() == v;
        at(&self.sm_gain, 1.0)
            && at(&self.sm_mute, 1.0)
            && at(&self.sm_pan, 0.0)
            && at(&self.sm_width, 1.0)
            && at(&self.sm_polarity[0], 1.0)
            && at(&self.sm_polarity[1], 1.0)
            && !self.bass_running
    }

    fn set_bass_mono(&mut self, on: bool) {
        if on && !self.bass_running {
            // Start from rest at the current frequency, not gliding from an old one.
            self.splitter.set_targets(&[self.p.bass_hz]);
            self.splitter.snap();
            self.splitter.reset();
            self.bass_running = true;
        }
        self.sm_bass.set_target(if on { 1.0 } else { 0.0 });
    }

    /// Process up to [`CHUNK`] frames.
    fn process_chunk(&mut self, input: &[f32], output: &mut [f32], frames: usize) {
        let scratch = &mut self.scratch[..frames * 2];

        // 1. Phase invert.
        for (s, x) in scratch.chunks_exact_mut(2).zip(input.chunks_exact(2)) {
            s[0] = x[0] * self.sm_polarity[0].next();
            s[1] = x[1] * self.sm_polarity[1].next();
        }

        // 2. Bass mono.
        if self.bass_running {
            self.splitter
                .split(scratch, &mut self.bands, &mut self.dry_aligned, frames);
            let (low, high) = (&self.bands[0], &self.bands[1]);
            for (f, s) in scratch.chunks_exact_mut(2).enumerate() {
                let m = self.sm_bass.next();
                if m == 0.0 {
                    continue;
                }
                let i = f * 2;
                let low_mono = (low[i] + low[i + 1]) * 0.5;
                let l = low_mono + high[i];
                let r = low_mono + high[i + 1];
                s[0] += (l - s[0]) * m;
                s[1] += (r - s[1]) * m;
            }
        }

        // 3–5. Width, pan, gain × mute.
        for (o, s) in output.chunks_exact_mut(2).zip(scratch.chunks_exact(2)) {
            let (mut l, mut r) = (s[0], s[1]);

            let (mid_gain, side_gain) = width_gains(self.sm_width.next());
            if mid_gain != 1.0 || side_gain != 1.0 {
                let mid = (l + r) * 0.5 * mid_gain;
                let side = (l - r) * 0.5 * side_gain;
                l = mid + side;
                r = mid - side;
            }

            let (pan_l, pan_r) = balance_gains(self.sm_pan.next());
            let gain = self.sm_gain.next() * self.sm_mute.next();
            o[0] = l * pan_l * gain;
            o[1] = r * pan_r * gain;
        }
    }

    fn snap_smoothers(&mut self) {
        let p = self.p;
        self.sm_gain.snap(p.gain);
        self.sm_mute.snap(p.mute_target());
        self.sm_pan.snap(p.pan);
        self.sm_width.snap(p.width_target());
        self.sm_polarity[0].snap(p.polarity(0));
        self.sm_polarity[1].snap(p.polarity(1));
        self.sm_bass.snap(if p.bass_mono { 1.0 } else { 0.0 });
    }

    fn reset_dsp(&mut self) {
        self.snap_smoothers();
        self.splitter.set_targets(&[self.p.bass_hz]);
        self.splitter.snap();
        self.splitter.reset();
        self.bass_running = self.p.bass_mono;
    }

    /// Apply a decoded (real-valued) parameter to the decoded state and the smoothers.
    fn apply(&mut self, id: ParamId, real: f32) {
        self.p.apply(id, real);
        let p = self.p;
        match id {
            GAIN => self.sm_gain.set_target(p.gain),
            PAN => self.sm_pan.set_target(p.pan),
            WIDTH | MONO => self.sm_width.set_target(p.width_target()),
            MUTE => self.sm_mute.set_target(p.mute_target()),
            BASS_MONO => self.set_bass_mono(p.bass_mono),
            BASS_MONO_FREQ => self.splitter.set_targets(&[p.bass_hz]),
            INVERT_L => self.sm_polarity[0].set_target(p.polarity(0)),
            INVERT_R => self.sm_polarity[1].set_target(p.polarity(1)),
            _ => {}
        }
    }
}

impl AudioDevice for UtilityDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.is_active || !self.is_enabled || self.is_identity() {
            pass_through(inputs, outputs, sample_count);
            self.sleep.on_block(sample_count);
            return;
        }
        let sample_count = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);

        let mut done = 0;
        while done < sample_count {
            let n = CHUNK.min(sample_count - done);
            let range = done * 2..(done + n) * 2;
            self.process_chunk(&inputs[range.clone()], &mut outputs[range], n);
            done += n;
        }

        if self.bass_running && !self.p.bass_mono && self.sm_bass.is_settled() {
            self.bass_running = false;
        }
        self.sleep.on_block(sample_count);
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        let Some((_, real)) = self.values.set(param_id, value) else {
            return;
        };
        self.sleep.wake();
        self.apply(param_id, real);
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        let Some((_, real)) = self.values.set_offset(param_id, offset) else {
            return;
        };
        self.sleep.wake();
        self.apply(param_id, real);
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.values.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.utility"
    }

    fn device_name(&self) -> &str {
        "Utility"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Effect
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        TABLE.infos()
    }

    fn reset(&mut self) {
        self.reset_dsp();
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        let [pol_l, pol_r] = &mut self.sm_polarity;
        for smoother in [
            &mut self.sm_gain,
            &mut self.sm_mute,
            &mut self.sm_pan,
            &mut self.sm_width,
            pol_l,
            pol_r,
            &mut self.sm_bass,
        ] {
            smoother.set_ramp(sample_rate, RAMP_MS);
        }
        self.splitter = MultibandSplitter::new(sample_rate);
        self.splitter.set_topology(1);
        self.sleep.set_sample_rate(sample_rate);
        self.reset_dsp();
    }

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        self.is_active = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        self.is_active = false;
        self.reset_dsp();
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
    }

    fn is_sleeping(&self) -> bool {
        self.sleep.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.sleep.wake();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        self.sleep.update(has_audio_activity)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{
        interleave, left, render, right, rms, sine, stereo, to_db, tone_amplitude, white_noise,
    };

    const SR: f32 = 48_000.0;

    fn device() -> UtilityDevice {
        let mut d = UtilityDevice::new(SR);
        d.prepare(SR, 4_096);
        d
    }

    fn set_real(d: &mut UtilityDevice, id: ParamId, real: f32) {
        let spec = TABLE.spec(id).unwrap();
        d.set_parameter(id, spec.to_norm(real));
    }

    /// Run silence until the smoothers settle.
    fn settle(d: &mut UtilityDevice) {
        render(d, &vec![0.0; 4_800 * 2], &[512]);
    }

    fn configured(params: &[(ParamId, f32)]) -> UtilityDevice {
        let mut d = device();
        for &(id, real) in params {
            set_real(&mut d, id, real);
        }
        settle(&mut d);
        d
    }

    /// Uncorrelated stereo noise.
    fn noise(frames: usize) -> Vec<f32> {
        interleave(&white_noise(frames, 0.5, 3), &white_noise(frames, 0.5, 17))
    }

    fn power(signal: &[f32]) -> f32 {
        rms(signal).powi(2)
    }

    #[test]
    fn defaults_pass_through_bit_exact() {
        let mut d = device();
        let input = noise(10_000);
        assert_eq!(render(&mut d, &input, &[512]), input);
    }

    #[test]
    fn width_zero_folds_to_mono() {
        let mut d = configured(&[(WIDTH, 0.0)]);
        let input = noise(4_800);
        let out = render(&mut d, &input, &[512]);
        for (o, i) in out.chunks_exact(2).zip(input.chunks_exact(2)) {
            assert_eq!(o[0], o[1]);
            assert!((o[0] - (i[0] + i[1]) * 0.5).abs() < 1e-6);
        }
    }

    #[test]
    fn mono_forces_width_zero() {
        let mut d = configured(&[(WIDTH, 200.0), (MONO, 1.0)]);
        let out = render(&mut d, &noise(4_800), &[512]);
        assert!(out.chunks_exact(2).all(|o| o[0] == o[1]));
    }

    #[test]
    fn width_200_keeps_power_of_uncorrelated_noise() {
        let mut d = configured(&[(WIDTH, 200.0)]);
        let input = noise(96_000);
        let out = render(&mut d, &input, &[512]);
        let diff = 10.0 * (power(&out) / power(&input)).log10();
        assert!(diff.abs() < 0.1, "power changed by {diff} dB");
    }

    #[test]
    fn width_200_has_two_to_one_side_to_mid() {
        let (mid, side) = width_gains(2.0);
        assert!((side / mid - 2.0).abs() < 1e-6);
        assert!((to_db(mid) + 3.98).abs() < 0.05, "mid {} dB", to_db(mid));
        assert!((to_db(side) - 2.04).abs() < 0.05, "side {} dB", to_db(side));

        // Pure mid in, pure side in: measure what the device does to each.
        let mut d = configured(&[(WIDTH, 200.0)]);
        let tone = sine(1_000.0, SR, 4_800, 0.25);
        let mid_out = render(&mut d, &stereo(&tone), &[512]);
        let neg: Vec<f32> = tone.iter().map(|x| -x).collect();
        let side_out = render(&mut d, &interleave(&tone, &neg), &[512]);
        let ratio = rms(&left(&side_out)) / rms(&left(&mid_out));
        assert!((ratio - 2.0).abs() < 1e-3, "side/mid {ratio}");
    }

    #[test]
    fn width_curve_is_continuous_at_100() {
        let (m0, s0) = width_gains(1.0);
        let (m1, s1) = width_gains(1.0 + 1e-4);
        assert_eq!((m0, s0), (1.0, 1.0));
        assert!((m1 - 1.0).abs() < 1e-3 && (s1 - 1.0).abs() < 1e-3);
    }

    #[test]
    fn pan_center_is_unity_and_full_right_silences_left() {
        assert_eq!(balance_gains(0.0), (1.0, 1.0));
        assert_eq!(balance_gains(1.0), (0.0, 1.0));
        assert_eq!(balance_gains(-1.0), (1.0, 0.0));

        let mut d = configured(&[(PAN, 100.0)]);
        let input = noise(4_800);
        let out = render(&mut d, &input, &[512]);
        assert!(left(&out).iter().all(|&x| x == 0.0));
        assert_eq!(right(&out), right(&input));
    }

    #[test]
    fn invert_flips_only_its_channel() {
        let input = noise(4_800);
        for (id, ch) in [(INVERT_L, 0), (INVERT_R, 1)] {
            let mut d = configured(&[(id, 1.0)]);
            let out = render(&mut d, &input, &[512]);
            for (o, i) in out.chunks_exact(2).zip(input.chunks_exact(2)) {
                assert_eq!(o[ch], -i[ch]);
                assert_eq!(o[1 - ch], i[1 - ch]);
            }
        }
    }

    /// Steady-state (left, right) amplitude of a sine panned hard left, through Bass Mono.
    fn bass_mono_hard_left(hz: f32) -> (f32, f32) {
        let mut d = configured(&[(BASS_MONO, 1.0)]);
        let frames = SR as usize;
        let tone = sine(hz, SR, frames, 0.5);
        let out = render(&mut d, &interleave(&tone, &vec![0.0; frames]), &[512]);
        let half = frames / 2;
        (
            tone_amplitude(&left(&out)[half..], hz, SR),
            tone_amplitude(&right(&out)[half..], hz, SR),
        )
    }

    #[test]
    fn bass_mono_centers_lows_and_keeps_highs() {
        let (l, r) = bass_mono_hard_left(40.0);
        assert!(
            (to_db(l) - to_db(r)).abs() < 0.3,
            "40 Hz: L {l}, R {r} should match"
        );
        assert!((l - 0.25).abs() < 0.02, "40 Hz folds to half level: {l}");

        let (l, r) = bass_mono_hard_left(5_000.0);
        assert!((l - 0.5).abs() < 0.01, "5 kHz left: {l}");
        assert!(r < 1e-3, "5 kHz leaks to the right: {r}");
    }

    #[test]
    fn gain_floor_is_silence_and_top_is_24_db() {
        let input = noise(4_800);
        let mut d = configured(&[(GAIN, GAIN_FLOOR_DB)]);
        assert!(render(&mut d, &input, &[512]).iter().all(|&x| x == 0.0));

        let mut d = configured(&[(GAIN, 24.0)]);
        let out = render(&mut d, &input, &[512]);
        let ratio = rms(&out) / rms(&input);
        assert!((ratio - 15.85).abs() < 0.01, "+24 dB gives ×{ratio}");
    }

    #[test]
    fn mute_fades_without_a_step() {
        let mut d = device();
        let frames = 4_800;
        let ones = vec![1.0; frames * 2];
        render(&mut d, &ones[..1_024], &[512]);
        set_real(&mut d, MUTE, 1.0);
        let out = render(&mut d, &ones, &[512]);
        let l = left(&out);
        let max_step = l
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max);
        // One ramp step is 1 / (20 ms × 48 kHz) ≈ 0.001.
        assert!(max_step < 0.002, "step of {max_step}");
        assert_eq!(*l.last().unwrap(), 0.0);
    }

    #[test]
    fn output_does_not_depend_on_block_size() {
        let input = noise(24_000);
        let params = [
            (GAIN, 6.0),
            (PAN, -40.0),
            (WIDTH, 160.0),
            (BASS_MONO, 1.0),
            (BASS_MONO_FREQ, 200.0),
            (INVERT_R, 1.0),
        ];
        let run = |block: usize| {
            let mut d = device();
            for &(id, real) in &params {
                set_real(&mut d, id, real);
            }
            render(&mut d, &input, &[block])
        };
        assert_eq!(run(64), run(512));
    }
}
