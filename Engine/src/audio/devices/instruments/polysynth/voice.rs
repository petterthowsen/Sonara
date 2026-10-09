//! One note slot: up to 16 unison oscillators per oscillator, noise, drive and the filter, the
//! amp envelope, glide, and the short fade a stolen voice plays before its queued note starts.
//!
//! Modulation runs once per control block: this voice's modulators are sampled at the block
//! start, summed per routed parameter, and decoded into a stack copy of the parameter block.
//! Pitch, cutoff, resonance, levels and volume are interpolated across the block; everything
//! else is block-constant. A modulator's value is `clamp(base + mono offset + Σ poly, 0, 1)`
//! (ADR-0014): the mono offset comes from a container's route through `SynthParams::offset`,
//! the poly sum from the voice's own modulator states.

use super::params::{
    slot_of, SynthParams, AMP_ENV, ATTACK, CUTOFF, CUTOFF_MAX, CUTOFF_MIN, DECAY, MAX_UNISON,
    PARAM_COUNT, RELEASE, SUSTAIN, VOLUME,
};
use crate::audio::devices::norm_to_real;
use crate::audio::dsp::{svf, FilterMode, Oscillator, Svf, SvfCoefs};
use crate::audio::modulation::envelope::AdsrEnvelope;
use crate::audio::modulation::kinds::{ModParams, ModulatorKind, LFO_RETRIGGER};
use crate::audio::modulation::state::ModulatorState;
use crate::audio::modulation::voice::VoiceModSpec;
use crate::audio::modulation::MAX_MODULATORS;
use crate::audio::transport::Transport;

/// Pitch, oscillator frequencies, modulation and the glide advance once per this many frames.
pub const CONTROL_BLOCK: usize = 32;
/// How long a stolen voice fades before the queued note starts.
const STEAL_FADE_MS: f32 = 4.0;
/// Per-voice headroom so a chord doesn't clip at default levels.
const VOICE_GAIN: f32 = 0.5;
/// Corner of the one-pole that splits noise into dark and bright halves.
const NOISE_TILT_HZ: f32 = 1_000.0;
/// Makes up the level the dark (low-passed) half of the noise loses.
const NOISE_DARK_GAIN: f32 = 3.0;
/// Keeps PolyBLEP's two-sample correction windows apart.
const MAX_PHASE_INCREMENT: f64 = 0.24;
/// Small fixed per-sub-voice detune deviations (fraction of each sub-voice's offset), so
/// unison voices don't beat in lockstep. Index 0 is always the one closest to centre.
const UNISON_JITTER: [f32; MAX_UNISON] = [
    0.0, 0.11, -0.07, 0.05, -0.12, 0.08, -0.04, 0.13, -0.09, 0.03, -0.1, 0.06, -0.02, 0.09, -0.06,
    0.04,
];

const CUTOFF_SLOT: usize = slot_of(CUTOFF);
const VOLUME_SLOT: usize = slot_of(VOLUME);
const AMP_ENV_SLOTS: [usize; 4] = env_slots(AMP_ENV);

const fn env_slots(base: u32) -> [usize; 4] {
    [
        slot_of(base + ATTACK),
        slot_of(base + DECAY),
        slot_of(base + SUSTAIN),
        slot_of(base + RELEASE),
    ]
}

/// A note waiting for its stolen voice to finish fading.
#[derive(Clone, Copy, Debug)]
pub struct PendingNote {
    pub note: u8,
    pub velocity: f32,
    pub age: u64,
    pub glide_from: Option<f32>,
    pub unison: [usize; 2],
    /// A note-off arrived during the fade: release (with this release velocity) as soon as the
    /// note starts.
    pub released: Option<f32>,
}

/// Device state a note needs when it starts.
#[derive(Clone, Copy, Debug)]
pub struct StartCtx {
    pub glide: f32,
    /// Free-running LFO phase per modulator slot, so a new voice's free LFO joins in phase.
    pub free_lfo: [f64; MAX_MODULATORS],
}

/// Everything a voice reads while rendering one span of the block. The slices cover the whole
/// block and are indexed with the span's frame positions.
pub struct RenderCtx<'a> {
    pub params: &'a SynthParams,
    /// The device's modulator definitions and self-targeting routes.
    pub spec: &'a VoiceModSpec,
    /// Smoothed oscillator levels per frame.
    pub levels: [&'a [f32]; 2],
    pub noise_level: &'a [f32],
    /// Smoothed base cutoff per frame, normalized (mono offset included).
    pub cutoff: &'a [f32],
    pub start: StartCtx,
    pub transport: Transport,
}

/// Position of sub-voice `k` of `n` across −1..1 (0 for a single voice).
pub fn unison_position(k: usize, n: usize) -> f32 {
    if n <= 1 {
        0.0
    } else {
        -1.0 + 2.0 * k as f32 / (n - 1) as f32
    }
}

fn note_to_hz(pitch: f32) -> f64 {
    440.0 * 2f64.powf((pitch as f64 - 69.0) / 12.0)
}

fn build_state(kind: ModulatorKind, params: &ModParams, sample_rate: f32) -> ModulatorState {
    let mut state = ModulatorState::new(kind, sample_rate);
    apply_params(&mut state, params);
    state
}

/// Push the spec's normalized parameters onto a live state without touching its runtime phase.
fn apply_params(state: &mut ModulatorState, params: &ModParams) {
    for spec in state.kind().table().specs {
        if let Some(norm) = params.get(spec.id) {
            state.set_param(spec.id, norm);
        }
    }
}

/// A free-running LFO (a new voice seeds its phase from the device's shared phase).
fn is_free_lfo(state: &ModulatorState) -> bool {
    state.kind() == ModulatorKind::Lfo && state.get_param(LFO_RETRIGGER).unwrap_or(0.0) < 0.5
}

/// Per-sub-voice detune ratios and pan gains for one oscillator, kept until the unison count,
/// detune or spread change (so steady voices skip a powf and a sin_cos per sub-voice per block).
#[derive(Clone, Copy, Debug)]
struct UnisonShape {
    count: usize,
    detune_cents: f32,
    spread: f32,
    ratio: [f64; MAX_UNISON],
    gain_l: [f32; MAX_UNISON],
    gain_r: [f32; MAX_UNISON],
    /// Any sub-voice off centre.
    stereo: bool,
}

impl UnisonShape {
    fn new(count: usize, detune_cents: f32, spread: f32) -> Self {
        let mut shape = Self {
            count,
            detune_cents,
            spread,
            ratio: [1.0; MAX_UNISON],
            gain_l: [0.0; MAX_UNISON],
            gain_r: [0.0; MAX_UNISON],
            stereo: false,
        };
        let gain = VOICE_GAIN / (count as f32).sqrt();
        for k in 0..count {
            let position = unison_position(k, count);
            let cents = position * (1.0 + UNISON_JITTER[k]) * detune_cents;
            shape.ratio[k] = 2f64.powf(cents as f64 / 1200.0);
            // Equal-power pan scaled so the centre is unity per side: L² + R² stays constant,
            // and the mono sum never drops below √2·centre/2, so no cancellation.
            let pan = position * spread;
            shape.stereo |= pan != 0.0;
            let (sin, cos) = ((pan + 1.0) * std::f32::consts::FRAC_PI_4).sin_cos();
            shape.gain_l[k] = gain * cos * std::f32::consts::SQRT_2;
            shape.gain_r[k] = gain * sin * std::f32::consts::SQRT_2;
        }
        shape
    }
}

/// Inputs and results of the per-block filter setup, kept so a steady voice skips the tan, powf
/// and exp calls.
#[derive(Clone, Copy, Debug, PartialEq)]
struct FilterSetup {
    cutoff_norm: f32,
    key_octaves: f32,
    resonance: f32,
    mode: FilterMode,
    g: f32,
    k: f32,
    comp: f32,
}

/// Block-end values of everything interpolated across a control block; the next block ramps
/// from these.
#[derive(Clone, Copy, Debug)]
struct Ramp {
    g: f32,
    k: f32,
    level_delta: [f32; 2],
    noise_delta: f32,
    volume: f32,
    /// Block-end FM index (the FM path ramps it per frame between blocks).
    fm_index: f32,
}

pub struct Voice {
    pub note: u8,
    pub velocity: f32,
    /// Note-on order (larger is newer).
    pub age: u64,
    /// Sounding (including release and the steal fade).
    pub active: bool,
    /// Key held.
    pub gate: bool,
    /// Sub-voices per oscillator, fixed when the note starts; the voice's budget cost is the max.
    pub unison: [usize; 2],
    pub pending: Option<PendingNote>,
    oscs: [[Oscillator; MAX_UNISON]; 2],
    pub amp_env: AdsrEnvelope,
    /// This voice's modulators, one per device modulator slot (spec 018 Phase 6).
    pub mods: [Option<ModulatorState>; MAX_MODULATORS],
    /// Left and right. The right one only runs when the voice is actually stereo.
    filters: [Svf; 2],
    /// Current pitch in (fractional) MIDI notes, before oscillator transpose.
    pub pitch: f32,
    target_pitch: f32,
    /// Semitones the current glide covers, so its rate follows a modulated Glide time.
    glide_span: f32,
    ramp: Ramp,
    unison_shape: [Option<UnisonShape>; 2],
    filter_setup: Option<FilterSetup>,
    /// The next control block snaps its ramps instead of gliding from the previous note's values.
    fresh: bool,
    fade: f32,
    fade_step: f32,
    rng: u32,
    noise_lp: f32,
    noise_coef: f32,
    sample_rate: f32,
}

impl Voice {
    pub fn new(sample_rate: f32, seed: u32) -> Self {
        Self {
            note: 0,
            velocity: 0.0,
            age: 0,
            active: false,
            gate: false,
            unison: [1, 1],
            pending: None,
            oscs: std::array::from_fn(|_| std::array::from_fn(|_| Oscillator::new())),
            amp_env: AdsrEnvelope::new(sample_rate),
            mods: std::array::from_fn(|_| None),
            filters: [Svf::new(); 2],
            pitch: 60.0,
            target_pitch: 60.0,
            glide_span: 0.0,
            ramp: Ramp {
                g: 0.0,
                k: 0.0,
                level_delta: [0.0; 2],
                noise_delta: 0.0,
                volume: 1.0,
                fm_index: 0.0,
            },
            unison_shape: [None; 2],
            filter_setup: None,
            fresh: true,
            fade: 1.0,
            fade_step: 0.0,
            // xorshift must never be seeded with 0.
            rng: seed.wrapping_mul(0x9E37_79B9) | 1,
            noise_lp: 0.0,
            noise_coef: 1.0 - (-std::f32::consts::TAU * NOISE_TILT_HZ / sample_rate).exp(),
            sample_rate,
        }
    }

    /// Match this voice's modulators to the device spec. A slot whose kind is unchanged keeps
    /// its runtime (phase, envelope stage) and is only re-parameterized.
    pub fn configure_mods(&mut self, spec: &VoiceModSpec, sample_rate: f32) {
        for slot in 0..MAX_MODULATORS {
            match spec.kind(slot) {
                Some(kind) => {
                    let params = spec.params[slot];
                    match &mut self.mods[slot] {
                        Some(state) if state.kind() == kind => apply_params(state, &params),
                        other => *other = Some(build_state(kind, &params, sample_rate)),
                    }
                }
                None => self.mods[slot] = None,
            }
        }
    }

    /// Voices this note costs out of the device budget.
    pub fn cost(&self) -> usize {
        match &self.pending {
            Some(p) => p.unison[0].max(p.unison[1]),
            None => self.unison[0].max(self.unison[1]),
        }
    }

    /// Fading out after a steal (with a note queued) or a kill (without).
    pub fn is_fading(&self) -> bool {
        self.fade_step > 0.0
    }

    /// Fading out with nothing queued: it no longer counts against the budget.
    pub fn is_dying(&self) -> bool {
        self.is_fading() && self.pending.is_none()
    }

    #[inline]
    fn next_random(&mut self) -> u32 {
        let mut x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        x
    }

    /// Uniform in −1..1.
    #[inline]
    fn next_noise(&mut self) -> f32 {
        (self.next_random() as i32) as f32 * (1.0 / 2_147_483_648.0)
    }

    /// Start a note on an idle voice.
    pub fn start(&mut self, pending: PendingNote, ctx: &StartCtx) {
        self.note = pending.note;
        self.velocity = pending.velocity;
        self.age = pending.age;
        self.unison = pending.unison;
        self.active = true;
        self.gate = true;
        self.pending = None;
        self.fade = 1.0;
        self.fade_step = 0.0;
        self.noise_lp = 0.0;
        self.fresh = true;
        self.filters = [Svf::new(); 2];
        for o in 0..2 {
            let n = self.unison[o];
            for k in 0..MAX_UNISON {
                // A lone oscillator starts at phase 0 (consistent plucks); unison is randomised.
                self.oscs[o][k].phase = if n > 1 {
                    self.next_random() as f64 / (u32::MAX as f64 + 1.0)
                } else {
                    0.0
                };
                self.oscs[o][k].mod_phase = 0.0;
            }
        }
        self.pitch = pending.glide_from.unwrap_or(pending.note as f32);
        self.glide_to(pending.note, ctx.glide);
        self.amp_env.reset();
        self.amp_env.gate_on();
        self.trigger_mods(pending.note, pending.velocity, ctx, true);
        if let Some(release) = pending.released {
            self.release(release);
        }
    }

    /// Retrigger a sounding voice with a new note: gliding from where it is now, and restarting
    /// the envelopes from their current levels only when `retrigger` (Mono, same-note repeats).
    /// The same flag restarts any note-driven LFO, so a re-triggered note keys its LFO just like
    /// a fresh note.
    pub fn retrigger(
        &mut self,
        note: u8,
        velocity: f32,
        age: u64,
        glide_seconds: f32,
        retrigger: bool,
        ctx: &StartCtx,
    ) {
        self.note = note;
        self.velocity = velocity;
        self.age = age;
        self.gate = true;
        self.glide_to(note, glide_seconds);
        if retrigger {
            self.amp_env.retrigger_from_current();
        }
        self.trigger_mods(note, velocity, ctx, retrigger);
    }

    /// Drive this voice's modulators with a note. `retrigger` gates the envelopes and restarts
    /// note LFOs; otherwise a legato slide only updates velocity and keytrack.
    fn trigger_mods(&mut self, note: u8, velocity: f32, ctx: &StartCtx, retrigger: bool) {
        for (slot, state) in self.mods.iter_mut().enumerate() {
            let Some(state) = state else { continue };
            if retrigger {
                state.gate_voice_on(note, velocity);
                if is_free_lfo(state) {
                    state.seed_lfo_phase(ctx.free_lfo[slot]);
                }
            } else {
                state.update_note(note, velocity);
            }
        }
    }

    /// Slide from the current pitch to `note` over `seconds`, linear in pitch (so exponential in
    /// frequency). 0 jumps.
    pub fn glide_to(&mut self, note: u8, seconds: f32) {
        self.target_pitch = note as f32;
        if seconds * self.sample_rate < 1.0 {
            self.pitch = self.target_pitch;
            self.glide_span = 0.0;
        } else {
            self.glide_span = (self.target_pitch - self.pitch).abs();
        }
    }

    /// Gate the note off. `release` is the note-off's release velocity, which the voice's
    /// `release` modulators latch.
    pub fn release(&mut self, release: f32) {
        self.gate = false;
        self.amp_env.gate_off();
        for state in self.mods.iter_mut().flatten() {
            state.gate_voice_off(release);
        }
    }

    /// Fade out quickly, then start `pending`.
    pub fn steal(&mut self, pending: PendingNote) {
        if !self.active {
            self.pending = Some(pending);
            return;
        }
        self.begin_fade();
        self.pending = Some(pending);
    }

    /// Fade out quickly and go idle.
    pub fn kill(&mut self) {
        if self.active {
            self.begin_fade();
        }
        self.pending = None;
        self.gate = false;
    }

    fn begin_fade(&mut self) {
        if !self.is_fading() {
            self.fade_step = 1.0 / (STEAL_FADE_MS * 0.001 * self.sample_rate).max(1.0);
        }
    }

    pub fn reset(&mut self) {
        self.active = false;
        self.gate = false;
        self.pending = None;
        self.fade = 1.0;
        self.fade_step = 0.0;
        self.amp_env.reset();
        for state in self.mods.iter_mut().flatten() {
            state.reset();
        }
    }

    /// Start a queued note if this voice is idle. Returns false when there is nothing to render.
    pub fn ensure_started(&mut self, ctx: &StartCtx) -> bool {
        if self.active {
            return true;
        }
        match self.pending {
            Some(p) => {
                self.start(p, ctx);
                true
            }
            None => false,
        }
    }

    /// After a control block: hand a finished fade over to its queued note, or retire a voice
    /// whose release has finished.
    pub fn finish_chunk(&mut self, ctx: &StartCtx) {
        if self.is_fading() && self.fade <= 0.0 {
            let pending = self.pending;
            self.reset();
            if let Some(p) = pending {
                self.start(p, ctx);
            }
        } else if !self.amp_env.is_active() {
            self.reset();
        }
    }

    /// Filter coefficients for this block, recomputed only when an input changed.
    fn filter_setup(
        &mut self,
        cutoff_norm: f32,
        key_octaves: f32,
        resonance: f32,
        mode: FilterMode,
    ) -> FilterSetup {
        if let Some(s) = self.filter_setup {
            if s.cutoff_norm == cutoff_norm
                && s.key_octaves == key_octaves
                && s.resonance == resonance
                && s.mode == mode
            {
                return s;
            }
        }
        let sr = self.sample_rate;
        let hz = norm_to_real(cutoff_norm, CUTOFF_MIN, CUTOFF_MAX, true, 1.0) * key_octaves.exp2();
        let setup = FilterSetup {
            cutoff_norm,
            key_octaves,
            resonance,
            mode,
            g: svf::cutoff_to_g(hz, sr),
            k: svf::resonance_to_k(resonance, mode),
            comp: svf::compensation_coef(hz, sr),
        };
        self.filter_setup = Some(setup);
        setup
    }

    /// Render this voice over frames `start..end` of the block, adding into the stereo
    /// accumulators (which cover the whole block).
    pub fn render_chunk(
        &mut self,
        ctx: &RenderCtx,
        start: usize,
        end: usize,
        out_l: &mut [f32],
        out_r: &mut [f32],
    ) {
        let n = end - start;
        let p = ctx.params;
        let sr = self.sample_rate;

        // Poly modulation: sample each routed modulator at the block start and sum the routes.
        let mut acc = [0.0f32; PARAM_COUNT];
        let routes = ctx.spec.routes();
        if !routes.is_empty() {
            for route in routes {
                let Some(state) = self.mods.get(route.mod_slot).and_then(|s| s.as_ref()) else {
                    continue;
                };
                if let Some(slot) = super::params::slot(route.param_id) {
                    acc[slot] += route.amount * state.value();
                }
            }
        }
        // Modulators keep running even with no routes, so their state is ready the moment one
        // appears (and a free LFO stays in phase).
        for state in self.mods.iter_mut().flatten() {
            state.advance(n, &ctx.transport);
        }

        let mut touched = [false; PARAM_COUNT];
        let modulated;
        let e: &SynthParams = if routes.is_empty() {
            p
        } else {
            let mut eff = *p;
            for route in routes {
                let Some(slot) = super::params::slot(route.param_id) else {
                    continue;
                };
                if slot == CUTOFF_SLOT || touched[slot] {
                    continue; // cutoff is applied from `acc` below, against its smoothed base
                }
                touched[slot] = true;
                eff.set_slot(
                    slot,
                    (p.effective_norm_at(slot) + acc[slot]).clamp(0.0, 1.0),
                );
            }
            if AMP_ENV_SLOTS.iter().any(|&s| touched[s]) {
                let env = &eff.amp_env;
                self.amp_env
                    .set_adsr(env.attack, env.decay, env.sustain, env.release);
            }
            modulated = eff;
            &modulated
        };

        // Pitch for this control block, then advance the glide by its length.
        let pitch = self.pitch;
        if self.pitch != self.target_pitch {
            let glide_frames = e.glide * sr;
            let step = self.glide_span * n as f32 / glide_frames;
            if glide_frames < 1.0 || (self.target_pitch - self.pitch).abs() <= step {
                self.pitch = self.target_pitch;
            } else {
                self.pitch += step.copysign(self.target_pitch - self.pitch);
            }
        }

        // Block-end targets for everything interpolated across the block.
        let setup = self.filter_setup(
            (ctx.cutoff[end - 1] + acc[CUTOFF_SLOT]).clamp(0.0, 1.0),
            e.key_track * (pitch - 60.0) / 12.0,
            e.resonance,
            p.filter_mode,
        );
        let volume = if touched[VOLUME_SLOT] && p.volume_gain > 0.0 {
            e.volume_gain / p.volume_gain
        } else {
            1.0
        };
        let target = Ramp {
            g: setup.g,
            k: setup.k,
            level_delta: [
                e.osc[0].level - p.osc[0].level,
                e.osc[1].level - p.osc[1].level,
            ],
            noise_delta: e.noise_level - p.noise_level,
            volume,
            fm_index: e.fm_index,
        };
        if self.fresh {
            self.ramp = target;
        }
        let from = self.ramp;
        let inv_n = 1.0 / n as f32;

        let mut sum_l = [0.0f32; CONTROL_BLOCK];
        let mut sum_r = [0.0f32; CONTROL_BLOCK];
        let mut osc_buf = [0.0f32; CONTROL_BLOCK];
        let mut level = [0.0f32; CONTROL_BLOCK];
        let mut stereo = false;

        let sr64 = sr as f64;
        for o in 0..2 {
            let osc = &e.osc[o];
            let count = self.unison[o];
            let base = pitch + osc.transpose;
            let (d0, d1) = (from.level_delta[o], target.level_delta[o]);
            let shared = &ctx.levels[o][start..end];
            let mut audible = false;
            for i in 0..n {
                let delta = d0 + (d1 - d0) * (i + 1) as f32 * inv_n;
                level[i] = (shared[i] + delta).clamp(0.0, 1.0);
                audible |= level[i] != 0.0;
            }
            let shape = match self.unison_shape[o] {
                Some(s)
                    if s.count == count
                        && s.detune_cents == osc.detune_cents
                        && s.spread == osc.spread =>
                {
                    s
                }
                _ => {
                    let s = UnisonShape::new(count, osc.detune_cents, osc.spread);
                    self.unison_shape[o] = Some(s);
                    s
                }
            };
            let base_increment = note_to_hz(base) / sr64;
            for k in 0..count {
                let increment = (base_increment * shape.ratio[k]).min(MAX_PHASE_INCREMENT);
                let oscillator = &mut self.oscs[o][k];
                if !audible || self.fresh {
                    oscillator.phase_increment = increment;
                }
                if !audible {
                    continue;
                }
                oscillator.set_pulse_width(osc.pulse_width);
                // FM replaces Osc 1's waveform with a phase-modulated sine.
                if o == 0 && e.fm_index > 0.0 {
                    oscillator.process_fm_ramped(
                        &mut osc_buf[..n],
                        n,
                        increment,
                        e.fm_ratio,
                        from.fm_index,
                        target.fm_index,
                    );
                } else {
                    oscillator.process_block_ramped(osc.wave, &mut osc_buf[..n], n, increment);
                }

                stereo |= shape.stereo;
                let (gl, gr) = (shape.gain_l[k], shape.gain_r[k]);
                for i in 0..n {
                    let s = osc_buf[i] * level[i];
                    sum_l[i] += s * gl;
                    sum_r[i] += s * gr;
                }
            }
        }

        let (d0, d1) = (from.noise_delta, target.noise_delta);
        let shared = &ctx.noise_level[start..end];
        let mut audible = false;
        for i in 0..n {
            let delta = d0 + (d1 - d0) * (i + 1) as f32 * inv_n;
            level[i] = (shared[i] + delta).clamp(0.0, 1.0);
            audible |= level[i] != 0.0;
        }
        if audible {
            // One-pole tilt: dark = low-passed, bright = the remainder, white in the middle.
            // Weights for (low, white, high): crossfade dark → white → bright.
            let color = e.noise_color;
            let (w_low, w_white, w_high) = if color < 0.5 {
                let t = color * 2.0;
                (NOISE_DARK_GAIN * (1.0 - t), t, 0.0)
            } else {
                let t = (color - 0.5) * 2.0;
                (0.0, 1.0 - t, t)
            };
            for i in 0..n {
                let white = self.next_noise();
                self.noise_lp += self.noise_coef * (white - self.noise_lp);
                let high = white - self.noise_lp;
                let s = w_low * self.noise_lp + w_white * white + w_high * high;
                let s = s * level[i] * VOICE_GAIN;
                sum_l[i] += s;
                sum_r[i] += s;
            }
        }

        // Drive → filter → amp. A mono voice filters one channel and copies it.
        let mode = p.filter_mode;
        let resonance = e.resonance;
        let comp = setup.comp;
        let (drive_gain, drive_blend) = svf::drive_params(e.drive_db);
        let velocity_gain = 1.0 - e.velocity_sens * (1.0 - self.velocity);
        let steady = from.g == target.g && from.k == target.k;
        let mut coefs = SvfCoefs::new(target.g, target.k, mode);
        for i in 0..n {
            let t = (i + 1) as f32 * inv_n;
            if !steady {
                let g = from.g + (target.g - from.g) * t;
                let k = from.k + (target.k - from.k) * t;
                coefs = SvfCoefs::new(g, k, mode);
            }
            let x = svf::drive(sum_l[i], drive_gain, drive_blend);
            let l = self.filters[0].process(x, mode, &coefs, comp, resonance);
            let r = if stereo {
                let x = svf::drive(sum_r[i], drive_gain, drive_blend);
                self.filters[1].process(x, mode, &coefs, comp, resonance)
            } else {
                l
            };

            let mut gain = self.amp_env.process_sample()
                * velocity_gain
                * (from.volume + (target.volume - from.volume) * t);
            if self.fade_step > 0.0 {
                self.fade = (self.fade - self.fade_step).max(0.0);
                gain *= self.fade;
            }
            out_l[start + i] += l * gain;
            out_r[start + i] += r * gain;
        }
        if !stereo {
            // Keep the right channel's state in step, so turning spread up doesn't click.
            self.filters[1] = self.filters[0];
        }

        self.ramp = target;
        self.fresh = false;
    }
}
