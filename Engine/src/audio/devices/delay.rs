//! Delay v2 (spec 012, Phase 1).
//!
//! Signal path per channel: `DelayLine` (Hermite reads) → Low Cut / High Cut (two one-pole
//! stages each) → Tape drive → wet output. The feedback is that filtered signal times Feedback,
//! soft-clipped so 100–110 % builds up without blowing up, and written back with the input.
//!
//! - **Clean** changes the time by crossfading between two read taps (about 50 ms), so the
//!   pitch doesn't bend. **Tape** glides one tap through a smoothed time (tape pitch bend), adds
//!   Drive saturation and a little wow and flutter.
//! - **Routing** (Stereo, Ping-Pong, Mono) is a set of mixing coefficients that are smoothed, so
//!   switching it crossfades instead of clicking.
//! - **Ducking** follows the dry input and turns down the wet signal only.
//! - Time comes from ms or, when Sync isn't Off, from the tempo in `set_transport`.
//!
//! Parameter IDs are in blocks of ten per module: Time = 0.., Feedback = 10.., Character = 20..,
//! Dynamics = 30.., Output = 40...

use super::effect::{pass_through, TailSleep};
use super::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use super::{AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
use crate::audio::dsp::delay_line::DelayLine;
use crate::audio::dsp::env_follower::{Detection, EnvFollower};
use crate::audio::dsp::gain::{dry_wet_gains, MixLaw};
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::dsp::tempo_sync::{division_seconds, index_of, SYNC_CHOICES};
use crate::audio::transport::Transport;
use std::f32::consts::TAU;

pub const TIME_L: ParamId = 0;
pub const TIME_R: ParamId = 1;
pub const SYNC_L: ParamId = 2;
pub const SYNC_R: ParamId = 3;
pub const LINK: ParamId = 4;
pub const ROUTING: ParamId = 5;

pub const FEEDBACK: ParamId = 10;
pub const LOW_CUT: ParamId = 11;
pub const HIGH_CUT: ParamId = 12;

pub const MODE: ParamId = 20;
pub const MOD_RATE: ParamId = 21;
pub const MOD_DEPTH: ParamId = 22;
pub const DRIVE: ParamId = 23;

pub const DUCKING: ParamId = 30;
pub const DUCK_RELEASE: ParamId = 31;

pub const WIDTH: ParamId = 40;
pub const MIX: ParamId = 41;

const ROUTINGS: &[&str] = &["Stereo", "Ping-Pong", "Mono"];
const MODES: &[&str] = &["Clean", "Tape"];

/// Longest delay time, in seconds.
pub const MAX_TIME_SECONDS: f32 = 5.0;

const TIME_SPECS: [ParamSpec; 6] = [
    spec(TIME_L, "Time L", "Time", "ms", log(1.0, 5000.0), 375.0),
    spec(TIME_R, "Time R", "Time", "ms", log(1.0, 5000.0), 375.0),
    spec(
        SYNC_L,
        "Sync L",
        "Time",
        "",
        Kind::Enum(SYNC_CHOICES),
        index_of("1/8.") as f32,
    ),
    spec(
        SYNC_R,
        "Sync R",
        "Time",
        "",
        Kind::Enum(SYNC_CHOICES),
        index_of("1/8.") as f32,
    ),
    spec(LINK, "Link", "Time", "", Kind::Bool, 1.0),
    spec(ROUTING, "Routing", "Time", "", Kind::Enum(ROUTINGS), 0.0),
];
const FEEDBACK_SPECS: [ParamSpec; 3] = [
    spec(
        FEEDBACK,
        "Feedback",
        "Feedback",
        "%",
        linear(0.0, 110.0),
        40.0,
    ),
    spec(
        LOW_CUT,
        "Low Cut",
        "Feedback",
        "Hz",
        log(20.0, 2_000.0),
        150.0,
    ),
    spec(
        HIGH_CUT,
        "High Cut",
        "Feedback",
        "Hz",
        log(1_000.0, 20_000.0),
        8_000.0,
    ),
];
const CHARACTER_SPECS: [ParamSpec; 4] = [
    spec(MODE, "Mode", "Character", "", Kind::Enum(MODES), 0.0),
    spec(MOD_RATE, "Mod Rate", "Character", "Hz", log(0.05, 8.0), 0.5),
    spec(
        MOD_DEPTH,
        "Mod Depth",
        "Character",
        "%",
        linear(0.0, 100.0),
        0.0,
    ),
    spec(DRIVE, "Drive", "Character", "%", linear(0.0, 100.0), 0.0),
];
const DYNAMICS_SPECS: [ParamSpec; 2] = [
    spec(DUCKING, "Ducking", "Dynamics", "%", linear(0.0, 100.0), 0.0),
    spec(
        DUCK_RELEASE,
        "Duck Release",
        "Dynamics",
        "ms",
        log(20.0, 2_000.0),
        250.0,
    ),
];
const OUTPUT_SPECS: [ParamSpec; 2] = [
    spec(WIDTH, "Width", "Output", "%", linear(0.0, 200.0), 100.0),
    spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 30.0),
];

const COUNT: usize = 17;
const SPECS: [ParamSpec; COUNT] = flatten(&[
    &TIME_SPECS,
    &FEEDBACK_SPECS,
    &CHARACTER_SPECS,
    &DYNAMICS_SPECS,
    &OUTPUT_SPECS,
]);
const SLOTS: [u8; 42] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// Parameter metadata for the Delay.
pub fn param_infos() -> Vec<ParamInfo> {
    TABLE.infos()
}

/// Clean time changes crossfade over this long.
const CROSSFADE_SECONDS: f32 = 0.05;
/// Tape time glide (one-pole time constant).
const TAPE_GLIDE_SECONDS: f32 = 0.12;
/// The Tape delay moves at most this many samples per sample (playback speed 0.5x to 1.5x).
const TAPE_MAX_SLEW: f32 = 0.5;
/// Routing and other switches crossfade over this many ms.
const SWITCH_RAMP_MS: f32 = 8.0;
/// A Clean tap moves when the target is further than this many samples away.
const RETARGET_EPSILON: f32 = 0.25;
/// Mod Depth 100 % swings the delay by this many ms either way.
const MOD_MAX_MS: f32 = 3.0;
/// Tape wow and flutter: rate in Hz and excursion in ms.
const WOW_HZ: f32 = 0.6;
const WOW_MS: f32 = 0.8;
const FLUTTER_HZ: f32 = 6.3;
const FLUTTER_MS: f32 = 0.05;
/// The dry input's envelope that fully ducks at 100 % is 1/DUCK_SCALE.
const DUCK_SCALE: f32 = 20.0;
/// Feedback signals below this pass the soft clip unchanged.
const CLIP_KNEE: f32 = 0.6;

/// Linear up to the knee, then a tanh shoulder to ±1 (continuous slope).
#[inline]
fn soft_clip(x: f32) -> f32 {
    let a = x.abs();
    if a <= CLIP_KNEE {
        x
    } else {
        let room = 1.0 - CLIP_KNEE;
        (CLIP_KNEE + room * ((a - CLIP_KNEE) / room).tanh()).copysign(x)
    }
}

/// One channel's read position: a settled tap, or a crossfade from it to a new one.
#[derive(Clone, Copy, Debug)]
struct TapState {
    /// Delay of the active tap, in samples.
    cur: f32,
    /// Delay of the tap being faded in.
    next: f32,
    /// Crossfade progress 0..1; 0 when no fade is running.
    fade: f32,
}

impl TapState {
    fn at(delay: f32) -> Self {
        Self {
            cur: delay,
            next: delay,
            fade: 0.0,
        }
    }

    /// Advance one sample toward `target`. `tape` glides, otherwise a change crossfades. A fade
    /// that is already running always finishes first.
    #[inline]
    fn advance(&mut self, target: f32, tape: bool, glide: f32, fade_step: f32) {
        if self.fade > 0.0 {
            self.fade += fade_step;
            if self.fade >= 1.0 {
                self.cur = self.next;
                self.fade = 0.0;
            }
        } else if tape {
            let step = ((target - self.cur) * glide).clamp(-TAPE_MAX_SLEW, TAPE_MAX_SLEW);
            self.cur += step;
        } else if (target - self.cur).abs() > RETARGET_EPSILON {
            self.next = target;
            self.fade = fade_step;
        }
    }
}

/// Low Cut and High Cut for one channel (two one-pole stages each, 12 dB/oct).
#[derive(Clone, Copy, Debug, Default)]
struct ToneStage {
    hp: [OnePole; 2],
    lp: [OnePole; 2],
}

impl ToneStage {
    fn reset(&mut self) {
        *self = Self::default();
    }

    #[inline]
    fn process(&mut self, x: f32, hp_g: f32, lp_g: f32) -> f32 {
        let x = self.hp[0].highpass(x, hp_g);
        let x = self.hp[1].highpass(x, hp_g);
        let x = self.lp[0].lowpass(x, lp_g);
        self.lp[1].lowpass(x, lp_g)
    }
}

#[derive(Clone)]
pub struct DelayDevice {
    sample_rate: f32,
    params: ParamValues<COUNT>,
    bpm: f64,

    line: [DelayLine; 2],
    taps: [TapState; 2],
    tone: [ToneStage; 2],
    ducker: EnvFollower,

    // Decoded parameters (real units).
    time_ms: [f32; 2],
    sync: [usize; 2],
    link: bool,
    tape: bool,
    mod_rate: f32,
    mod_phase: f32,
    wow_phase: f32,
    flutter_phase: f32,

    feedback: SmoothedParam,
    low_cut: SmoothedParam,
    high_cut: SmoothedParam,
    mod_depth: SmoothedParam,
    drive: SmoothedParam,
    ducking: SmoothedParam,
    width: SmoothedParam,
    mix: SmoothedParam,
    // Routing coefficients (see `set_routing`).
    mono_in: SmoothedParam,
    cross: SmoothedParam,
    r_mono: SmoothedParam,
    mono_out: SmoothedParam,
    gains: (f32, f32),
    filter_g: (f32, f32),

    tail: TailSleep,
    is_active: bool,
    is_enabled: bool,
}

impl std::fmt::Debug for DelayDevice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DelayDevice")
            .field("sample_rate", &self.sample_rate)
            .field("time_ms", &self.time_ms)
            .finish()
    }
}

impl DelayDevice {
    /// `_max_delay_ms` is kept for API compatibility: the line always holds 5 s.
    pub fn new(sample_rate: f32, _max_delay_ms: f32) -> Self {
        let ramp = SmoothedParam::DEFAULT_RAMP_MS;
        let smooth = |v: f32| SmoothedParam::new(v, sample_rate, ramp);
        let switch = |v: f32| SmoothedParam::new(v, sample_rate, SWITCH_RAMP_MS);
        let mut device = Self {
            sample_rate,
            params: ParamValues::new(&TABLE),
            bpm: 120.0,
            line: [DelayLine::new(), DelayLine::new()],
            taps: [TapState::at(2.0); 2],
            tone: [ToneStage::default(); 2],
            ducker: EnvFollower::new(5.0, 250.0, sample_rate, Detection::Peak),
            time_ms: [375.0; 2],
            sync: [index_of("1/8."); 2],
            link: true,
            tape: false,
            mod_rate: 0.5,
            mod_phase: 0.0,
            wow_phase: 0.0,
            flutter_phase: 0.0,
            feedback: smooth(0.4),
            low_cut: smooth(150.0),
            high_cut: smooth(8_000.0),
            mod_depth: smooth(0.0),
            drive: smooth(0.0),
            ducking: smooth(0.0),
            width: smooth(1.0),
            mix: smooth(0.3),
            mono_in: switch(0.0),
            cross: switch(0.0),
            r_mono: switch(1.0),
            mono_out: switch(0.0),
            gains: (1.0, 0.0),
            filter_g: (0.0, 0.0),
            tail: TailSleep::new(sample_rate),
            is_active: true,
            is_enabled: true,
        };
        device.prepare_lines();
        device.gains = dry_wet_gains(device.mix.current(), MixLaw::EqualPower);
        device.filter_g = device.cutoff_g();
        device.snap_taps();
        device.update_tail();
        device
    }

    fn prepare_lines(&mut self) {
        for line in &mut self.line {
            line.prepare_seconds(MAX_TIME_SECONDS + 0.05, self.sample_rate);
        }
    }

    /// Target delay of channel `ch` in samples, from ms or the tempo.
    fn target_samples(&self, ch: usize) -> f32 {
        let src = if self.link { 0 } else { ch };
        let seconds = match division_seconds(self.sync[src], self.bpm) {
            Some(s) => s as f32,
            None => self.time_ms[src] * 0.001,
        };
        (seconds * self.sample_rate).clamp(2.0, MAX_TIME_SECONDS * self.sample_rate)
    }

    fn snap_taps(&mut self) {
        for ch in 0..2 {
            self.taps[ch] = TapState::at(self.target_samples(ch));
        }
    }

    /// How long the wet signal can ring after the input stops.
    fn update_tail(&mut self) {
        let fb = self.feedback.target();
        if fb >= 1.0 {
            self.tail.set_tail_seconds(None);
            return;
        }
        let repeats = if fb <= 0.001 {
            1.0
        } else {
            ((0.001f32).ln() / fb.ln()).ceil().clamp(1.0, 200.0)
        };
        let time = self.target_samples(0).max(self.target_samples(1)) / self.sample_rate;
        self.tail.set_tail_seconds(Some(time * (repeats + 1.0)));
    }

    fn set_routing(&mut self, routing: usize) {
        // (mono input mix, cross-feed of the feedback, R input from the mono sum, mono output)
        let (mono_in, cross, r_mono, mono_out) = match routing {
            1 => (1.0, 1.0, 0.0, 0.0),
            2 => (1.0, 0.0, 1.0, 1.0),
            _ => (0.0, 0.0, 1.0, 0.0),
        };
        self.mono_in.set_target(mono_in);
        self.cross.set_target(cross);
        self.r_mono.set_target(r_mono);
        self.mono_out.set_target(mono_out);
    }

    fn cutoff_g(&self) -> (f32, f32) {
        (
            one_pole_g(self.low_cut.current(), self.sample_rate),
            one_pole_g(self.high_cut.current(), self.sample_rate),
        )
    }
}

impl AudioDevice for DelayDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.is_active || !self.is_enabled {
            pass_through(inputs, outputs, sample_count);
            return;
        }
        let frames = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        self.tail.on_block(frames);

        let sr = self.sample_rate;
        let target = [self.target_samples(0), self.target_samples(1)];
        let fade_step = 1.0 / (CROSSFADE_SECONDS * sr);
        let glide = 1.0 - (-1.0 / (TAPE_GLIDE_SECONDS * sr)).exp();
        let mod_inc = self.mod_rate / sr;
        let wow_inc = WOW_HZ / sr;
        let flutter_inc = FLUTTER_HZ / sr;
        let ms = 0.001 * sr;
        let tape = self.tape;
        let mut filter_g = self.filter_g;

        for n in 0..frames {
            let in_l = inputs[2 * n];
            let in_r = inputs[2 * n + 1];

            // Smoothed controls.
            let fb = self.feedback.next();
            let depth = self.mod_depth.next();
            let drive = self.drive.next();
            let duck = self.ducking.next();
            let width = self.width.next();
            let m_in = self.mono_in.next();
            let cross = self.cross.next();
            let r_mono = self.r_mono.next();
            let m_out = self.mono_out.next();
            if !(self.low_cut.is_settled() && self.high_cut.is_settled()) {
                self.low_cut.next();
                self.high_cut.next();
                filter_g = self.cutoff_g();
            }
            if !self.mix.is_settled() {
                self.mix.next();
                self.gains = dry_wet_gains(self.mix.current(), MixLaw::EqualPower);
            }

            // Delay modulation: the Mod LFO in both modes, wow and flutter in Tape.
            self.mod_phase = (self.mod_phase + mod_inc).fract();
            let mut swing = (self.mod_phase * TAU).sin() * depth * MOD_MAX_MS * ms;
            if tape {
                self.wow_phase = (self.wow_phase + wow_inc).fract();
                self.flutter_phase = (self.flutter_phase + flutter_inc).fract();
                swing += (self.wow_phase * TAU).sin() * WOW_MS * ms
                    + (self.flutter_phase * TAU).sin() * FLUTTER_MS * ms;
            }

            // Read both lines.
            let mut read = [0.0f32; 2];
            for ch in 0..2 {
                self.taps[ch].advance(target[ch], tape, glide, fade_step);
                let t = self.taps[ch];
                let a = self.line[ch].read_hermite(t.cur + swing);
                read[ch] = if t.fade > 0.0 {
                    let b = self.line[ch].read_hermite(t.next + swing);
                    a + (b - a) * t.fade
                } else {
                    a
                };
            }

            // Tone and Tape drive give the wet signal; the feedback is that, clipped.
            let mut wet = [0.0f32; 2];
            let mut own_fb = [0.0f32; 2];
            for ch in 0..2 {
                let mut w = self.tone[ch].process(read[ch], filter_g.0, filter_g.1);
                if tape && drive > 0.0 {
                    let g = drive * 6.0;
                    w = (g * w).tanh() / g;
                }
                wet[ch] = w;
                own_fb[ch] = soft_clip(w * fb);
            }

            // Routing: input mix, feedback cross-feed.
            let mono = 0.5 * (in_l + in_r);
            let line_in_l = in_l + (mono - in_l) * m_in;
            let line_in_r = in_r * (1.0 - m_in) + mono * m_in * r_mono;
            let fb_l = own_fb[0] + (own_fb[1] - own_fb[0]) * cross;
            let fb_r = own_fb[1] + (own_fb[0] - own_fb[1]) * cross;
            self.line[0].push(line_in_l + fb_l);
            self.line[1].push(line_in_r + fb_r);

            // Output: Mono, Ducking, Width, then Mix.
            let wet_l = wet[0];
            let wet_r = wet[1] + (wet[0] - wet[1]) * m_out;
            let env = self.ducker.process(in_l.abs().max(in_r.abs()));
            let duck_gain = 1.0 - duck * (env * DUCK_SCALE).min(1.0);
            let (wet_l, wet_r) = (wet_l * duck_gain, wet_r * duck_gain);
            let mid = 0.5 * (wet_l + wet_r);
            let side = 0.5 * (wet_l - wet_r) * width;
            let (dry_gain, wet_gain) = self.gains;
            outputs[2 * n] = in_l * dry_gain + (mid + side) * wet_gain;
            outputs[2 * n + 1] = in_r * dry_gain + (mid - side) * wet_gain;
        }
        self.filter_g = filter_g;
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        let Some((_, real)) = self.params.set(param_id, value) else {
            return;
        };
        self.tail.wake();
        match param_id {
            TIME_L => self.time_ms[0] = real,
            TIME_R => self.time_ms[1] = real,
            SYNC_L => self.sync[0] = real as usize,
            SYNC_R => self.sync[1] = real as usize,
            LINK => self.link = real >= 0.5,
            ROUTING => self.set_routing(real as usize),
            FEEDBACK => self.feedback.set_target(real * 0.01),
            LOW_CUT => self.low_cut.set_target(real),
            HIGH_CUT => self.high_cut.set_target(real),
            MODE => self.tape = real >= 0.5,
            MOD_RATE => self.mod_rate = real,
            MOD_DEPTH => self.mod_depth.set_target(real * 0.01),
            DRIVE => self.drive.set_target(real * 0.01),
            DUCKING => self.ducking.set_target(real * 0.01),
            DUCK_RELEASE => self.ducker.set_times(5.0, real, self.sample_rate),
            WIDTH => self.width.set_target(real * 0.01),
            MIX => self.mix.set_target(real * 0.01),
            _ => {}
        }
        self.update_tail();
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.params.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.delay"
    }

    fn device_name(&self) -> &str {
        "Delay"
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Effect
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        param_infos()
    }

    fn reset(&mut self) {
        for line in &mut self.line {
            line.clear();
        }
        for tone in &mut self.tone {
            tone.reset();
        }
        self.ducker.reset();
        self.snap_taps();
        self.tail.wake();
    }

    fn set_transport(&mut self, transport: &Transport) {
        if transport.tempo > 0.0 && (transport.tempo - self.bpm).abs() > 1e-9 {
            self.bpm = transport.tempo;
            self.update_tail();
        }
    }

    /// Resize the lines for the new rate and restart from the current parameters.
    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        self.prepare_lines();
        let ramp = SmoothedParam::DEFAULT_RAMP_MS;
        for p in [
            &mut self.feedback,
            &mut self.low_cut,
            &mut self.high_cut,
            &mut self.mod_depth,
            &mut self.drive,
            &mut self.ducking,
            &mut self.width,
            &mut self.mix,
        ] {
            p.set_ramp(sample_rate, ramp);
        }
        for p in [
            &mut self.mono_in,
            &mut self.cross,
            &mut self.r_mono,
            &mut self.mono_out,
        ] {
            p.set_ramp(sample_rate, SWITCH_RAMP_MS);
        }
        let release = TABLE
            .spec(DUCK_RELEASE)
            .map(|s| s.to_real(self.params.get(DUCK_RELEASE).unwrap_or(0.0)))
            .unwrap_or(250.0);
        self.ducker.set_times(5.0, release, sample_rate);
        self.tail.set_sample_rate(sample_rate);
        for tone in &mut self.tone {
            tone.reset();
        }
        self.ducker.reset();
        self.filter_g = self.cutoff_g();
        self.snap_taps();
        self.update_tail();
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

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    // === Sleep ===

    fn is_sleeping(&self) -> bool {
        self.tail.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.tail.wake();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        self.tail.update(has_audio_activity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{
        impulse, interleave, left, peak, render, right, sine, stereo, to_db, tone_amplitude,
        white_noise,
    };

    const SR: f32 = 48_000.0;

    fn set_real(d: &mut DelayDevice, id: ParamId, real: f32) {
        let norm = TABLE.spec(id).unwrap().to_norm(real);
        d.set_parameter(id, norm);
    }

    fn set_sync(d: &mut DelayDevice, name: &str) {
        set_real(d, SYNC_L, index_of(name) as f32);
        set_real(d, SYNC_R, index_of(name) as f32);
    }

    /// A delay with only the wet path: Mix 100 %, no feedback unless a test sets it, and the
    /// smoothers settled.
    fn wet_only() -> DelayDevice {
        let mut d = DelayDevice::new(SR, 5000.0);
        d.prepare(SR, 4096);
        set_real(&mut d, MIX, 100.0);
        set_real(&mut d, FEEDBACK, 0.0);
        set_real(&mut d, LOW_CUT, 20.0);
        set_real(&mut d, HIGH_CUT, 20_000.0);
        render(&mut d, &vec![0.0; 4800 * 2], &[512]);
        d
    }

    fn peak_index(signal: &[f32]) -> usize {
        signal
            .iter()
            .enumerate()
            .fold((0, 0.0f32), |best, (i, x)| {
                if x.abs() > best.1 {
                    (i, x.abs())
                } else {
                    best
                }
            })
            .0
    }

    fn max_jump(v: &[f32]) -> f32 {
        v.windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max)
    }

    #[test]
    fn impulse_peak_lands_on_the_exact_sample_for_ms_and_for_sync() {
        // 100 ms = 4800 samples.
        let mut d = wet_only();
        set_sync(&mut d, "Off");
        set_real(&mut d, TIME_L, 100.0);
        let out = render(&mut d, &stereo(&impulse(10_000)), &[512]);
        assert_eq!(peak_index(&left(&out)), 4800);
        assert_eq!(peak_index(&right(&out)), 4800);

        // 1/8. at 120 BPM = 0.375 s = 18000 samples.
        let mut d = wet_only();
        set_sync(&mut d, "1/8.");
        d.set_transport(&Transport {
            tempo: 120.0,
            ..Transport::default()
        });
        let out = render(&mut d, &stereo(&impulse(20_000)), &[512]);
        assert_eq!(peak_index(&left(&out)), 18_000);

        // The tempo follows the transport: at 60 BPM the same division is twice as long.
        let mut d = wet_only();
        set_sync(&mut d, "1/8.");
        d.set_transport(&Transport {
            tempo: 60.0,
            ..Transport::default()
        });
        let out = render(&mut d, &stereo(&impulse(40_000)), &[512]);
        assert_eq!(peak_index(&left(&out)), 36_000);
    }

    #[test]
    fn ping_pong_alternates_left_and_right_repeats() {
        let mut d = wet_only();
        set_sync(&mut d, "Off");
        set_real(&mut d, TIME_L, 100.0);
        set_real(&mut d, FEEDBACK, 80.0);
        d.set_parameter(ROUTING, 0.5); // Ping-Pong
        render(&mut d, &vec![0.0; 1024 * 2], &[512]);
        let out = render(&mut d, &stereo(&impulse(4800 * 4 + 600)), &[512]);
        let (l, r) = (left(&out), right(&out));
        // Energy in a short window around each repeat (the tone filters smear the impulse).
        let at = |v: &[f32], k: usize| {
            v[4800 * k - 50..4800 * k + 400]
                .iter()
                .map(|x| x * x)
                .sum::<f32>()
        };
        for k in 1..=4usize {
            let (loud, quiet) = if k % 2 == 1 {
                (at(&l, k), at(&r, k))
            } else {
                (at(&r, k), at(&l, k))
            };
            assert!(
                loud > 1e-3 && quiet < loud * 1e-4,
                "repeat {k}: {loud} vs {quiet}"
            );
        }
    }

    #[test]
    fn feedback_110_stays_below_6_dbfs_over_60_seconds() {
        let mut d = wet_only();
        set_real(&mut d, FEEDBACK, 110.0);
        set_real(&mut d, MIX, 50.0);
        set_sync(&mut d, "Off");
        set_real(&mut d, TIME_L, 120.0);
        let frames = 60 * SR as usize;
        // One second of loud noise, then silence: the loop keeps ringing on its own.
        let mut input = white_noise(SR as usize, 0.8, 5);
        input.resize(frames, 0.0);
        let out = render(&mut d, &stereo(&input), &[512]);
        assert!(out.iter().all(|x| x.is_finite()));
        assert!(to_db(peak(&out)) < 6.0, "peak {} dBFS", to_db(peak(&out)));
        assert!(peak(&out[out.len() - 9600..]) > 0.02, "still ringing");
    }

    #[test]
    fn repeats_lose_energy_above_high_cut_and_below_low_cut() {
        // Feedback 100 %: a tone in the pass band keeps its level; tones outside it fall away.
        let repeat_levels = |freq: f32| {
            let mut d = wet_only();
            set_sync(&mut d, "Off");
            set_real(&mut d, TIME_L, 100.0);
            set_real(&mut d, FEEDBACK, 100.0);
            set_real(&mut d, LOW_CUT, 400.0);
            set_real(&mut d, HIGH_CUT, 3_000.0);
            render(&mut d, &vec![0.0; 2048 * 2], &[512]);
            let mut input = sine(freq, SR, 4800, 0.1);
            input.resize(4800 * 6, 0.0);
            let out = left(&render(&mut d, &stereo(&input), &[512]));
            let level = |k: usize| tone_amplitude(&out[4800 * k..4800 * (k + 1)], freq, SR);
            (level(2), level(4))
        };
        let loss = |(a, b): (f32, f32)| to_db(b) - to_db(a);
        let pass = loss(repeat_levels(1_000.0));
        let high = loss(repeat_levels(10_000.0));
        let low = loss(repeat_levels(60.0));
        assert!(pass > -6.0, "pass band: {pass} dB");
        assert!(high < -20.0, "above High Cut: {high} dB");
        assert!(low < -20.0, "below Low Cut: {low} dB");
    }

    #[test]
    fn clean_time_change_has_no_jump_bigger_than_the_inputs() {
        let mut d = wet_only();
        set_sync(&mut d, "Off");
        set_real(&mut d, TIME_L, 100.0);
        let input = sine(440.0, SR, 96_000, 0.5);
        let mut out = Vec::new();
        for (i, block) in stereo(&input).chunks(512 * 2).enumerate() {
            // Drag Time around while playing.
            let ms = 100.0 + 400.0 * (i as f32 * 0.15).sin().abs();
            set_real(&mut d, TIME_L, ms);
            out.extend(render(&mut d, block, &[512]));
        }
        let (input_jump, out_jump) = (max_jump(&input), max_jump(&left(&out)));
        assert!(
            out_jump <= input_jump * 1.05,
            "output jumps {out_jump}, input {input_jump}"
        );
    }

    #[test]
    fn tape_time_change_glides_without_jumps() {
        let mut d = wet_only();
        set_sync(&mut d, "Off");
        set_real(&mut d, TIME_L, 100.0);
        d.set_parameter(MODE, 1.0);
        let input = sine(440.0, SR, 48_000, 0.5);
        let mut out = Vec::new();
        for (i, block) in stereo(&input).chunks(512 * 2).enumerate() {
            if i == 20 {
                set_real(&mut d, TIME_L, 300.0);
            }
            out.extend(render(&mut d, block, &[512]));
        }
        // Playback speed stays within 0.5x-1.5x, so steps stay within 1.5x the input's.
        assert!(max_jump(&left(&out)) <= max_jump(&input) * 1.6);
    }

    #[test]
    fn ducking_full_turns_the_wet_down_by_20_db_while_input_is_present() {
        let run = |duck: f32| {
            let mut d = wet_only();
            set_sync(&mut d, "Off");
            set_real(&mut d, TIME_L, 10.0);
            set_real(&mut d, DUCKING, duck);
            let input = white_noise(SR as usize, 0.3, 9);
            let out = render(&mut d, &stereo(&input), &[512]);
            to_db(peak(&out[SR as usize / 2..]))
        };
        let (open, ducked) = (run(0.0), run(100.0));
        assert!(open - ducked >= 20.0, "open {open} dB, ducked {ducked} dB");
    }

    #[test]
    fn mono_routing_makes_both_channels_identical() {
        let mut d = wet_only();
        d.set_parameter(ROUTING, 1.0); // Mono
        let input = interleave(&white_noise(9600, 0.3, 1), &white_noise(9600, 0.3, 2));
        let out = render(&mut d, &input, &[512]);
        let worst = left(&out)
            .iter()
            .zip(&right(&out))
            .skip(2000)
            .map(|(a, b)| (a - b).abs())
            .fold(0.0, f32::max);
        assert!(worst < 1e-6, "{worst}");
    }

    #[test]
    fn link_makes_right_follow_left() {
        let mut d = wet_only();
        set_sync(&mut d, "Off");
        set_real(&mut d, TIME_L, 100.0);
        set_real(&mut d, TIME_R, 50.0);
        let out = render(&mut d, &stereo(&impulse(10_000)), &[512]);
        assert_eq!(peak_index(&right(&out)), 4800);

        let mut d = wet_only();
        set_sync(&mut d, "Off");
        set_real(&mut d, TIME_L, 100.0);
        set_real(&mut d, TIME_R, 50.0);
        d.set_parameter(LINK, 0.0);
        let out = render(&mut d, &stereo(&impulse(10_000)), &[512]);
        assert_eq!(peak_index(&left(&out)), 4800);
        assert_eq!(peak_index(&right(&out)), 2400);
    }

    #[test]
    fn max_time_is_the_advertised_5000_ms() {
        let mut d = wet_only();
        set_sync(&mut d, "Off");
        d.set_parameter(TIME_L, 1.0);
        let out = render(&mut d, &stereo(&impulse(250_000)), &[4096]);
        assert_eq!(peak_index(&left(&out)), 240_000);
        assert_eq!(param_infos()[0].max, 5000.0);
    }

    #[test]
    fn sleep_waits_out_the_tail_and_feedback_100_never_sleeps() {
        let mut d = DelayDevice::new(SR, 5000.0);
        set_sync(&mut d, "Off");
        d.set_parameter(TIME_L, 1.0); // 5 s repeats
        for _ in 0..(3 * 48_000 / 512 + 1) {
            d.tail.on_block(512);
            d.update_sleep_state(false);
        }
        assert!(!d.is_sleeping(), "the tail is far longer than 3 s");
        set_real(&mut d, FEEDBACK, 100.0);
        for _ in 0..10_000 {
            d.tail.on_block(512);
            d.update_sleep_state(false);
        }
        assert!(!d.is_sleeping());
    }
}
