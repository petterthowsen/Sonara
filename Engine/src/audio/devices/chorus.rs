//! Chorus effect (spec 012, Phase 5).
//!
//! A modulated-delay chorus with three voicings, built on the Phase 0 [`DelayLine`] (Hermite
//! fractional reads) so sweeping the delay doesn't zipper or alias:
//!
//! - **Classic**: two triangle-LFO voices, the L and R voices in quadrature (90° apart).
//! - **Dimension**: two anti-phase voices (180° apart), cross-mixed, at a much lower depth,
//!   with a mild BBD-style softening (a gentle extra low-pass plus soft saturation) and no
//!   added noise.
//! - **Ensemble**: three voices 120° apart on a sine LFO plus a faster, shallow vibrato.
//!
//! The wet path is high-passed (Low Cut) so the bass stays out of the modulated signal and the
//! mono sum keeps its low end; the three voicings are laid out so summing L and R doesn't
//! cancel the wet. Width is a mid/side scale on the wet, Mix an equal-power crossfade (Mix 0 %
//! is bit-exact dry). Every continuous parameter is smoothed, and a Mode change crossfades both
//! voicings over 8 ms.

use std::f64::consts::FRAC_PI_2;

use super::effect::pass_through;
use super::param_table::{
    flatten, linear, log, skewed, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
use crate::audio::dsp::delay_line::{DelayLine, MIN_HERMITE_DELAY};
use crate::audio::dsp::gain::{dry_wet_gains, MixLaw};
use crate::audio::dsp::lfo::{Lfo, LfoShape};
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::dsp::tempo_sync::{division_seconds, SYNC_CHOICES};

// === Parameters (IDs in blocks of ten per module) ===

pub const MODE: ParamId = 0;
pub const RATE: ParamId = 1;
pub const SYNC: ParamId = 2;
pub const DEPTH: ParamId = 3;
pub const DELAY: ParamId = 4;
pub const FEEDBACK: ParamId = 5;

pub const TONE: ParamId = 10;
pub const LOW_CUT: ParamId = 11;

pub const WIDTH: ParamId = 20;
pub const MIX: ParamId = 21;

const MODES: &[&str] = &["Classic", "Dimension", "Ensemble"];

/// Depth's curve: more travel at the subtle end.
const DEPTH_SKEW: f32 = 2.0;

/// Glide lengths: the delay time needs a longer one than the mix-like controls, so a big Delay
/// move plays back like a tape (pitch glide) rather than stepping.
const DELAY_RAMP_MS: f32 = 50.0;
const SMOOTH_RAMP_MS: f32 = 5.0;

/// Mode crossfade length.
const MODE_FADE_MS: f32 = 8.0;

/// Vibrato added on top of the Ensemble's main LFO.
const VIBRATO_MULT: f64 = 6.0;

/// BBD-style softening cutoff for the Dimension voicing.
const BBD_HZ: f32 = 5_000.0;

/// Delay-line length: the Delay parameter tops out at 40 ms, and Depth can double the read.
const MAX_DELAY_SECONDS: f32 = 0.15;

#[rustfmt::skip]
const CHORUS_SPECS: [ParamSpec; 6] = [
    spec(MODE, "Chorus Mode", "Chorus", "", Kind::Enum(MODES), 0.0),
    spec(RATE, "Chorus Rate", "Chorus", "Hz", log(0.02, 10.0), 0.6),
    spec(SYNC, "Chorus Sync", "Chorus", "", Kind::Enum(SYNC_CHOICES), 0.0),
    spec(DEPTH, "Chorus Depth", "Chorus", "%", skewed(0.0, 100.0, DEPTH_SKEW), 35.0),
    spec(DELAY, "Chorus Delay", "Chorus", "ms", log(0.5, 40.0), 7.0),
    spec(FEEDBACK, "Chorus Feedback", "Chorus", "%", linear(0.0, 90.0), 0.0),
];
#[rustfmt::skip]
const TONE_SPECS: [ParamSpec; 2] = [
    spec(TONE, "Tone", "Tone", "Hz", log(1_000.0, 20_000.0), 9_000.0),
    spec(LOW_CUT, "Low Cut", "Tone", "Hz", log(20.0, 1_000.0), 120.0),
];
#[rustfmt::skip]
const OUTPUT_SPECS: [ParamSpec; 2] = [
    spec(WIDTH, "Width", "Output", "%", linear(0.0, 200.0), 100.0),
    spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 50.0),
];

/// Number of real parameters.
pub const PARAM_COUNT: usize = 6 + 2 + 2;

/// Every parameter, in display order (its index here is its slot).
pub const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[
    &CHORUS_SPECS,
    &TONE_SPECS,
    &OUTPUT_SPECS,
]);

/// IDs are all below this.
const ID_SPACE: usize = 22;

const SLOT_OF: [u8; ID_SPACE] = slot_table(&SPECS);

static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOT_OF);

// === Voicings ===

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ChorusMode {
    Classic,
    Dimension,
    Ensemble,
}

impl ChorusMode {
    fn from_index(index: usize) -> Self {
        match index {
            1 => ChorusMode::Dimension,
            2 => ChorusMode::Ensemble,
            _ => ChorusMode::Classic,
        }
    }

    fn voices(&self) -> &'static [Voice] {
        match self {
            ChorusMode::Classic => &CLASSIC_VOICES,
            ChorusMode::Dimension => &DIMENSION_VOICES,
            ChorusMode::Ensemble => &ENSEMBLE_VOICES,
        }
    }

    /// LFO shape of the main modulation.
    fn shape(&self) -> LfoShape {
        match self {
            ChorusMode::Ensemble => LfoShape::Sine,
            _ => LfoShape::Triangle,
        }
    }

    /// How much of the Depth knob the voicing uses — the mode's modulation range. Dimension
    /// stays deliberately shallow.
    fn depth_scale(&self) -> f32 {
        match self {
            ChorusMode::Classic => 1.0,
            ChorusMode::Dimension => 0.4,
            ChorusMode::Ensemble => 0.7,
        }
    }

    /// Normalization so the wet sums land near unity regardless of the voice count.
    fn wet_gain(&self) -> f32 {
        match self {
            ChorusMode::Classic => 1.0,
            _ => 0.7,
        }
    }

    /// Amplitude of the extra fast vibrato (Ensemble only).
    fn vibrato_amp(&self) -> f32 {
        match self {
            ChorusMode::Ensemble => 0.18,
            _ => 0.0,
        }
    }

    /// `(cos, sin)` of each voice's phase offset for the sine voicing, so one `sin`/`cos` pair
    /// per sample builds all three voices by angle addition. None for the triangle voicings,
    /// whose shape is cheap to evaluate per voice.
    fn sine_offsets(&self) -> Option<&'static [(f32, f32)]> {
        match self {
            ChorusMode::Ensemble => Some(&ENSEMBLE_SINE_OFFSETS),
            _ => None,
        }
    }
}

/// One modulated read: `source` is the delay line it reads, `left`/`right` its output weights,
/// and `phase` its LFO offset in cycles.
#[derive(Clone, Copy, Debug)]
struct Voice {
    source: usize,
    left: f32,
    right: f32,
    phase: f64,
}

const CLASSIC_VOICES: [Voice; 2] = [
    Voice { source: 0, left: 1.0, right: 0.0, phase: 0.0 },
    Voice { source: 1, left: 0.0, right: 1.0, phase: 0.25 },
];
const DIMENSION_VOICES: [Voice; 2] = [
    Voice { source: 0, left: 1.0, right: 0.5, phase: 0.0 },
    Voice { source: 1, left: 0.5, right: 1.0, phase: 0.5 },
];
const ENSEMBLE_VOICES: [Voice; 3] = [
    Voice { source: 0, left: 1.0, right: 0.0, phase: 0.0 },
    Voice { source: 1, left: 0.0, right: 1.0, phase: 1.0 / 3.0 },
    Voice { source: 0, left: 0.5, right: 0.5, phase: 2.0 / 3.0 },
];

/// `(cos, sin)` of the Ensemble voices' offsets (0, 120°, 240°).
const ENSEMBLE_SINE_OFFSETS: [(f32, f32); 3] = [
    (1.0, 0.0),
    (-0.5, 0.866_025_4),
    (-0.5, -0.866_025_4),
];

/// LFO output at an absolute phase in cycles.
fn lfo_value(shape: LfoShape, phase: f64) -> f32 {
    let mut lfo = Lfo::default();
    lfo.phase = phase.rem_euclid(1.0);
    lfo.value(shape)
}

/// `sin` and `cos` of a phase in cycles (0..1), to a few 1e-6.
///
/// The per-sample sine voicing needs a `sin`/`cos` pair and the vibrato another `sin`; three
/// libm calls per sample are most of the chorus's CPU budget, so this uses a quarter-wave
/// reduction and minimax polynomials instead. The error is ~2e-6, far below anything audible in
/// a delay modulation.
#[inline]
fn sin_cos_cycles(phase: f64) -> (f32, f32) {
    let fraction = phase.fract();
    let p = (if fraction < 0.0 { fraction + 1.0 } else { fraction }) * 4.0;
    let quadrant = p as i32;
    let x = (p - quadrant as f64) * FRAC_PI_2;
    let x2 = x * x;
    let sin_x =
        x * (1.0 - x2 * (1.0 / 6.0 - x2 * (1.0 / 120.0 - x2 * (1.0 / 5_040.0 - x2 / 362_880.0))));
    let cos_x = 1.0
        - x2 * (0.5
            - x2 * (1.0 / 24.0
                - x2 * (1.0 / 720.0 - x2 * (1.0 / 40_320.0 - x2 / 3_628_800.0))));
    let (sin, cos) = (sin_x as f32, cos_x as f32);
    match quadrant {
        0 => (sin, cos),
        1 => (cos, -sin),
        2 => (-sin, -cos),
        _ => (-cos, sin),
    }
}

/// `sin` of a phase in cycles.
#[inline]
fn sine_cycles(phase: f64) -> f32 {
    sin_cos_cycles(phase).0
}

/// Read delay of voice `voice` of `mode`, in frames at the device rate.
///
/// The slow, literal form of what [`ChorusDevice::mode_wet`] computes: the tests measure the
/// rendered audio against this.
#[cfg(test)]
fn voice_delay_frames(
    mode: ChorusMode,
    voice: usize,
    base_frames: f32,
    depth01: f32,
    lfo_phase: f64,
    vibrato_phase: f64,
) -> f32 {
    let spec = mode.voices()[voice];
    let mut m = lfo_value(mode.shape(), lfo_phase + spec.phase);
    // The vibrato is common-mode: the voices keep their 120° spacing from the main LFO alone.
    let vibrato = mode.vibrato_amp();
    if vibrato > 0.0 {
        m += vibrato * sine_cycles(vibrato_phase);
    }
    let m = m.clamp(-1.0, 1.0);
    (base_frames * (1.0 + depth01 * mode.depth_scale() * m)).max(MIN_HERMITE_DELAY)
}

/// Cheap bounded soft clip (`x/(1+|x|)`), used for the feedback loop and the Dimension colour.
#[inline]
fn soft_clip(x: f32) -> f32 {
    x / (1.0 + x.abs())
}

// === Device ===

/// Chorus effect (spec 012, Phase 5).
pub struct ChorusDevice {
    sample_rate: f32,
    params: ParamValues<PARAM_COUNT>,

    delay_ms: SmoothedParam,
    depth: SmoothedParam,
    rate: SmoothedParam,
    tone_hz: SmoothedParam,
    low_cut_hz: SmoothedParam,
    feedback: SmoothedParam,
    width: SmoothedParam,
    mix: SmoothedParam,

    lfo: Lfo,
    vibrato_phase: f64,
    tempo: f64,

    mode: ChorusMode,
    prev_mode: Option<ChorusMode>,
    fade: f32,
    fade_step: f32,

    /// One delay line per channel; voices read them at their own modulated delays.
    lines: [DelayLine; 2],
    high_pass: [OnePole; 2],
    low_pass: [OnePole; 2],
    /// Dimension's extra BBD softening filter.
    bbd: [OnePole; 2],
    bbd_g: f32,

    /// Per-sample coefficients cached against their smoothed inputs, so the audio thread only
    /// pays for `tan`/`cos`/`sin` while a knob is actually moving.
    g_hp: f32,
    g_lp: f32,
    last_low_cut_hz: f32,
    last_tone_hz: f32,
    dry_gain: f32,
    wet_gain: f32,
    last_mix: f32,

    enabled: bool,

    /// `1 / sample_rate` and `sample_rate / 1000`, so the per-sample path multiplies instead of
    /// dividing.
    inv_sample_rate: f64,
    frames_per_ms: f32,
}

impl ChorusDevice {
    pub fn new(sample_rate: f32) -> Self {
        let mut device = Self {
            sample_rate,
            params: ParamValues::new(&TABLE),
            delay_ms: SmoothedParam::new(7.0, sample_rate, DELAY_RAMP_MS),
            depth: SmoothedParam::new(0.35, sample_rate, SMOOTH_RAMP_MS),
            rate: SmoothedParam::new(0.6, sample_rate, SMOOTH_RAMP_MS),
            tone_hz: SmoothedParam::new(9_000.0, sample_rate, SMOOTH_RAMP_MS),
            low_cut_hz: SmoothedParam::new(120.0, sample_rate, SMOOTH_RAMP_MS),
            feedback: SmoothedParam::new(0.0, sample_rate, SMOOTH_RAMP_MS),
            width: SmoothedParam::new(1.0, sample_rate, SMOOTH_RAMP_MS),
            mix: SmoothedParam::new(0.5, sample_rate, SMOOTH_RAMP_MS),
            lfo: Lfo::default(),
            vibrato_phase: 0.0,
            tempo: 120.0,
            mode: ChorusMode::Classic,
            prev_mode: None,
            fade: 1.0,
            fade_step: 1.0 / (MODE_FADE_MS * 0.001 * sample_rate).max(1.0),
            lines: std::array::from_fn(|_| DelayLine::new()),
            high_pass: [OnePole::new(); 2],
            low_pass: [OnePole::new(); 2],
            bbd: [OnePole::new(); 2],
            bbd_g: one_pole_g(BBD_HZ, sample_rate),
            g_hp: 0.0,
            g_lp: 0.0,
            last_low_cut_hz: f32::NAN,
            last_tone_hz: f32::NAN,
            dry_gain: 1.0,
            wet_gain: 0.0,
            last_mix: f32::NAN,
            enabled: true,
            inv_sample_rate: 1.0 / sample_rate as f64,
            frames_per_ms: sample_rate / 1000.0,
        };
        device.prepare(sample_rate, 4_096);
        device
    }

    /// Rate in Hz: the synced division when Sync isn't Off, else the (smoothed) free Rate.
    #[inline]
    fn effective_rate(&self, sync_seconds: Option<f64>, free_hz: f32) -> f32 {
        match sync_seconds {
            Some(seconds) => (1.0 / seconds) as f32,
            None => free_hz,
        }
    }

    /// Sum of the mode's voices from the delay lines, as a stereo wet pair.
    ///
    /// `voice_delay_frames` is the reference for the mathematics; this fast path is the same
    /// formula, with the sine voicing's three voices built from one `sin`/`cos` pair.
    #[inline]
    fn mode_wet(
        &self,
        mode: ChorusMode,
        base_frames: f32,
        depth01: f32,
        lfo_phase: f64,
        vibrato_phase: f64,
    ) -> (f32, f32) {
        let vibrato_amp = mode.vibrato_amp();
        let vibrato = if vibrato_amp > 0.0 {
            vibrato_amp * sine_cycles(vibrato_phase)
        } else {
            0.0
        };
        let sine_offsets = mode.sine_offsets();
        let (sin_a, cos_a) = match sine_offsets {
            Some(_) => sin_cos_cycles(lfo_phase),
            None => (0.0, 0.0),
        };
        let scale = mode.depth_scale();

        let (mut left, mut right) = (0.0, 0.0);
        for (v, spec) in mode.voices().iter().enumerate() {
            let main = match sine_offsets {
                Some(offsets) => {
                    let (cos_offset, sin_offset) = offsets[v];
                    sin_a * cos_offset + cos_a * sin_offset
                }
                None => lfo_value(mode.shape(), lfo_phase + spec.phase),
            };
            let m = (main + vibrato).clamp(-1.0, 1.0);
            let delay = (base_frames * (1.0 + depth01 * scale * m)).max(MIN_HERMITE_DELAY);
            let sample = self.lines[spec.source].read_hermite(delay);
            left += spec.left * sample;
            right += spec.right * sample;
        }
        let gain = mode.wet_gain();
        (left * gain, right * gain)
    }

    /// How much Dimension colour to apply right now (1 during the voicing, fading at its edges).
    #[inline]
    fn dimension_weight(&self) -> f32 {
        let current = self.mode == ChorusMode::Dimension;
        match self.prev_mode {
            None => {
                if current {
                    1.0
                } else {
                    0.0
                }
            }
            Some(prev) => {
                let prev_dim = prev == ChorusMode::Dimension;
                match (prev_dim, current) {
                    (true, false) => 1.0 - self.fade,
                    (false, true) => self.fade,
                    _ => 0.0,
                }
            }
        }
    }

    fn set_mode(&mut self, mode: ChorusMode) {
        if mode == self.mode {
            return;
        }
        self.prev_mode = Some(self.mode);
        self.mode = mode;
        self.fade = 0.0;
    }

    /// Force the next sample to recompute the filter gains and the dry/wet gains (reset, rate
    /// change, tests).
    fn invalidate_coefficients(&mut self) {
        self.last_low_cut_hz = f32::NAN;
        self.last_tone_hz = f32::NAN;
        self.last_mix = f32::NAN;
    }

    /// Put every smoothed value on its target (reset, tests).
    fn snap_all(&mut self) {
        let smoothed = [
            &mut self.delay_ms,
            &mut self.depth,
            &mut self.rate,
            &mut self.tone_hz,
            &mut self.low_cut_hz,
            &mut self.feedback,
            &mut self.width,
            &mut self.mix,
        ];
        for param in smoothed {
            let target = param.target();
            param.snap(target);
        }
    }
}

impl AudioDevice for ChorusDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.enabled {
            pass_through(inputs, outputs, sample_count);
            return;
        }

        let sample_rate = self.sample_rate;
        let sync = self.params.real(SYNC).unwrap_or(0.0) as usize;
        let sync_seconds = division_seconds(sync, self.tempo);
        let frames = sample_count
            .min(inputs.len() / 2)
            .min(outputs.len() / 2);

        let g_bbd = self.bbd_g;
        let frames_per_ms = self.frames_per_ms;
        let inv_sample_rate = self.inv_sample_rate;
        // Dimension's extra colour only runs while that voicing is in play.
        let dimension_active = self.mode == ChorusMode::Dimension
            || self.prev_mode == Some(ChorusMode::Dimension);

        for i in 0..frames {
            let dry_l = inputs[i * 2];
            let dry_r = inputs[i * 2 + 1];

            let delay_ms = self.delay_ms.next();
            let depth01 = self.depth.next();
            let tone_hz = self.tone_hz.next();
            let low_cut_hz = self.low_cut_hz.next();
            let feedback = self.feedback.next();
            let width = self.width.next();
            let mix = self.mix.next();
            let free_hz = self.rate.next();

            let lfo_phase = self.lfo.phase;
            let vibrato_phase = self.vibrato_phase;
            let base_frames = delay_ms * frames_per_ms;

            let (mut wet_l, mut wet_r) =
                self.mode_wet(self.mode, base_frames, depth01, lfo_phase, vibrato_phase);
            if let Some(prev) = self.prev_mode {
                let t = self.fade;
                let (prev_l, prev_r) =
                    self.mode_wet(prev, base_frames, depth01, lfo_phase, vibrato_phase);
                wet_l = prev_l + (wet_l - prev_l) * t;
                wet_r = prev_r + (wet_r - prev_r) * t;
            }

            if dimension_active {
                let dim = self.dimension_weight();
                let soft_l = soft_clip(self.bbd[0].lowpass(wet_l, g_bbd));
                let soft_r = soft_clip(self.bbd[1].lowpass(wet_r, g_bbd));
                wet_l += (soft_l - wet_l) * dim;
                wet_r += (soft_r - wet_r) * dim;
            }

            // Tone: Low Cut keeps the bass out of the wet path, Tone softens the top.
            if low_cut_hz != self.last_low_cut_hz {
                self.last_low_cut_hz = low_cut_hz;
                self.g_hp = one_pole_g(low_cut_hz, sample_rate);
            }
            if tone_hz != self.last_tone_hz {
                self.last_tone_hz = tone_hz;
                self.g_lp = one_pole_g(tone_hz, sample_rate);
            }
            let (g_hp, g_lp) = (self.g_hp, self.g_lp);
            let wet_l = self.low_pass[0].lowpass(self.high_pass[0].highpass(wet_l, g_hp), g_lp);
            let wet_r = self.low_pass[1].lowpass(self.high_pass[1].highpass(wet_r, g_hp), g_lp);

            // The feedback loop taps the wet before Width (so Width can't multiply it).
            self.lines[0].push(dry_l + feedback * wet_l);
            self.lines[1].push(dry_r + feedback * wet_r);

            let mid = (wet_l + wet_r) * 0.5;
            let side = (wet_l - wet_r) * 0.5 * width;
            let wet_l = mid + side;
            let wet_r = mid - side;

            if mix != self.last_mix {
                self.last_mix = mix;
                let (dry, wet) = dry_wet_gains(mix, MixLaw::EqualPower);
                self.dry_gain = dry;
                self.wet_gain = wet;
            }
            let (dry_gain, wet_gain) = (self.dry_gain, self.wet_gain);
            let (out_l, out_r) = if wet_gain == 0.0 {
                (dry_l, dry_r)
            } else {
                (
                    dry_gain * dry_l + wet_gain * wet_l,
                    dry_gain * dry_r + wet_gain * wet_r,
                )
            };

            outputs[i * 2] = out_l;
            outputs[i * 2 + 1] = out_r;

            let rate_hz = self.effective_rate(sync_seconds, free_hz) as f64 * inv_sample_rate;
            self.lfo.advance(rate_hz);
            self.vibrato_phase =
                (self.vibrato_phase + VIBRATO_MULT * rate_hz).fract();

            if self.prev_mode.is_some() {
                self.fade += self.fade_step;
                if self.fade >= 1.0 {
                    self.fade = 1.0;
                    self.prev_mode = None;
                }
            }
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        let Some((_, real)) = self.params.set(param_id, value) else {
            return;
        };
        match param_id {
            MODE => self.set_mode(ChorusMode::from_index(real as usize)),
            RATE => self.rate.set_target(real),
            DEPTH => self.depth.set_target(real / 100.0),
            DELAY => self.delay_ms.set_target(real),
            FEEDBACK => self.feedback.set_target(real / 100.0),
            TONE => self.tone_hz.set_target(real),
            LOW_CUT => self.low_cut_hz.set_target(real),
            WIDTH => self.width.set_target(real / 100.0),
            MIX => self.mix.set_target(real / 100.0),
            _ => {}
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.params.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.chorus"
    }

    fn device_name(&self) -> &str {
        "Chorus"
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
        if transport.tempo > 0.0 {
            self.tempo = transport.tempo;
        }
    }

    fn reset(&mut self) {
        self.lines[0].clear();
        self.lines[1].clear();
        self.high_pass = [OnePole::new(); 2];
        self.low_pass = [OnePole::new(); 2];
        self.bbd = [OnePole::new(); 2];
        self.lfo.phase = 0.0;
        self.vibrato_phase = 0.0;
        self.prev_mode = None;
        self.fade = 1.0;
        self.invalidate_coefficients();
        self.snap_all();
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        for line in &mut self.lines {
            line.prepare_seconds(MAX_DELAY_SECONDS, sample_rate);
        }
        self.high_pass = [OnePole::new(); 2];
        self.low_pass = [OnePole::new(); 2];
        self.bbd = [OnePole::new(); 2];
        self.bbd_g = one_pole_g(BBD_HZ, sample_rate);
        self.inv_sample_rate = 1.0 / sample_rate as f64;
        self.frames_per_ms = sample_rate / 1000.0;
        self.invalidate_coefficients();
        self.fade_step = 1.0 / (MODE_FADE_MS * 0.001 * sample_rate).max(1.0);
        self.delay_ms.set_ramp(sample_rate, DELAY_RAMP_MS);
        for param in [
            &mut self.depth,
            &mut self.rate,
            &mut self.tone_hz,
            &mut self.low_cut_hz,
            &mut self.feedback,
            &mut self.width,
            &mut self.mix,
        ] {
            param.set_ramp(sample_rate, SMOOTH_RAMP_MS);
        }
    }

    fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{
        left, peak, pink_noise, render, right, rms, sine, stereo, to_db,
    };
    use crate::audio::devices::{enum_to_norm, real_to_norm, ParamType};

    const SR: f32 = 48_000.0;
    const BASE_MS: f32 = 7.0;
    const BASE_FRAMES: f32 = BASE_MS * SR / 1000.0;

    fn device() -> ChorusDevice {
        ChorusDevice::new(SR)
    }

    /// Set a parameter by real value (index for enums), then settle the smoothers.
    fn set_real(device: &mut ChorusDevice, id: ParamId, real: f32) {
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

    fn all_modes() -> [(ChorusMode, f32); 3] {
        [
            (ChorusMode::Classic, 0.0),
            (ChorusMode::Dimension, 1.0),
            (ChorusMode::Ensemble, 2.0),
        ]
    }

    /// A device set up for a clean delay measurement: pure wet, slow LFO, filters wide open.
    fn measurement_device(mode_index: f32, depth: f32) -> ChorusDevice {
        let mut device = device();
        set_real(&mut device, MODE, mode_index);
        set_real(&mut device, RATE, 0.02);
        set_real(&mut device, DEPTH, depth);
        set_real(&mut device, DELAY, BASE_MS);
        set_real(&mut device, FEEDBACK, 0.0);
        set_real(&mut device, MIX, 100.0);
        set_real(&mut device, LOW_CUT, 20.0);
        set_real(&mut device, TONE, 20_000.0);
        // Selecting the voicing started a crossfade; finish it so the delays are pure.
        device.prev_mode = None;
        device.fade = 1.0;
        device
    }

    /// Peak lag of channel `ch` after a mono impulse: the voice's read delay in frames.
    fn impulse_delay(device: &mut ChorusDevice, ch: usize) -> f32 {
        let frames = 4_000;
        let mut input = vec![0.0; frames * 2];
        input[0] = 1.0;
        input[1] = 1.0;
        let mut output = vec![0.0; frames * 2];
        device.process_block(&input, &mut output, frames);
        let mut best = 0;
        let mut best_value = 0.0f32;
        for n in 0..frames {
            let value = output[n * 2 + ch].abs();
            if value > best_value {
                best_value = value;
                best = n;
            }
        }
        best as f32
    }

    /// Delay of channel `ch` with the LFO parked at `phase`.
    fn delay_at(mode_index: f32, phase: f64, ch: usize) -> f32 {
        let mut device = measurement_device(mode_index, 100.0);
        device.lfo.phase = phase;
        device.vibrato_phase = 0.0;
        impulse_delay(&mut device, ch)
    }

    fn max_step(signal: &[f32]) -> f32 {
        signal
            .windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0f32, f32::max)
    }

    #[test]
    fn voice_phase_offsets_are_the_documented_ones() {
        let phases = |mode: ChorusMode| -> Vec<f64> {
            mode.voices().iter().map(|v| v.phase).collect()
        };
        assert_eq!(phases(ChorusMode::Classic), vec![0.0, 0.25]);
        assert_eq!(phases(ChorusMode::Dimension), vec![0.0, 0.5]);
        let ensemble = phases(ChorusMode::Ensemble);
        assert_eq!(ensemble.len(), 3);
        assert!((ensemble[1] - 1.0 / 3.0).abs() < 1e-12);
        assert!((ensemble[2] - 2.0 / 3.0).abs() < 1e-12);
    }

    #[test]
    fn classic_channels_are_in_quadrature() {
        // At LFO phase 0 the L voice sits at the base delay and the R voice (90° ahead) is at
        // the top of its swing.
        let l = delay_at(0.0, 0.0, 0);
        let r = delay_at(0.0, 0.0, 1);
        let top = BASE_FRAMES * (1.0 + ChorusMode::Classic.depth_scale());
        assert!((l - BASE_FRAMES).abs() <= 2.0, "L delay {l}");
        assert!((r - top).abs() <= 2.0, "R delay {r} (expected {top})");

        // A quarter cycle later the roles are swapped: the L voice is at the top.
        let l2 = delay_at(0.0, 0.25, 0);
        assert!((l2 - top).abs() <= 2.0, "L delay at 0.25 {l2}");
    }

    #[test]
    fn dimension_channels_are_anti_phase() {
        // Both voices start together...
        let l0 = delay_at(1.0, 0.0, 0);
        let r0 = delay_at(1.0, 0.0, 1);
        assert!((l0 - BASE_FRAMES).abs() <= 2.0, "L {l0}");
        assert!((r0 - BASE_FRAMES).abs() <= 2.0, "R {r0}");

        // ...and a quarter cycle later they are at opposite ends of the swing.
        let l = delay_at(1.0, 0.25, 0);
        let r = delay_at(1.0, 0.25, 1);
        let swing = BASE_FRAMES * ChorusMode::Dimension.depth_scale();
        assert!((l - (BASE_FRAMES + swing)).abs() <= 2.0, "L {l}");
        assert!((r - (BASE_FRAMES - swing)).abs() <= 2.0, "R {r}");
        assert!(
            (l + r - 2.0 * BASE_FRAMES).abs() <= 4.0,
            "not anti-phase: L {l} + R {r}"
        );
    }

    #[test]
    fn ensemble_voices_are_120_degrees_apart() {
        // R's dominant voice is a third of a cycle ahead of L's, so R at phase p takes the same
        // delay as L a third of a cycle later.
        for p in [0.0, 0.2, 0.4, 0.6] {
            let r = delay_at(2.0, p, 1);
            let l_later = delay_at(2.0, p + 1.0 / 3.0, 0);
            assert!(
                (r - l_later).abs() <= 3.0,
                "phase {p}: R {r}, L at p+1/3 {l_later}"
            );
        }
    }

    #[test]
    fn delay_swing_matches_depth_and_mode_range() {
        for (mode, index) in all_modes() {
            let mut low = f32::MAX;
            let mut high = f32::MIN;
            for k in 0..8 {
                let phase = k as f64 / 8.0;
                let measured = delay_at(index, phase, 0);
                let expected = voice_delay_frames(mode, 0, BASE_FRAMES, 1.0, phase, 0.0);
                assert!(
                    (measured - expected).abs() <= 2.0,
                    "{mode:?} at {phase}: measured {measured}, expected {expected}"
                );
                low = low.min(measured);
                high = high.max(measured);
            }
            let expected_swing = 2.0 * BASE_FRAMES * mode.depth_scale();
            assert!(
                (high - low - expected_swing).abs() <= 20.0,
                "{mode:?}: swing {} (expected {expected_swing})",
                high - low
            );
        }
    }

    #[test]
    fn mono_sum_stays_within_3_db_per_mode() {
        for (mode, index) in all_modes() {
            let mut device = device();
            set_real(&mut device, MODE, index);
            set_real(&mut device, WIDTH, 100.0);
            let mono = pink_noise(SR as usize, 0.5, 5);
            let output = render(&mut device, &stereo(&mono), &[512]);
            let l = left(&output);
            let r = right(&output);
            let summed: Vec<f32> = l.iter().zip(&r).map(|(a, b)| (a + b) * 0.5).collect();
            let ratio = to_db(rms(&summed) / ((rms(&l) + rms(&r)) * 0.5));
            assert!(ratio > -3.0, "{mode:?}: mono sum is {ratio} dB");
        }
    }

    #[test]
    fn depth_zero_is_a_static_base_delay() {
        let mut device = measurement_device(0.0, 0.0);
        let before = impulse_delay(&mut device, 0);
        device.lfo.phase = 0.25;
        let after = impulse_delay(&mut device, 0);
        // Depth 0 leaves only the base delay, whatever the LFO does.
        assert!((before - BASE_FRAMES).abs() <= 2.0, "{before}");
        assert!((after - BASE_FRAMES).abs() <= 2.0, "{after}");
    }

    #[test]
    fn changing_delay_never_jumps() {
        let mut device = device();
        set_real(&mut device, DEPTH, 0.0);
        set_real(&mut device, MIX, 100.0);
        set_real(&mut device, LOW_CUT, 20.0);
        set_real(&mut device, TONE, 20_000.0);

        let frames = SR as usize;
        let mono = sine(30.0, SR, frames, 0.5);
        let input = stereo(&mono);
        let mut output = vec![0.0; frames * 2];

        let delay_info = device.parameters().into_iter().find(|p| p.id == DELAY).unwrap();
        let big = real_to_norm(
            30.0,
            delay_info.min,
            delay_info.max,
            delay_info.is_logarithmic,
            delay_info.skew,
        );
        let mut pos = 0;
        while pos < frames {
            let n = 512.min(frames - pos);
            if pos == frames / 2 {
                // Deliberately do *not* settle the smoother: this is the step the glide hides.
                device.set_parameter(DELAY, big);
            }
            device.process_block(&input[pos * 2..(pos + n) * 2], &mut output[pos * 2..(pos + n) * 2], n);
            pos += n;
        }

        let input_step = max_step(&mono);
        let output_step = max_step(&left(&output));
        assert!(
            output_step < input_step * 8.0,
            "output steps by {output_step} (input {input_step})"
        );
    }

    #[test]
    fn feedback_90_percent_stays_bounded() {
        let mut device = device();
        set_real(&mut device, FEEDBACK, 90.0);
        let mono = pink_noise(SR as usize * 5, 0.5, 3);
        let output = render(&mut device, &stereo(&mono), &[256]);
        let p = peak(&output);
        assert!(p.is_finite() && p < 10.0, "peak {p}");

        // With the input gone the loop rings down.
        let tail = render(&mut device, &vec![0.0; SR as usize * 4], &[256]);
        assert!(peak(&tail) < 10.0, "tail peaks at {}", peak(&tail));
        let last_second = &tail[tail.len() - SR as usize * 2..];
        assert!(
            peak(last_second) < 0.02,
            "still at {} after 1 s of silence",
            peak(last_second)
        );
    }

    #[test]
    fn mode_change_crossfades_without_a_jump() {
        let mut device = device();
        set_real(&mut device, MIX, 100.0);
        let frames = SR as usize / 2;
        let mono = sine(220.0, SR, frames, 0.5);
        let input = stereo(&mono);
        let mut output = vec![0.0; frames * 2];

        let switch = frames / 2;
        let mode_info = device.parameters().into_iter().find(|p| p.id == MODE).unwrap();
        let ensemble = enum_to_norm(2, mode_info.enum_values.len());
        let mut pos = 0;
        while pos < frames {
            let n = 256.min(frames - pos);
            if pos == switch {
                device.set_parameter(MODE, ensemble);
            }
            device.process_block(&input[pos * 2..(pos + n) * 2], &mut output[pos * 2..(pos + n) * 2], n);
            pos += n;
        }

        // The crossfade region must not add a step beyond the signal's own slope.
        let region = &left(&output)[switch - 256..switch + 256];
        assert!(
            max_step(region) < max_step(&mono) * 8.0,
            "crossfade steps by {}",
            max_step(region)
        );
    }

    #[test]
    #[ignore = "CPU measurement: cargo test --release cpu_chorus -- --ignored --nocapture"]
    fn cpu_chorus() {
        const FRAMES: usize = 256;
        const SECONDS: usize = 10;
        const REPEATS: usize = 5;
        let mut device = device();
        let mut output = vec![0.0; FRAMES * 2];
        // A quiet sine keeps the filters and the delay lines busy without clipping.
        let input = stereo(&sine(220.0, SR, FRAMES, 0.1));
        let blocks = (SR as usize * SECONDS) / FRAMES;
        for (index, name) in [(0.0, "Classic"), (1.0, "Dimension"), (2.0, "Ensemble")] {
            set_real(&mut device, MODE, index);
            device.prev_mode = None;
            device.fade = 1.0;
            let mut best = f64::MAX;
            for _ in 0..REPEATS {
                // Warm up, so the first block's cache misses don't count.
                for _ in 0..64 {
                    device.process_block(&input, &mut output, FRAMES);
                }
                let start = std::time::Instant::now();
                for _ in 0..blocks {
                    device.process_block(&input, &mut output, FRAMES);
                }
                best = best.min(start.elapsed().as_secs_f64());
            }
            println!(
                "{name}: {SECONDS} s rendered in {best:.3} s: {:.2} % of one core (best of {REPEATS})",
                best / SECONDS as f64 * 100.0
            );
        }
    }
}
