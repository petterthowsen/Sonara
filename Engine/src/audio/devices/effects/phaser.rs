//! Phaser effect (spec 012, Phase 6).
//!
//! A chain of first-order TPT all-pass stages ([`OnePole::allpass`]) whose cutoffs sweep with an
//! LFO and an envelope follower. Each stage's coefficient is
//! `Sweep × 2^(LFO·Depth + Env·Amount) × spread offset`, recomputed exactly once per 8 frames and
//! interpolated between, as PolySynth does for its filter. Feedback runs from the last stage back
//! to the input through a one-sample delay and a soft clip. Depth 0 with Amount 0 gives a static,
//! fully manual phaser (the research's most repeated request).
//!
//! The chain is always built for [`MAX_STAGES`] stages; a stage that the current Stages count
//! leaves out is bypassed by blending its output back to its input, and the blend ramps over a few
//! milliseconds so changing Stages doesn't click (decision 8). That keeps one set of filter states
//! and makes the switch a smooth fade between "N stages" and "M stages".

use super::effect::{pass_through, TailSleep};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
};
use crate::audio::dsp::env_follower::{Detection, EnvFollower};
use crate::audio::dsp::gain::{dry_wet_gains, MixLaw};
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::dsp::tempo_sync::{beats_to_hz, sync_beats, SYNC_CHOICES};
use crate::audio::modulation::lfo::{Lfo, LfoShape};
use crate::audio::transport::Transport;

pub const STAGES: ParamId = 0;
pub const SWEEP: ParamId = 1;
pub const SPREAD: ParamId = 2;
pub const FEEDBACK: ParamId = 3;

pub const LFO_SHAPE: ParamId = 10;
pub const LFO_RATE: ParamId = 11;
pub const LFO_SYNC: ParamId = 12;
pub const LFO_DEPTH: ParamId = 13;
pub const LFO_STEREO_PHASE: ParamId = 14;

pub const ENV_AMOUNT: ParamId = 20;
pub const ENV_ATTACK: ParamId = 21;
pub const ENV_RELEASE: ParamId = 22;

pub const LOW_CUT: ParamId = 30;
pub const HIGH_CUT: ParamId = 31;

pub const MIX: ParamId = 40;

/// Stage counts for the Stages enum, in choice order.
const STAGE_CHOICES: &[&str] = &["2", "4", "6", "8", "12"];
const STAGE_COUNTS: [usize; 5] = [2, 4, 6, 8, 12];
const SHAPES: &[&str] = &["Sine", "Triangle"];

/// All-pass stages the chain is always built for.
const MAX_STAGES: usize = 12;
/// The cutoff coefficient is recomputed exactly once per this many frames and interpolated
/// between (PolySynth's control block).
const CONTROL_BLOCK: usize = 8;
/// Ramp for the per-stage blend when Stages changes.
const STAGE_FADE_MS: f32 = 5.0;
/// Octaves spanned by Spread at 100 %.
const SPREAD_OCTAVES: f32 = 2.0;

#[rustfmt::skip]
const PHASER_SPECS: [ParamSpec; 4] = [
    spec(STAGES, "Stages", "Phaser", "", Kind::Enum(STAGE_CHOICES), 2.0),
    spec(SWEEP, "Sweep", "Phaser", "Hz", log(20.0, 16_000.0), 800.0),
    spec(SPREAD, "Spread", "Phaser", "%", linear(0.0, 100.0), 0.0),
    spec(FEEDBACK, "Feedback", "Phaser", "%", linear(-95.0, 95.0), 40.0),
];

#[rustfmt::skip]
const LFO_SPECS: [ParamSpec; 5] = [
    spec(LFO_SHAPE, "Shape", "LFO", "", Kind::Enum(SHAPES), 0.0),
    spec(LFO_RATE, "Rate", "LFO", "Hz", log(0.01, 20.0), 0.3),
    spec(LFO_SYNC, "Sync", "LFO", "", Kind::Enum(SYNC_CHOICES), 0.0),
    spec(LFO_DEPTH, "Depth", "LFO", "oct", linear(0.0, 6.0), 2.0),
    spec(LFO_STEREO_PHASE, "Stereo Phase", "LFO", "°", linear(0.0, 180.0), 90.0),
];

#[rustfmt::skip]
const ENVELOPE_SPECS: [ParamSpec; 3] = [
    spec(ENV_AMOUNT, "Amount", "Envelope", "oct", linear(-4.0, 4.0), 0.0),
    spec(ENV_ATTACK, "Attack", "Envelope", "ms", log(0.1, 100.0), 5.0),
    spec(ENV_RELEASE, "Release", "Envelope", "ms", log(5.0, 2_000.0), 200.0),
];

#[rustfmt::skip]
const TONE_SPECS: [ParamSpec; 2] = [
    spec(LOW_CUT, "Low Cut", "Tone", "Hz", log(20.0, 2_000.0), 20.0),
    spec(HIGH_CUT, "High Cut", "Tone", "Hz", log(1_000.0, 20_000.0), 20_000.0),
];

#[rustfmt::skip]
const OUTPUT_SPECS: [ParamSpec; 1] = [
    spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 50.0),
];

/// Number of real parameters.
pub const PARAM_COUNT: usize = 4 + 5 + 3 + 2 + 1;

/// Every parameter, in display order; a parameter's index here is its slot.
pub const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[
    &PHASER_SPECS,
    &LFO_SPECS,
    &ENVELOPE_SPECS,
    &TONE_SPECS,
    &OUTPUT_SPECS,
]);

const ID_SPACE: usize = 50;
const SLOT_OF: [u8; ID_SPACE] = slot_table(&SPECS);

/// The device's parameter table.
pub static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOT_OF);

/// Bounded soft clip for the feedback path: smooth, monotone and exactly ±1 at the clamp.
/// A cubic is far cheaper than `tanh` and the loop only needs it to stay bounded.
#[inline]
fn soft_clip(x: f32) -> f32 {
    let x = x.clamp(-1.5, 1.5);
    x - (4.0 / 27.0) * x * x * x
}

/// Spread multiplier for stage `i` of `count` stages: 1.0 at Spread 0, spanning
/// ±`SPREAD_OCTAVES`/2 octaves at Spread 1.
#[inline]
fn spread_mult(i: usize, count: usize, spread: f32) -> f32 {
    if spread <= 0.0 || count <= 1 {
        return 1.0;
    }
    let t = i as f32 / (count - 1) as f32 - 0.5;
    2f32.powf(spread * SPREAD_OCTAVES * t)
}

fn snap(p: &mut SmoothedParam) {
    p.snap(p.target());
}

/// One channel's all-pass chain plus its one-sample-delayed feedback.
#[derive(Clone, Copy)]
struct Chain {
    stages: [OnePole; MAX_STAGES],
    fb: f32,
}

impl Chain {
    fn new() -> Self {
        Self {
            stages: [OnePole::new(); MAX_STAGES],
            fb: 0.0,
        }
    }

    fn reset(&mut self) {
        for stage in self.stages.iter_mut() {
            stage.reset();
        }
        self.fb = 0.0;
    }
}

/// Phaser device: swept all-pass chain with LFO and envelope modulation, feedback and wet tone
/// controls.
pub struct PhaserDevice {
    sample_rate: f32,
    values: ParamValues<PARAM_COUNT>,

    sweep_oct: SmoothedParam,
    spread: SmoothedParam,
    feedback: SmoothedParam,
    depth: SmoothedParam,
    env_amount: SmoothedParam,
    mix: SmoothedParam,
    low_cut: SmoothedParam,
    high_cut: SmoothedParam,

    lfo: Lfo,
    shape: LfoShape,
    rate_hz: f32,
    sync_beats: Option<f64>,
    /// Right-channel LFO offset, in cycles.
    stereo_phase: f64,
    tempo: f64,
    playing: bool,
    song_pos_beats: f64,

    followers: [EnvFollower; 2],
    chains: [Chain; 2],
    tone_hp: [OnePole; 2],
    tone_lp: [OnePole; 2],

    stage_count: usize,
    /// Per-stage blend weight (0 bypassed, 1 active) and its per-frame step.
    w_cur: [f32; MAX_STAGES],
    w_step: [f32; MAX_STAGES],

    /// Per-channel, per-stage all-pass coefficient `g/(1+g)` and its per-frame step.
    gp_cur: [[f32; MAX_STAGES]; 2],
    gp_step: [[f32; MAX_STAGES]; 2],
    hp_cur: [f32; 2],
    hp_step: [f32; 2],
    lp_cur: [f32; 2],
    lp_step: [f32; 2],

    frames_to_control: usize,
    /// Equal-power Mix gains, recomputed with the coefficients (every control block).
    dry_gain: f32,
    wet_gain: f32,

    sleep: TailSleep,
    is_active: bool,
    is_enabled: bool,
}

impl PhaserDevice {
    pub fn new(sample_rate: f32) -> Self {
        let ramp = SmoothedParam::DEFAULT_RAMP_MS;
        let mut device = Self {
            sample_rate,
            values: ParamValues::new(&TABLE),
            sweep_oct: SmoothedParam::new(800.0f32.log2(), sample_rate, ramp),
            spread: SmoothedParam::new(0.0, sample_rate, ramp),
            feedback: SmoothedParam::new(0.4, sample_rate, ramp),
            depth: SmoothedParam::new(2.0, sample_rate, ramp),
            env_amount: SmoothedParam::new(0.0, sample_rate, ramp),
            mix: SmoothedParam::new(0.5, sample_rate, ramp),
            low_cut: SmoothedParam::new(20.0, sample_rate, ramp),
            high_cut: SmoothedParam::new(20_000.0, sample_rate, ramp),
            lfo: Lfo::default(),
            shape: LfoShape::Sine,
            rate_hz: 0.3,
            sync_beats: None,
            stereo_phase: 0.25,
            tempo: 120.0,
            playing: false,
            song_pos_beats: 0.0,
            followers: [
                EnvFollower::new(5.0, 200.0, sample_rate, Detection::Peak),
                EnvFollower::new(5.0, 200.0, sample_rate, Detection::Peak),
            ],
            chains: [Chain::new(); 2],
            tone_hp: [OnePole::new(); 2],
            tone_lp: [OnePole::new(); 2],
            stage_count: 0,
            w_cur: [0.0; MAX_STAGES],
            w_step: [0.0; MAX_STAGES],
            gp_cur: [[0.0; MAX_STAGES]; 2],
            gp_step: [[0.0; MAX_STAGES]; 2],
            hp_cur: [0.0; 2],
            hp_step: [0.0; 2],
            lp_cur: [0.0; 2],
            lp_step: [0.0; 2],
            frames_to_control: 0,
            dry_gain: 1.0,
            wet_gain: 0.0,
            sleep: TailSleep::new(sample_rate),
            is_active: true,
            is_enabled: true,
        };
        for spec in SPECS.iter() {
            device.apply(spec.id, spec.default);
        }
        device.snap_all();
        device
    }

    /// Decode a real parameter value into the fields it drives.
    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            STAGES => {
                let index = (real as usize).min(STAGE_COUNTS.len() - 1);
                self.set_stage_count(STAGE_COUNTS[index]);
            }
            SWEEP => self.sweep_oct.set_target(real.max(1.0).log2()),
            SPREAD => self.spread.set_target(real / 100.0),
            FEEDBACK => self.feedback.set_target(real / 100.0),
            LFO_SHAPE => {
                self.shape = if real as usize == 0 {
                    LfoShape::Sine
                } else {
                    LfoShape::Triangle
                }
            }
            LFO_RATE => self.rate_hz = real,
            LFO_SYNC => self.sync_beats = sync_beats(real as usize),
            LFO_DEPTH => self.depth.set_target(real),
            LFO_STEREO_PHASE => self.stereo_phase = (real / 360.0) as f64,
            ENV_AMOUNT => self.env_amount.set_target(real),
            ENV_ATTACK | ENV_RELEASE => self.update_env_times(),
            LOW_CUT => self.low_cut.set_target(real),
            HIGH_CUT => self.high_cut.set_target(real),
            MIX => self.mix.set_target(real / 100.0),
            _ => {}
        }
    }

    /// Ramp the stage blend weights so a Stages change fades rather than jumps.
    fn set_stage_count(&mut self, count: usize) {
        let count = count.clamp(2, MAX_STAGES);
        if count == self.stage_count {
            return;
        }
        self.stage_count = count;
        let frames = (STAGE_FADE_MS * 0.001 * self.sample_rate).max(1.0);
        for i in 0..MAX_STAGES {
            let target = if i < count { 1.0 } else { 0.0 };
            self.w_step[i] = (target - self.w_cur[i]) / frames;
        }
    }

    fn update_env_times(&mut self) {
        let attack = self.values.real(ENV_ATTACK).unwrap_or(5.0);
        let release = self.values.real(ENV_RELEASE).unwrap_or(200.0);
        for follower in self.followers.iter_mut() {
            follower.set_times(attack, release, self.sample_rate);
        }
    }

    fn reset_dsp(&mut self) {
        for chain in self.chains.iter_mut() {
            chain.reset();
        }
        for filter in self.tone_hp.iter_mut() {
            filter.reset();
        }
        for filter in self.tone_lp.iter_mut() {
            filter.reset();
        }
        for follower in self.followers.iter_mut() {
            follower.reset();
        }
    }

    /// Snap the smoothed values, the stage blend and the coefficients to their targets (init and
    /// rate changes), so the device starts settled.
    fn snap_all(&mut self) {
        snap(&mut self.sweep_oct);
        snap(&mut self.spread);
        snap(&mut self.feedback);
        snap(&mut self.depth);
        snap(&mut self.env_amount);
        snap(&mut self.mix);
        snap(&mut self.low_cut);
        snap(&mut self.high_cut);
        for i in 0..MAX_STAGES {
            self.w_cur[i] = if i < self.stage_count { 1.0 } else { 0.0 };
            self.w_step[i] = 0.0;
        }
        self.recompute_g(true);
        self.frames_to_control = 0;
    }

    /// The LFO rate in Hz, synced to the tempo when Sync is not Off.
    fn lfo_rate_hz(&self) -> f64 {
        match self.sync_beats {
            Some(beats) => beats_to_hz(beats, self.tempo),
            None => self.rate_hz as f64,
        }
    }

    /// Compute the all-pass and tone coefficients. `snap` sets them outright (init); otherwise it
    /// steps toward them over the control block. The stage coefficient is stored as
    /// `gp = g / (1 + g)` (see [`OnePole::allpass_g`]), so the audio loop never divides.
    fn recompute_g(&mut self, snap: bool) {
        let sr = self.sample_rate;
        let sweep_oct = self.sweep_oct.current();
        let spread = self.spread.current();
        let depth = self.depth.current();
        let amount = self.env_amount.current();
        let (shape, stereo) = (self.shape, self.stereo_phase);
        let count = self.stage_count;
        for ch in 0..2 {
            let offset = if ch == 0 { 0.0 } else { stereo };
            let lfo = self.lfo.value_at(shape, offset);
            let env = self.followers[ch].value();
            let base = 2f32.powf(sweep_oct + lfo * depth + env * amount);
            let set = |g: f32, cur: &mut f32, step: &mut f32| {
                let gp = g / (1.0 + g);
                if snap {
                    *cur = gp;
                    *step = 0.0;
                } else {
                    *step = (gp - *cur) / CONTROL_BLOCK as f32;
                }
            };
            if spread <= 0.0 {
                // Every stage sits on Sweep: one coefficient for the whole chain.
                let g = one_pole_g(base, sr);
                for i in 0..MAX_STAGES {
                    set(g, &mut self.gp_cur[ch][i], &mut self.gp_step[ch][i]);
                }
            } else {
                for i in 0..MAX_STAGES {
                    let g = one_pole_g(base * spread_mult(i, count, spread), sr);
                    set(g, &mut self.gp_cur[ch][i], &mut self.gp_step[ch][i]);
                }
            }
            let hp = one_pole_g(self.low_cut.current(), sr);
            let lp = one_pole_g(self.high_cut.current(), sr);
            if snap {
                self.hp_cur[ch] = hp;
                self.hp_step[ch] = 0.0;
                self.lp_cur[ch] = lp;
                self.lp_step[ch] = 0.0;
            } else {
                self.hp_step[ch] = (hp - self.hp_cur[ch]) / CONTROL_BLOCK as f32;
                self.lp_step[ch] = (lp - self.lp_cur[ch]) / CONTROL_BLOCK as f32;
            }
        }
        let (dry, wet) = dry_wet_gains(self.mix.current(), MixLaw::EqualPower);
        self.dry_gain = dry;
        self.wet_gain = wet;
    }

    /// The 8-frame control update: new coefficients and one LFO step.
    fn update_control(&mut self) {
        self.recompute_g(false);
        let rate = self.lfo_rate_hz();
        self.lfo
            .advance(rate * CONTROL_BLOCK as f64 / self.sample_rate as f64);
    }

    /// One frame of both channels: feedback, the all-pass chain, the wet tone filters. The two
    /// channels share the stage loop so their independent divisions pipeline.
    #[inline]
    fn process_frame(&mut self, x: [f32; 2], feedback: f32) -> [f32; 2] {
        let mut s = [
            x[0] + soft_clip(self.chains[0].fb),
            x[1] + soft_clip(self.chains[1].fb),
        ];
        {
            let (left, right) = self.chains.split_at_mut(1);
            let (c0, c1) = (&mut left[0], &mut right[0]);
            for i in 0..MAX_STAGES {
                let ap0 = c0.stages[i].allpass_g(s[0], self.gp_cur[0][i]);
                let ap1 = c1.stages[i].allpass_g(s[1], self.gp_cur[1][i]);
                let w = self.w_cur[i];
                s[0] += w * (ap0 - s[0]);
                s[1] += w * (ap1 - s[1]);
            }
        }
        let mut out = [0.0f32; 2];
        for ch in 0..2 {
            self.chains[ch].fb = s[ch] * feedback;
            let (hp_g, lp_g) = (self.hp_cur[ch], self.lp_cur[ch]);
            let hp = self.tone_hp[ch].highpass(s[ch], hp_g);
            out[ch] = self.tone_lp[ch].lowpass(hp, lp_g);
        }
        out
    }
}

impl AudioDevice for PhaserDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.is_active || !self.is_enabled {
            pass_through(inputs, outputs, sample_count);
            return;
        }
        self.sleep.on_block(sample_count);
        let frames = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        for frame in 0..frames {
            // Smoothed parameters advance once per frame.
            self.mix.next();
            let feedback = self.feedback.next();
            self.sweep_oct.next();
            self.spread.next();
            self.depth.next();
            self.env_amount.next();
            self.low_cut.next();
            self.high_cut.next();

            if self.frames_to_control == 0 {
                self.update_control();
                self.frames_to_control = CONTROL_BLOCK;
            }
            self.frames_to_control -= 1;

            for i in 0..MAX_STAGES {
                self.w_cur[i] = (self.w_cur[i] + self.w_step[i]).clamp(0.0, 1.0);
            }
            for ch in 0..2 {
                for i in 0..MAX_STAGES {
                    self.gp_cur[ch][i] += self.gp_step[ch][i];
                }
                self.hp_cur[ch] += self.hp_step[ch];
                self.lp_cur[ch] += self.lp_step[ch];
            }

            let (dry_gain, wet_gain) = (self.dry_gain, self.wet_gain);
            let x = [inputs[frame * 2], inputs[frame * 2 + 1]];
            self.followers[0].process(x[0]);
            self.followers[1].process(x[1]);
            let wet = self.process_frame(x, feedback);
            outputs[frame * 2] = x[0] * dry_gain + wet[0] * wet_gain;
            outputs[frame * 2 + 1] = x[1] * dry_gain + wet[1] * wet_gain;
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        if let Some((_slot, real)) = self.values.set(param_id, value) {
            self.apply(param_id, real);
            self.sleep.wake();
        }
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        if let Some((_slot, real)) = self.values.set_offset(param_id, offset) {
            self.apply(param_id, real);
            self.sleep.wake();
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.values.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.phaser"
    }

    fn device_name(&self) -> &str {
        "Phaser"
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
        self.frames_to_control = 0;
    }

    fn set_transport(&mut self, transport: &Transport) {
        if transport.tempo > 0.0 {
            self.tempo = transport.tempo;
        }
        self.playing = transport.playing;
        self.song_pos_beats = transport.song_pos_beats;
        if self.playing {
            if let Some(beats) = self.sync_beats {
                self.lfo.phase = (self.song_pos_beats / beats).rem_euclid(1.0);
            }
        }
    }

    /// Resize for the new rate (the tail is cleared).
    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        self.sleep.set_sample_rate(sample_rate);
        for param in [
            &mut self.sweep_oct,
            &mut self.spread,
            &mut self.feedback,
            &mut self.depth,
            &mut self.env_amount,
            &mut self.mix,
            &mut self.low_cut,
            &mut self.high_cut,
        ] {
            param.set_ramp(sample_rate, SmoothedParam::DEFAULT_RAMP_MS);
        }
        self.update_env_times();
        self.snap_all();
        self.reset_dsp();
    }

    // === Lifecycle Management ===

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

    // === Bypass Control ===

    fn is_enabled(&self) -> bool {
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
    }

    // === Sleep/Wake System ===

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
    use crate::audio::devices::{enum_to_norm, real_to_norm};
    use crate::audio::dsp::test_util::{
        left, render, right, sine, stereo, to_db, tone_amplitude, white_noise,
    };

    const SR: f32 = 48_000.0;

    fn device() -> PhaserDevice {
        let mut device = PhaserDevice::new(SR);
        device.prepare(SR, 4_096);
        device
    }

    fn info(device: &PhaserDevice, id: ParamId) -> ParamInfo {
        device
            .parameters()
            .into_iter()
            .find(|p| p.id == id)
            .unwrap_or_else(|| panic!("no parameter {id}"))
    }

    fn set_real(device: &mut PhaserDevice, id: ParamId, real: f32) {
        let p = info(device, id);
        device.set_parameter(
            id,
            real_to_norm(real, p.min, p.max, p.is_logarithmic, p.skew),
        );
    }

    fn set_enum(device: &mut PhaserDevice, id: ParamId, index: usize) {
        let count = info(device, id).enum_values.len();
        device.set_parameter(id, enum_to_norm(index, count));
    }

    /// Steady-state gain at `freq`, measured over one whole number of cycles after a settling
    /// half. The device is linear, so the amplitude only affects the envelope follower.
    fn response_db(device: &mut PhaserDevice, freq: f32, amplitude: f32) -> f32 {
        let cycles = 20.0;
        let frames = ((SR as f64 * cycles / freq as f64).round() as usize).max(256);
        let input = sine(freq, SR, frames * 2, amplitude);
        let out = render(device, &stereo(&input), &[256]);
        let amp = tone_amplitude(&left(&out)[frames..], freq, SR);
        to_db(amp / amplitude)
    }

    /// The magnitude response over a log-spaced grid, as `(freq, db_left, db_right)`.
    fn scan(
        device: &mut PhaserDevice,
        f_lo: f32,
        f_hi: f32,
        points: usize,
    ) -> Vec<(f32, f32, f32)> {
        let ratio = (f_hi / f_lo).powf(1.0 / (points - 1) as f32);
        let mut out = Vec::with_capacity(points);
        let mut f = f_lo;
        for _ in 0..points {
            let cycles = 20.0;
            let frames = ((SR as f64 * cycles / f as f64).round() as usize).max(256);
            let input = sine(f, SR, frames * 2, 0.5);
            let rendered = render(device, &stereo(&input), &[256]);
            let l = tone_amplitude(&left(&rendered)[frames..], f, SR);
            let r = tone_amplitude(&right(&rendered)[frames..], f, SR);
            out.push((f, to_db(l / 0.5), to_db(r / 0.5)));
            f *= ratio;
        }
        out
    }

    fn first_notch(points: &[(f32, f32, f32)], channel: usize) -> Option<f32> {
        for i in 1..points.len().saturating_sub(1) {
            let (f, l, r) = points[i];
            let (db, prev, next) = if channel == 0 {
                (l, points[i - 1].1, points[i + 1].1)
            } else {
                (r, points[i - 1].2, points[i + 1].2)
            };
            if db < prev && db < next && db < -12.0 {
                return Some(f);
            }
        }
        None
    }

    fn notch_count(points: &[(f32, f32, f32)], channel: usize) -> usize {
        (1..points.len().saturating_sub(1))
            .filter(|&i| {
                let (_, l, r) = points[i];
                let (db, prev, next) = if channel == 0 {
                    (l, points[i - 1].1, points[i + 1].1)
                } else {
                    (r, points[i - 1].2, points[i + 1].2)
                };
                db < prev && db < next && db < -12.0
            })
            .count()
    }

    /// Frequency where the chain's total phase first reaches −180°, including the wet tone
    /// filters, which is where a 50 % equal-power mix first cancels: `stages` all-pass stages at
    /// `sweep`, then the low-cut high pass and the high-cut low pass.
    fn expected_first_notch(sweep: f32, stages: usize, low_cut: f32, high_cut: f32) -> f32 {
        let g = (std::f32::consts::PI * sweep / SR).tan();
        let phase = |f: f32| {
            let w = (std::f32::consts::PI * f / SR).tan() / g;
            -(stages as f32) * 2.0 * w.atan() + (low_cut / f).atan() - (f / high_cut).atan()
        };
        // `phase` falls monotonically through −π; bisect for the crossing.
        let (mut lo, mut hi) = (1.0f32, SR * 0.49);
        for _ in 0..60 {
            let mid = 0.5 * (lo + hi);
            if phase(mid) > -std::f32::consts::PI {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        0.5 * (lo + hi)
    }

    #[test]
    fn static_mix_50_has_stages_over_2_notches() {
        let mut device = device();
        set_enum(&mut device, STAGES, 2); // 6 stages
        set_real(&mut device, FEEDBACK, 0.0);
        set_real(&mut device, LFO_DEPTH, 0.0);
        set_real(&mut device, ENV_AMOUNT, 0.0);
        set_real(&mut device, SWEEP, 800.0);

        let points = scan(&mut device, 60.0, 6_000.0, 400);
        assert_eq!(notch_count(&points, 0), 3, "6 stages give 3 notches");
        let first = first_notch(&points, 0).expect("a first notch");
        let expected = expected_first_notch(800.0, 6, 20.0, 20_000.0);
        assert!(
            (first - expected).abs() / expected < 0.05,
            "first notch at {first} Hz, expected {expected} Hz"
        );

        // Each channel's notches are the same: the LFO contributes nothing at Depth 0.
        assert_eq!(notch_count(&points, 1), 3);
    }

    #[test]
    fn depth_zero_is_static() {
        let mut device = device();
        set_real(&mut device, LFO_DEPTH, 0.0);
        set_real(&mut device, ENV_AMOUNT, 0.0);
        set_real(&mut device, SWEEP, 800.0);
        set_real(&mut device, LFO_RATE, 1.0);

        let frames = SR as usize * 10;
        let input = sine(220.0, SR, frames, 0.5);
        let out = render(&mut device, &stereo(&input), &[512]);

        // 220 Hz over one second is a whole number of cycles.
        let second = |n: usize| {
            let chunk = &out[n * SR as usize * 2..(n + 1) * SR as usize * 2];
            let mono: Vec<f32> = chunk.iter().step_by(2).copied().collect();
            crate::audio::dsp::test_util::rms(&mono)
        };
        let first = second(1);
        for n in 2..10 {
            let rms = second(n);
            assert!(
                (rms - first).abs() / first < 1e-4,
                "second {n} at {rms}, first at {first}: Depth 0 must not move"
            );
        }
    }

    #[test]
    fn feedback_at_plus_minus_95_stays_bounded() {
        for feedback in [95.0, -95.0] {
            let mut device = device();
            set_real(&mut device, FEEDBACK, feedback);
            set_enum(&mut device, STAGES, 4); // 12 stages
            set_real(&mut device, LFO_DEPTH, 6.0);
            set_real(&mut device, ENV_AMOUNT, 4.0);

            let frames = SR as usize * 60;
            let input = stereo(&white_noise(frames, 0.8, 7));
            let out = render(&mut device, &input, &[512]);
            let peak = out.iter().fold(0.0f32, |m, x| m.max(x.abs()));
            assert!(peak < 3.0, "feedback {feedback} % peaked at {peak}");
            assert!(
                out.iter().all(|x| x.is_finite()),
                "feedback {feedback} % went non-finite"
            );
        }
    }

    #[test]
    fn env_amount_moves_the_notch_with_level() {
        let mut device = device();
        set_real(&mut device, LFO_DEPTH, 0.0);
        set_real(&mut device, ENV_AMOUNT, 4.0);
        set_real(&mut device, FEEDBACK, 0.0);
        set_real(&mut device, SWEEP, 800.0);

        // At the quiet level the notch sits on 220 Hz; at the loud level the envelope opens the
        // cutoff four octaves and the notch moves well above it.
        let quiet = response_db(&mut device, 220.0, 0.01);
        let loud = response_db(&mut device, 220.0, 0.9);
        assert!(
            loud - quiet > 10.0,
            "the notch should move with input level (quiet {quiet:.1} dB, loud {loud:.1} dB)"
        );
    }

    /// Steady-state L/R gain at `freq`, measured over one whole number of cycles after a
    /// settling half. Both channels are measured from the same render, so a drifting LFO hits
    /// them equally.
    fn response_pair(device: &mut PhaserDevice, freq: f32, amplitude: f32) -> (f32, f32) {
        let cycles = 10.0;
        let frames = ((SR as f64 * cycles / freq as f64).round() as usize).max(256);
        let input = sine(freq, SR, frames * 2, amplitude);
        let out = render(device, &stereo(&input), &[256]);
        let l = tone_amplitude(&left(&out)[frames..], freq, SR);
        let r = tone_amplitude(&right(&out)[frames..], freq, SR);
        (to_db(l / amplitude), to_db(r / amplitude))
    }

    #[test]
    fn stereo_phase_separates_the_notches() {
        let mut device = device();
        set_enum(&mut device, STAGES, 2);
        set_real(&mut device, FEEDBACK, 0.0);
        set_real(&mut device, LFO_DEPTH, 2.0);
        set_real(&mut device, LFO_STEREO_PHASE, 180.0);
        set_real(&mut device, LFO_RATE, 0.5);
        set_real(&mut device, MIX, 50.0);

        // Advance the LFO to phase 0.25: L's sine is +1 (cutoff ×4), R's is −1 (cutoff ÷4).
        let silence = vec![0.0f32; (SR as usize / 2) * 2];
        render(&mut device, &silence, &[512]);
        // Then freeze it: at 0.01 Hz the whole measurement drifts by a few hundredths of a cycle.
        set_real(&mut device, LFO_RATE, 0.01);

        // The static chain's first notch sits where the all-pass chain plus the wet tone filters
        // reach 180° of phase.
        let l_notch = expected_first_notch(3_200.0, 6, 20.0, 20_000.0);
        let r_notch = expected_first_notch(200.0, 6, 20.0, 20_000.0);
        let (l_at_l, r_at_l) = response_pair(&mut device, l_notch, 0.5);
        let (l_at_r, r_at_r) = response_pair(&mut device, r_notch, 0.5);
        assert!(
            l_at_l < -15.0 && r_at_l > l_at_l + 15.0,
            "L should notch at {l_notch} Hz (L {l_at_l:.1} dB, R {r_at_l:.1} dB)"
        );
        assert!(
            r_at_r < -15.0 && l_at_r > r_at_r + 15.0,
            "R should notch at {r_notch} Hz (L {l_at_r:.1} dB, R {r_at_r:.1} dB)"
        );
    }

    /// Worst case for the budget: 12 stages, LFO and envelope both sweeping, stereo.
    /// `cargo test --release cpu_phaser -- --ignored --nocapture`
    #[test]
    #[ignore = "CPU measurement, run in release"]
    fn cpu_phaser() {
        const FRAMES: usize = 256;
        let mut device = device();
        set_enum(&mut device, STAGES, 4); // 12 stages
        set_real(&mut device, LFO_DEPTH, 6.0);
        set_real(&mut device, ENV_AMOUNT, 4.0);
        set_real(&mut device, FEEDBACK, 80.0);

        let input = stereo(&white_noise(FRAMES, 0.5, 3));
        let mut out = vec![0.0; FRAMES * 2];
        // Warm up the caches and the CPU's clock before measuring.
        for _ in 0..(SR as usize * 10 / FRAMES) {
            device.process_block(&input, &mut out, FRAMES);
        }
        let seconds = 60usize;
        let blocks = SR as usize * seconds / FRAMES;
        let start = std::time::Instant::now();
        for _ in 0..blocks {
            device.process_block(&input, &mut out, FRAMES);
        }
        let elapsed = start.elapsed().as_secs_f64();
        println!(
            "{seconds} s rendered in {:.3} s: {:.3} % of one core",
            elapsed,
            elapsed / seconds as f64 * 100.0
        );
        assert!(
            elapsed / (seconds as f64) < 0.005,
            "12-stage stereo phaser took {:.3} % of a core",
            elapsed / seconds as f64 * 100.0
        );
    }

    /// Regenerates the SimpleView fixture the Godot layout test reads.
    /// `cargo test --lib dump_phaser_view_fixture -- --ignored`
    #[test]
    #[ignore = "regenerates a fixture the Godot layout test reads"]
    fn dump_phaser_view_fixture() {
        let device = device();
        let params: Vec<String> = device
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
                        crate::audio::devices::ParamType::Float => "float",
                        crate::audio::devices::ParamType::Enum => "enum",
                        crate::audio::devices::ParamType::Bool => "bool",
                    },
                    p.min,
                    p.max,
                    p.default,
                    p.param_type != crate::audio::devices::ParamType::Float,
                    p.is_logarithmic,
                    enum_values.join(",")
                )
            })
            .collect();
        let json = format!(
            "{{\n  \"device\": {{\"id\": \"sonara.builtin.phaser\", \"name\": \"Phaser\", \
             \"features\": []}},\n  \"params\": [\n    {}\n  ]\n}}\n",
            params.join(",\n    ")
        );
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../Godot/tests/fixtures/simple_view/phaser_params.json");
        std::fs::write(&path, json).expect("write fixture");
        println!("wrote {}", path.display());
    }
}
