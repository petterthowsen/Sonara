//! Pitch Shifter effect (spec 045).
//!
//! A delay-line granular shifter. Each channel has one [`DelayLine`]; `TAPS` read taps move
//! through it at the pitch ratio `r` while the write head moves at 1, so a tap's delay changes by
//! `1 − r` per sample. Every tap is faded in and out by a `sin²` window driven by one shared grain
//! phasor, the taps evenly spaced in phase, so the windows always sum to exactly 1.
//!
//! Tap delays are *integrated*, never computed from the phasor: a restarting tap jumps to a start
//! delay while its window is at zero, and from then on only the slope (`1 − r`) is ever
//! changed. Automating Pitch, Fine, Spread or Grain therefore changes slopes, not positions, and
//! can't click. At `r = 1` every tap sits at `D_MIN` and the wet is the input delayed by `D_MIN`.
//!
//! Jitter randomizes the length of each grain cycle and offsets each restarting tap (seeded, so
//! renders are repeatable). Feedback returns the shifted output through a fixed 30 Hz low cut and
//! 8 kHz high cut and a soft clip. Mix 0 % is bit-exact dry; non-finite input is replaced by
//! silence before it reaches the dry path or the lines.

use super::chorus::sin_cos_cycles;
use super::effect::{pass_through, TailSleep};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
};
use crate::audio::dsp::delay_line::{DelayLine, MIN_HERMITE_DELAY};
use crate::audio::dsp::gain::{dry_wet_gains, MixLaw};
use crate::audio::dsp::noise::Rng;
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::dsp::tempo_sync::{division_seconds, SYNC_CHOICES};

// === Parameters (IDs in blocks of ten per module) ===

pub const PITCH: ParamId = 0;
pub const FINE: ParamId = 1;

pub const GRAIN: ParamId = 10;
pub const SYNC: ParamId = 11;
pub const JITTER: ParamId = 12;

pub const FEEDBACK: ParamId = 20;

pub const SPREAD: ParamId = 30;
pub const MIX: ParamId = 31;

#[rustfmt::skip]
const PITCH_SPECS: [ParamSpec; 2] = [
    spec(PITCH, "Pitch", "Pitch", "st", linear(-24.0, 24.0), 0.0),
    spec(FINE, "Fine", "Pitch", "cents", linear(-100.0, 100.0), 0.0),
];
#[rustfmt::skip]
const GRAIN_SPECS: [ParamSpec; 3] = [
    spec(GRAIN, "Grain", "Grain", "Hz", log(1.0, 100.0), 20.0),
    spec(SYNC, "Sync", "Grain", "", Kind::Enum(SYNC_CHOICES), 0.0),
    spec(JITTER, "Jitter", "Grain", "%", linear(0.0, 100.0), 0.0),
];
#[rustfmt::skip]
const FEEDBACK_SPECS: [ParamSpec; 1] = [
    spec(FEEDBACK, "Feedback", "Feedback", "%", linear(0.0, 95.0), 0.0),
];
#[rustfmt::skip]
const OUTPUT_SPECS: [ParamSpec; 2] = [
    spec(SPREAD, "Spread", "Output", "cents", linear(0.0, 50.0), 0.0),
    spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 100.0),
];

/// Number of real parameters.
pub const PARAM_COUNT: usize = 2 + 3 + 1 + 2;

/// Every parameter, in display order (its index here is its slot).
pub const SPECS: [ParamSpec; PARAM_COUNT] =
    flatten(&[&PITCH_SPECS, &GRAIN_SPECS, &FEEDBACK_SPECS, &OUTPUT_SPECS]);

/// IDs are all below this.
const ID_SPACE: usize = 32;

const SLOT_OF: [u8; ID_SPACE] = slot_table(&SPECS);

static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOT_OF);

// === Constants ===

/// Read taps per channel. Evenly spaced in grain phase; 2 is Bitwig's character, and the
/// window and buffer code is generic over it.
const TAPS: usize = 2;

/// Shortest tap delay, and so the constant wet delay at zero shift (2 samples).
const D_MIN: f32 = MIN_HERMITE_DELAY;

/// The grain rate range. Synced divisions longer than 1 s play as 1 Hz grains.
const GRAIN_MIN_HZ: f32 = 1.0;
const GRAIN_MAX_HZ: f32 = 100.0;

/// Largest start offset Jitter adds to a restarting tap.
const MAX_JITTER_OFFSET_SECONDS: f32 = 0.030;
/// How far Jitter can scale a grain cycle's rate (±50 % at 100 %).
const JITTER_RATE_SPREAD: f32 = 0.5;

/// Worst-case tap sweep: `(r − 1) · T` at the widest shift (±24 st, ±100 ct Fine, 50 ct Spread:
/// r ≈ 4.4) and the longest grain (1 s), rounded up.
const MAX_SWEEP_SECONDS: f32 = 3.9;
const BUFFER_HEADROOM_SECONDS: f32 = 0.1;

/// Fixed feedback-path filters.
const FEEDBACK_LOW_CUT_HZ: f32 = 30.0;
const FEEDBACK_HIGH_CUT_HZ: f32 = 8_000.0;

const SMOOTH_RAMP_MS: f32 = 5.0;
const RNG_SEED: u32 = 0x5EED_0045;

/// Cheap bounded soft clip (`x/(1+|x|)`), as the Delay's and Chorus's feedback use.
#[inline]
fn soft_clip(x: f32) -> f32 {
    x / (1.0 + x.abs())
}

/// Replace NaN and ±Inf with 0 so they never reach the lines.
#[inline]
fn finite_or_zero(x: f32) -> f32 {
    if x.is_finite() {
        x
    } else {
        0.0
    }
}

/// Pitch ratio for a shift in cents.
#[inline]
fn ratio(cents: f32) -> f32 {
    (cents * (1.0 / 1200.0)).exp2()
}

// === Device ===

/// Pitch Shifter effect (spec 045).
pub struct PitchShifterDevice {
    sample_rate: f32,
    params: ParamValues<PARAM_COUNT>,

    /// `100 · Pitch + Fine`, smoothed.
    cents: SmoothedParam,
    spread: SmoothedParam,
    grain_hz: SmoothedParam,
    jitter: SmoothedParam,
    feedback: SmoothedParam,
    mix: SmoothedParam,

    /// Whole-semitone Pitch and Fine, kept so either can change on its own.
    pitch_st: f32,
    fine_cents: f32,
    spread_target: f32,
    tempo: f64,

    lines: [DelayLine; 2],
    /// Current delay of each tap, per channel, in frames.
    taps: [[f32; TAPS]; 2],
    /// Shared grain phasor in cycles, and this cycle's Jitter rate scale.
    phase: f64,
    rate_mult: f32,
    rng: Rng,
    /// `(cos, sin)` of each tap's phase offset `2π·k/TAPS`.
    tap_rotation: [(f32, f32); TAPS],

    high_pass: [OnePole; 2],
    low_pass: [OnePole; 2],
    g_hp: f32,
    g_lp: f32,

    /// Pitch ratios per channel, cached against their smoothed inputs.
    ratios: [f32; 2],
    last_cents: f32,
    last_spread: f32,
    dry_gain: f32,
    wet_gain: f32,
    last_mix: f32,

    max_delay: f32,
    max_jitter_offset: f32,

    tail: TailSleep,
    enabled: bool,
    /// Dormant (deactivated) devices bypass like a disabled one.
    is_active: bool,
}

impl PitchShifterDevice {
    pub fn new(sample_rate: f32) -> Self {
        let mut device = Self {
            sample_rate,
            params: ParamValues::new(&TABLE),
            cents: SmoothedParam::new(0.0, sample_rate, SMOOTH_RAMP_MS),
            spread: SmoothedParam::new(0.0, sample_rate, SMOOTH_RAMP_MS),
            grain_hz: SmoothedParam::new(20.0, sample_rate, SMOOTH_RAMP_MS),
            jitter: SmoothedParam::new(0.0, sample_rate, SMOOTH_RAMP_MS),
            feedback: SmoothedParam::new(0.0, sample_rate, SMOOTH_RAMP_MS),
            mix: SmoothedParam::new(1.0, sample_rate, SMOOTH_RAMP_MS),
            pitch_st: 0.0,
            fine_cents: 0.0,
            spread_target: 0.0,
            tempo: 120.0,
            lines: std::array::from_fn(|_| DelayLine::new()),
            taps: [[D_MIN; TAPS]; 2],
            phase: 0.0,
            rate_mult: 1.0,
            rng: Rng::new(RNG_SEED),
            tap_rotation: std::array::from_fn(|k| {
                let angle = std::f64::consts::TAU * k as f64 / TAPS as f64;
                (angle.cos() as f32, angle.sin() as f32)
            }),
            high_pass: [OnePole::new(); 2],
            low_pass: [OnePole::new(); 2],
            g_hp: 0.0,
            g_lp: 0.0,
            ratios: [1.0; 2],
            last_cents: f32::NAN,
            last_spread: f32::NAN,
            dry_gain: 0.0,
            wet_gain: 1.0,
            last_mix: f32::NAN,
            max_delay: 0.0,
            max_jitter_offset: 0.0,
            tail: TailSleep::new(sample_rate),
            enabled: true,
            is_active: true,
        };
        device.prepare(sample_rate, 4_096);
        device.update_tail();
        device
    }

    /// Grain rate in Hz right now: the synced division when Sync isn't Off, else `free_hz`.
    #[inline]
    fn effective_grain_hz(sync_seconds: Option<f64>, free_hz: f32) -> f32 {
        match sync_seconds {
            Some(seconds) => (1.0 / seconds) as f32,
            None => free_hz,
        }
        .clamp(GRAIN_MIN_HZ, GRAIN_MAX_HZ)
    }

    fn sync_seconds(&self) -> Option<f64> {
        let sync = self.params.real(SYNC).unwrap_or(0.0) as usize;
        division_seconds(sync, self.tempo)
    }

    /// Start a tap's next grain: it jumps to the delay that lets it sweep the whole grain
    /// without reaching `D_MIN` (pitch up) or the line's end (pitch down).
    #[inline]
    fn restart_tap(&mut self, tap: usize, grain_frames_max: f32, jitter: f32) {
        let offset = if jitter > 0.0 {
            let span = (0.25 * grain_frames_max).min(self.max_jitter_offset);
            jitter * self.rng.next_f32() * span
        } else {
            0.0
        };
        for ch in 0..2 {
            let r = self.ratios[ch];
            let start = if r > 1.0 {
                D_MIN + (r - 1.0) * grain_frames_max
            } else {
                D_MIN
            };
            self.taps[ch][tap] = (start + offset).clamp(D_MIN, self.max_delay);
        }
    }

    /// How long the wet signal can ring after the input stops.
    fn update_tail(&mut self) {
        let free_hz = self.grain_hz.target();
        let grain_hz = Self::effective_grain_hz(self.sync_seconds(), free_hz);
        let grain_seconds = 1.0 / grain_hz;
        let max_cents = (100.0 * self.pitch_st + self.fine_cents).abs() + self.spread_target;
        let r_max = ratio(max_cents).max(ratio(-max_cents));
        let loop_seconds =
            D_MIN / self.sample_rate + (r_max - 1.0).abs() * grain_seconds * 0.5 + grain_seconds;
        let fb = self.feedback.target();
        let repeats = if fb <= 0.001 {
            1.0
        } else {
            ((0.001f32).ln() / fb.ln()).ceil().clamp(1.0, 400.0)
        };
        self.tail
            .set_tail_seconds(Some((repeats + 1.0) * loop_seconds));
    }

    /// Force the next sample to recompute the cached coefficients.
    fn invalidate_coefficients(&mut self) {
        self.last_cents = f32::NAN;
        self.last_spread = f32::NAN;
        self.last_mix = f32::NAN;
    }

    /// Put every smoothed value on its target (reset, tests).
    fn snap_all(&mut self) {
        let smoothed = [
            &mut self.cents,
            &mut self.spread,
            &mut self.grain_hz,
            &mut self.jitter,
            &mut self.feedback,
            &mut self.mix,
        ];
        for param in smoothed {
            let target = param.target();
            param.snap(target);
        }
    }

    /// Apply a decoded (real-valued) parameter to the DSP state.
    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            PITCH => {
                self.pitch_st = real.round();
                self.cents
                    .set_target(100.0 * self.pitch_st + self.fine_cents);
            }
            FINE => {
                self.fine_cents = real;
                self.cents
                    .set_target(100.0 * self.pitch_st + self.fine_cents);
            }
            GRAIN => self.grain_hz.set_target(real),
            JITTER => self.jitter.set_target(real / 100.0),
            FEEDBACK => self.feedback.set_target(real / 100.0),
            SPREAD => {
                self.spread_target = real;
                self.spread.set_target(real);
            }
            MIX => self.mix.set_target(real / 100.0),
            _ => {}
        }
    }
}

impl AudioDevice for PitchShifterDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.enabled || !self.is_active {
            pass_through(inputs, outputs, sample_count);
            return;
        }

        let frames = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        self.tail.on_block(frames);

        let sync_seconds = self.sync_seconds();
        let sample_rate = self.sample_rate;
        let inv_sample_rate = 1.0 / sample_rate as f64;
        let max_delay = self.max_delay;
        let (g_hp, g_lp) = (self.g_hp, self.g_lp);

        for i in 0..frames {
            let dry = [
                finite_or_zero(inputs[i * 2]),
                finite_or_zero(inputs[i * 2 + 1]),
            ];

            let cents = self.cents.next();
            let spread = self.spread.next();
            let free_grain = self.grain_hz.next();
            let jitter = self.jitter.next();
            let feedback = self.feedback.next();
            let mix = self.mix.next();

            if cents != self.last_cents || spread != self.last_spread {
                self.last_cents = cents;
                self.last_spread = spread;
                self.ratios = [ratio(cents + spread), ratio(cents - spread)];
            }

            // Windows: w_k = (1/TAPS)(1 − cos(2π(φ + k/TAPS))), by angle addition from one
            // sin/cos pair. They sum to 1 for TAPS ≥ 2.
            let (sin_p, cos_p) = sin_cos_cycles(self.phase);
            let mut weights = [0.0f32; TAPS];
            for (k, w) in weights.iter_mut().enumerate() {
                let (cos_k, sin_k) = self.tap_rotation[k];
                *w = (1.0 - (cos_p * cos_k - sin_p * sin_k)) * (1.0 / TAPS as f32);
            }

            let mut wet = [0.0f32; 2];
            for ch in 0..2 {
                let slope = 1.0 - self.ratios[ch];
                let line = &self.lines[ch];
                let mut sum = 0.0;
                for k in 0..TAPS {
                    let delay = self.taps[ch][k];
                    sum += weights[k] * line.read_hermite(delay);
                    self.taps[ch][k] = (delay + slope).clamp(D_MIN, max_delay);
                }
                wet[ch] = sum;
            }

            // The feedback loop returns the shifted wet through the fixed filters.
            let mut fb_in = [0.0f32; 2];
            if feedback > 0.0 {
                for ch in 0..2 {
                    let filtered =
                        self.low_pass[ch].lowpass(self.high_pass[ch].highpass(wet[ch], g_hp), g_lp);
                    let clipped = soft_clip(filtered);
                    // Keep decaying tails out of the denormal range.
                    fb_in[ch] = if clipped.abs() < 1e-20 { 0.0 } else { clipped };
                }
            }
            self.lines[0].push(dry[0] + feedback * fb_in[0]);
            self.lines[1].push(dry[1] + feedback * fb_in[1]);

            if mix != self.last_mix {
                self.last_mix = mix;
                let (dry_gain, wet_gain) = dry_wet_gains(mix, MixLaw::EqualPower);
                self.dry_gain = dry_gain;
                self.wet_gain = wet_gain;
            }
            let (dry_gain, wet_gain) = (self.dry_gain, self.wet_gain);
            if wet_gain == 0.0 {
                outputs[i * 2] = dry[0];
                outputs[i * 2 + 1] = dry[1];
            } else {
                outputs[i * 2] = dry_gain * dry[0] + wet_gain * wet[0];
                outputs[i * 2 + 1] = dry_gain * dry[1] + wet_gain * wet[1];
            }

            // Advance the grain phasor; a tap whose own phase wraps restarts.
            let grain_hz = Self::effective_grain_hz(sync_seconds, free_grain);
            let rate = (grain_hz * self.rate_mult).max(GRAIN_MIN_HZ);
            let old = self.phase;
            let mut new = old + rate as f64 * inv_sample_rate;
            let wrapped = new >= 1.0;
            if wrapped {
                new -= 1.0;
                self.rate_mult = if jitter > 0.0 {
                    1.0 + JITTER_RATE_SPREAD * jitter * self.rng.bipolar()
                } else {
                    1.0
                };
            }
            self.phase = new;

            // A tap restarts when the phasor crosses its offset (tap 0: when it wraps).
            for k in 0..TAPS {
                let offset = k as f64 / TAPS as f64;
                let crossed = if k == 0 {
                    wrapped
                } else {
                    old < offset && new >= offset
                };
                if crossed {
                    // The slowest cycle Jitter can pick bounds how far a pitch-up tap must start.
                    let slowest =
                        (grain_hz * (1.0 - JITTER_RATE_SPREAD * jitter)).max(GRAIN_MIN_HZ);
                    self.restart_tap(k, sample_rate / slowest, jitter);
                }
            }
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        let Some((_, real)) = self.params.set(param_id, value) else {
            return;
        };
        self.tail.wake();
        self.apply(param_id, real);
        self.update_tail();
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        let Some((_, real)) = self.params.set_offset(param_id, offset) else {
            return;
        };
        self.tail.wake();
        self.apply(param_id, real);
        self.update_tail();
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.params.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.pitch_shifter"
    }

    fn device_name(&self) -> &str {
        "Pitch Shifter"
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

    fn set_transport(&mut self, transport: &crate::audio::transport::Transport) {
        if transport.tempo > 0.0 && transport.tempo != self.tempo {
            self.tempo = transport.tempo;
            self.update_tail();
        }
    }

    fn reset(&mut self) {
        self.lines[0].clear();
        self.lines[1].clear();
        self.taps = [[D_MIN; TAPS]; 2];
        self.phase = 0.0;
        self.rate_mult = 1.0;
        self.rng = Rng::new(RNG_SEED);
        self.high_pass = [OnePole::new(); 2];
        self.low_pass = [OnePole::new(); 2];
        self.ratios = [1.0; 2];
        self.invalidate_coefficients();
        self.snap_all();
        self.tail.wake();
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        for line in &mut self.lines {
            line.prepare_seconds(
                MAX_SWEEP_SECONDS + MAX_JITTER_OFFSET_SECONDS + BUFFER_HEADROOM_SECONDS,
                sample_rate,
            );
        }
        self.max_delay = self.lines[0].max_delay();
        self.max_jitter_offset = MAX_JITTER_OFFSET_SECONDS * sample_rate;
        self.taps = [[D_MIN; TAPS]; 2];
        self.high_pass = [OnePole::new(); 2];
        self.low_pass = [OnePole::new(); 2];
        self.g_hp = one_pole_g(FEEDBACK_LOW_CUT_HZ, sample_rate);
        self.g_lp = one_pole_g(FEEDBACK_HIGH_CUT_HZ.min(sample_rate * 0.45), sample_rate);
        self.invalidate_coefficients();
        for param in [
            &mut self.cents,
            &mut self.spread,
            &mut self.grain_hz,
            &mut self.jitter,
            &mut self.feedback,
            &mut self.mix,
        ] {
            param.set_ramp(sample_rate, SMOOTH_RAMP_MS);
        }
        self.tail.set_sample_rate(sample_rate);
        self.update_tail();
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
        self.reset();
        Ok(())
    }

    fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    fn is_sleeping(&self) -> bool {
        self.tail.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.tail.wake();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        self.tail.update(has_audio_activity)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::{enum_to_norm, real_to_norm, ParamType};
    use crate::audio::dsp::test_util::{
        left, peak, render, right, sine, spectrum_db, stereo, white_noise,
    };
    use crate::audio::transport::Transport;

    const SR: f32 = 48_000.0;
    /// FFT length for peak measurements (a power of two, 2.7 s at 48 kHz).
    const FFT_LEN: usize = 1 << 17;
    /// Grain rate for the exact-pitch tests: a 1 Hz comb resolves any shift in the test set.
    const ACCURATE_GRAIN: f32 = 1.0;

    fn device() -> PitchShifterDevice {
        PitchShifterDevice::new(SR)
    }

    /// A device with the narrow comb the exact-pitch tests need.
    fn accurate_device() -> PitchShifterDevice {
        let mut d = device();
        set_real(&mut d, GRAIN, ACCURATE_GRAIN);
        d
    }

    /// Set a parameter by real value (index for enums), then settle the smoothers.
    fn set_real(device: &mut PitchShifterDevice, id: ParamId, real: f32) {
        let info = device
            .parameters()
            .into_iter()
            .find(|p| p.id == id)
            .unwrap();
        let norm = match info.param_type {
            ParamType::Enum => enum_to_norm(real as usize, info.enum_values.len()),
            _ => real_to_norm(real, info.min, info.max, info.is_logarithmic, info.skew),
        };
        device.set_parameter(id, norm);
        device.snap_all();
    }

    /// Pitch of the last `FFT_LEN` samples: the power-weighted centre of the spectral comb around
    /// its strongest bin.
    ///
    /// A granular shifter doesn't output a single line. A grain restarts every 1/Grain, so a
    /// sine comes out as lines `Grain` Hz apart (or `TAPS · Grain` when the taps' phases line
    /// up), weighted by the grain window centred on the true shifted frequency. The strongest
    /// bin is just the nearest line; the centre of the comb is the pitch. A shift much smaller
    /// than the line spacing can't be resolved, so the exact-pitch tests use `ACCURATE_GRAIN`.
    fn peak_hz(signal: &[f32], sample_rate: f32) -> f32 {
        peak_hz_for_grain(signal, sample_rate, ACCURATE_GRAIN)
    }

    fn peak_hz_for_grain(signal: &[f32], sample_rate: f32, grain_hz: f32) -> f32 {
        let tail = &signal[signal.len() - FFT_LEN..];
        let db = spectrum_db(tail);
        let bin_hz = sample_rate / FFT_LEN as f32;
        let (strongest, _) = db
            .iter()
            .enumerate()
            .skip(2)
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap();
        let half = (4.0 * grain_hz / bin_hz) as usize;
        let (lo, hi) = (
            strongest.saturating_sub(half).max(1),
            (strongest + half).min(db.len() - 1),
        );
        let (mut weighted, mut total) = (0.0f64, 0.0f64);
        for (bin, level) in db.iter().enumerate().take(hi + 1).skip(lo) {
            let power = 10f64.powf(*level as f64 / 10.0);
            weighted += power * bin as f64 * bin_hz as f64;
            total += power;
        }
        (weighted / total) as f32
    }

    fn cents(measured: f32, expected: f32) -> f32 {
        1200.0 * (measured / expected).log2()
    }

    /// Render a mono sine through the device (stereo in, left channel out), long enough to
    /// measure.
    fn shifted_sine(device: &mut PitchShifterDevice, freq: f32, sample_rate: f32) -> Vec<f32> {
        let frames = FFT_LEN + sample_rate as usize;
        let input = stereo(&sine(freq, sample_rate, frames, 0.5));
        left(&render(device, &input, &[512]))
    }

    /// Frames between phasor wraps (grain restarts), measured one frame at a time.
    fn grain_periods(device: &mut PitchShifterDevice, frames: usize) -> Vec<usize> {
        let (mut out, mut last_wrap, mut last_phase) = (Vec::new(), 0, 0.0);
        for n in 0..frames {
            device.process_block(&[0.0; 2], &mut [0.0; 2], 1);
            if device.phase < last_phase {
                if last_wrap > 0 {
                    out.push(n - last_wrap);
                }
                last_wrap = n;
            }
            last_phase = device.phase;
        }
        out
    }

    #[test]
    fn pitch_semitones_hit_the_target_frequency() {
        for n in [-24, -12, -7, 7, 12, 24] {
            let mut d = accurate_device();
            set_real(&mut d, PITCH, n as f32);
            let out = shifted_sine(&mut d, 440.0, SR);
            let expected = 440.0 * 2f32.powf(n as f32 / 12.0);
            let measured = peak_hz(&out, SR);
            let error = cents(measured, expected);
            assert!(
                error.abs() <= 10.0,
                "{n:+} st: peak at {measured} Hz, expected {expected} ({error:+.1} cents)"
            );
        }
    }

    #[test]
    fn default_grain_keeps_resolvable_shifts_on_pitch() {
        // At 20 Hz grains the comb lines are 20 Hz apart: octaves land exactly, and a shift
        // larger than the spacing is within a few cents. (Smaller shifts smear; see peak_hz.)
        for (n, tolerance) in [(12, 5.0), (24, 5.0), (-12, 5.0), (7, 10.0)] {
            let mut d = device();
            set_real(&mut d, PITCH, n as f32);
            let out = shifted_sine(&mut d, 440.0, SR);
            let expected = 440.0 * 2f32.powf(n as f32 / 12.0);
            let measured = peak_hz_for_grain(&out, SR, 20.0);
            let error = cents(measured, expected);
            assert!(error.abs() <= tolerance, "{n:+} st: {error:+.1} cents");
        }
    }

    #[test]
    fn fine_cents_offset_the_pitch() {
        for fine in [50.0, -50.0, 100.0] {
            let mut d = accurate_device();
            set_real(&mut d, FINE, fine);
            let out = shifted_sine(&mut d, 440.0, SR);
            let error = cents(peak_hz(&out, SR), 440.0) - fine;
            assert!(
                error.abs() <= 5.0,
                "Fine {fine:+}: off by {error:+.1} cents"
            );
        }
    }

    #[test]
    fn zero_shift_is_a_constant_delay() {
        let noise = white_noise(20_000, 0.5, 9);
        let input = stereo(&noise);
        for grain in [1.0, 20.0, 100.0] {
            let mut d = device();
            set_real(&mut d, GRAIN, grain);
            let out = left(&render(&mut d, &input, &[512]));
            let delay = D_MIN as usize;
            for n in delay..noise.len() {
                assert!(
                    (out[n] - noise[n - delay]).abs() < 1e-6,
                    "Grain {grain}: frame {n}: {} vs {}",
                    out[n],
                    noise[n - delay]
                );
            }
        }
        assert!(D_MIN / SR < 0.005, "constant delay must stay under 5 ms");
    }

    #[test]
    fn grain_rate_sets_the_restart_period() {
        for grain in [1.0, 5.0, 20.0, 100.0] {
            let mut d = device();
            set_real(&mut d, GRAIN, grain);
            let periods = grain_periods(&mut d, (SR * 3.0) as usize);
            let expected = SR / grain;
            assert!(periods.len() >= 2, "Grain {grain}: {} wraps", periods.len());
            for p in periods {
                assert!(
                    (p as f32 - expected).abs() / expected < 0.05,
                    "Grain {grain}: period {p}, expected {expected}"
                );
            }
        }
    }

    /// Strongest line 100 or 200 Hz either side of the strongest bin, relative to it, in dB
    /// (depending on the taps' phase, only every second line survives).
    fn sideband_db(signal: &[f32]) -> f32 {
        let tail = &signal[signal.len() - FFT_LEN..];
        let db = spectrum_db(tail);
        let bin_hz = SR / FFT_LEN as f32;
        let peak_bin = db
            .iter()
            .enumerate()
            .skip(2)
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .unwrap()
            .0;
        let side = |bin: usize| db[bin - 3..=bin + 3].iter().cloned().fold(-200.0, f32::max);
        [100.0, 200.0]
            .iter()
            .flat_map(|offset| {
                let span = (offset / bin_hz) as usize;
                [side(peak_bin + span), side(peak_bin - span)]
            })
            .fold(-200.0, f32::max)
            - db[peak_bin]
    }

    #[test]
    fn short_grains_add_grain_rate_sidebands() {
        let measure = |grain: f32| {
            let mut d = device();
            set_real(&mut d, PITCH, 7.0);
            set_real(&mut d, GRAIN, grain);
            sideband_db(&shifted_sine(&mut d, 440.0, SR))
        };
        let (fast, slow) = (measure(100.0), measure(5.0));
        assert!(
            fast > slow + 6.0,
            "sidebands 100-200 Hz off the peak: {fast:.1} dB at 100 Hz grains, {slow:.1} dB at 5 Hz"
        );
    }

    #[test]
    fn synced_grain_follows_tempo() {
        let mut d = device();
        set_real(&mut d, SYNC, 19.0); // 1/16
        d.set_transport(&Transport {
            tempo: 120.0,
            ..Transport::default()
        });
        let periods = grain_periods(&mut d, SR as usize * 2);
        let expected = 0.125 * SR; // 125 ms
        for p in &periods {
            assert!(
                (*p as f32 - expected).abs() / expected < 0.05,
                "period {p}, expected {expected}"
            );
        }

        // A tempo change moves the rate, never the phase.
        let before = d.phase;
        d.set_transport(&Transport {
            tempo: 90.0,
            ..Transport::default()
        });
        assert_eq!(d.phase, before);

        // Sync Off: the Hz knob applies again (20 Hz = 50 ms).
        set_real(&mut d, SYNC, 0.0);
        let periods = grain_periods(&mut d, SR as usize);
        for p in &periods {
            assert!(
                (*p as f32 - SR / 20.0).abs() < SR / 20.0 * 0.05,
                "period {p}"
            );
        }
    }

    #[test]
    fn long_synced_divisions_clamp_to_one_hz() {
        let mut d = device();
        set_real(&mut d, SYNC, 1.0); // 4/1
        let periods = grain_periods(&mut d, SR as usize * 3);
        assert!(!periods.is_empty());
        for p in periods {
            assert!((p as f32 - SR).abs() < SR * 0.05, "period {p}");
        }
    }

    #[test]
    fn jitter_zero_is_periodic_and_jitter_is_seeded() {
        let mut d = device();
        let periods = grain_periods(&mut d, SR as usize * 2);
        assert!(periods.windows(2).all(|w| w[0] == w[1]), "{periods:?}");

        let mut d = device();
        set_real(&mut d, JITTER, 100.0);
        let periods = grain_periods(&mut d, SR as usize * 2);
        assert!(
            periods.windows(2).any(|w| w[0] != w[1]),
            "grain length never varied: {periods:?}"
        );

        let input = stereo(&white_noise(SR as usize, 0.5, 4));
        let run = || {
            let mut d = device();
            set_real(&mut d, PITCH, 5.0);
            set_real(&mut d, JITTER, 100.0);
            render(&mut d, &input, &[512])
        };
        assert_eq!(run(), run(), "same settings must render bit-identically");
    }

    #[test]
    fn feedback_cascades_up_in_pitch() {
        let run = |feedback: f32| {
            let mut d = device();
            set_real(&mut d, PITCH, 12.0);
            set_real(&mut d, GRAIN, 5.0);
            set_real(&mut d, FEEDBACK, feedback);
            // A 1 kHz burst, then silence for its echoes.
            let mut mono = sine(1_000.0, SR, 4_800, 0.5);
            mono.resize(SR as usize * 4, 0.0);
            left(&render(&mut d, &stereo(&mono), &[512]))
        };
        // Band level around 4 kHz (the second pass), relative to the whole.
        let band_db = |signal: &[f32]| {
            let db = spectrum_db(signal);
            let bin_hz = SR / signal.len() as f32;
            let (lo, hi) = ((3_700.0 / bin_hz) as usize, (4_300.0 / bin_hz) as usize);
            db[lo..hi].iter().cloned().fold(-200.0, f32::max)
        };
        let (with, without) = (band_db(&run(80.0)), band_db(&run(0.0)));
        assert!(
            with > without + 20.0,
            "second pass at 4 kHz: {with:.1} dB with feedback, {without:.1} dB without"
        );
    }

    #[test]
    fn feedback_stays_bounded_on_a_long_noise_render() {
        let mut d = device();
        set_real(&mut d, FEEDBACK, 95.0);
        set_real(&mut d, PITCH, 12.0);
        let input = stereo(&white_noise(SR as usize * 60, 1.0, 21));
        let out = render(&mut d, &input, &[512]);
        assert!(out.iter().all(|x| x.is_finite()));
        assert!(peak(&out) < 10.0, "peak {}", peak(&out));
    }

    #[test]
    fn spread_detunes_left_up_right_down() {
        let mut d = accurate_device();
        set_real(&mut d, SPREAD, 20.0);
        let frames = FFT_LEN + SR as usize;
        let input = stereo(&sine(440.0, SR, frames, 0.5));
        let out = render(&mut d, &input, &[512]);
        let (l, r) = (peak_hz(&left(&out), SR), peak_hz(&right(&out), SR));
        assert!((cents(l, 440.0) - 20.0).abs() <= 5.0, "left {l} Hz");
        assert!((cents(r, 440.0) + 20.0).abs() <= 5.0, "right {r} Hz");

        let mut d = device();
        set_real(&mut d, PITCH, 5.0);
        let out = render(&mut d, &input, &[512]);
        assert_eq!(
            left(&out),
            right(&out),
            "Spread 0 must keep a mono input mono"
        );
    }

    #[test]
    fn pitch_automation_glides_without_clicks() {
        let mut d = device();
        let bar = SR as usize * 2;
        let mono = sine(220.0, SR, bar, 0.5);
        let input = stereo(&mono);
        let mut output = vec![0.0; bar * 2];
        let block = 256;
        let mut pos = 0;
        while pos < bar {
            let n = block.min(bar - pos);
            let semitones = (-12.0 + 24.0 * pos as f32 / bar as f32).round();
            set_real_no_snap(&mut d, PITCH, semitones);
            d.process_block(
                &input[pos * 2..(pos + n) * 2],
                &mut output[pos * 2..(pos + n) * 2],
                n,
            );
            pos += n;
        }
        let step = left(&output)
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0f32, f32::max);
        // A 440 Hz sine at 0.5 steps at most 0.029; allow headroom for the crossfades.
        assert!(step < 0.1, "largest sample step {step}");
    }

    fn set_real_no_snap(device: &mut PitchShifterDevice, id: ParamId, real: f32) {
        let info = device
            .parameters()
            .into_iter()
            .find(|p| p.id == id)
            .unwrap();
        device.set_parameter(
            id,
            real_to_norm(real, info.min, info.max, info.is_logarithmic, info.skew),
        );
    }

    #[test]
    fn non_finite_input_never_leaks() {
        let mut d = accurate_device();
        set_real(&mut d, PITCH, 12.0);
        set_real(&mut d, FEEDBACK, 50.0);
        let mut input = Vec::new();
        for n in 0..1_000 {
            let bad = [f32::INFINITY, f32::NEG_INFINITY, f32::NAN][n % 3];
            input.extend([bad, bad]);
        }
        input.extend(stereo(&sine(440.0, SR, FFT_LEN + SR as usize, 0.5)));
        let out = render(&mut d, &input, &[512]);
        assert!(out.iter().all(|x| x.is_finite()), "non-finite output");

        let measured = peak_hz(&left(&out), SR);
        assert!(
            cents(measured, 880.0).abs() <= 10.0,
            "recovered at {measured} Hz"
        );
    }

    #[test]
    fn prepare_resizes_for_sample_rate() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let mut d = accurate_device();
            d.prepare(rate, 512);
            set_real(&mut d, PITCH, 7.0);
            let out = shifted_sine(&mut d, 440.0, rate);
            let expected = 440.0 * 2f32.powf(7.0 / 12.0);
            let error = cents(peak_hz(&out, rate), expected);
            assert!(error.abs() <= 10.0, "{rate} Hz: {error:+.1} cents");
        }
    }

    #[test]
    fn sleep_waits_out_the_feedback_tail() {
        let mut d = device();
        set_real(&mut d, FEEDBACK, 80.0);
        let mut quiet_frames = 0usize;
        while !d.is_sleeping() && quiet_frames < SR as usize * 600 {
            d.tail.on_block(512);
            d.update_sleep_state(false);
            quiet_frames += 512;
        }
        assert!(d.is_sleeping(), "never slept");
        assert!(
            quiet_frames > SR as usize * 4,
            "slept after only {quiet_frames} frames, before the tail died"
        );

        // Signal wakes it.
        assert!(d.update_sleep_state(true));
        assert!(!d.is_sleeping());
    }

    #[test]
    fn extreme_settings_stay_finite_and_inside_the_line() {
        for (pitch, fine, spread) in [(24.0, 100.0, 50.0), (-24.0, -100.0, 50.0)] {
            let mut d = device();
            set_real(&mut d, PITCH, pitch);
            set_real(&mut d, FINE, fine);
            set_real(&mut d, SPREAD, spread);
            set_real(&mut d, GRAIN, 1.0);
            set_real(&mut d, JITTER, 100.0);
            set_real(&mut d, FEEDBACK, 95.0);
            let input = stereo(&white_noise(SR as usize * 8, 1.0, 5));
            let out = render(&mut d, &input, &[512]);
            assert!(out.iter().all(|x| x.is_finite()));
            assert!(peak(&out) < 10.0);
        }
    }

    /// Regenerates the SimpleView fixture the Godot layout test reads.
    /// `cargo test --lib dump_pitch_shifter_view_fixture -- --ignored`
    #[test]
    #[ignore = "regenerates a fixture the Godot layout test reads"]
    fn dump_pitch_shifter_view_fixture() {
        let params: Vec<String> = device()
            .parameters()
            .into_iter()
            .map(|p| {
                let enum_values: Vec<String> =
                    p.enum_values.iter().map(|v| format!("\"{v}\"")).collect();
                format!(
                    "{{\"id\":{},\"name\":\"{}\",\"module\":\"{}\",\"unit\":\"{}\",\
                     \"type\":\"{}\",\"min\":{},\"max\":{},\"default\":{},\"stepped\":{},\
                     \"logarithmic\":{},\"enum_values\":[{}]}}",
                    p.id,
                    p.name,
                    p.module,
                    p.unit,
                    match p.param_type {
                        ParamType::Float => "float",
                        ParamType::Enum => "enum",
                        ParamType::Bool => "bool",
                    },
                    p.min,
                    p.max,
                    p.default,
                    p.param_type != ParamType::Float,
                    p.is_logarithmic,
                    enum_values.join(",")
                )
            })
            .collect();
        let json = format!(
            "{{\n  \"device\": {{\"id\": \"sonara.builtin.pitch_shifter\", \
             \"name\": \"Pitch Shifter\", \"features\": []}},\n  \"params\": [\n    {}\n  ]\n}}\n",
            params.join(",\n    ")
        );
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../Godot/tests/fixtures/simple_view/pitch_shifter_params.json");
        std::fs::write(&path, json).expect("write fixture");
        println!("wrote {}", path.display());
    }

    #[test]
    #[ignore = "CPU measurement: cargo test --release cpu_pitch_shifter -- --ignored --nocapture"]
    fn cpu_pitch_shifter() {
        const FRAMES: usize = 512;
        const SECONDS: usize = 10;
        const REPEATS: usize = 5;
        let mut d = device();
        set_real(&mut d, PITCH, 7.0);
        set_real(&mut d, JITTER, 50.0);
        set_real(&mut d, FEEDBACK, 50.0);
        set_real(&mut d, SPREAD, 20.0);
        let mut output = vec![0.0; FRAMES * 2];
        let input = stereo(&sine(220.0, SR, FRAMES, 0.1));
        let blocks = (SR as usize * SECONDS) / FRAMES;
        let mut best = f64::MAX;
        for _ in 0..REPEATS {
            for _ in 0..64 {
                d.process_block(&input, &mut output, FRAMES);
            }
            let start = std::time::Instant::now();
            for _ in 0..blocks {
                d.process_block(&input, &mut output, FRAMES);
            }
            best = best.min(start.elapsed().as_secs_f64());
        }
        println!(
            "Pitch Shifter: {SECONDS} s rendered in {best:.3} s: {:.2} % of one core (best of {REPEATS})",
            best / SECONDS as f64 * 100.0
        );
    }
}
