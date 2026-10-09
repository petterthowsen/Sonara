//! One sampler voice: playback position, loop and crossfade, filter, and block rendering.

use super::params::LoopMode;
use super::regions::{interpolate_frame, zone_at, Regions, SampleBuffer, Zone, SINGLE_ZONE};
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::dsp::svf::{
    compensation_coef, cutoff_to_g, resonance_to_k, FilterMode, Svf, SvfCoefs,
};
use crate::audio::modulation::envelope::{AdsrEnvelope, AdsrState};
use std::f32::consts::FRAC_PI_2;

/// Fade at the end of a non-looping region.
pub(super) const DECLICK_SECONDS: f32 = 0.002;

/// Sentinel key in the queued MIDI list marking a choke (real keys are 0–127).
pub(super) const CHOKE_KEY: u8 = 255;

/// Frames between filter coefficient updates.
pub(super) const FILTER_CHUNK: usize = 32;

pub(super) const FILTER_RAMP_MS: f32 = 5.0;

/// One voice reading its zone's sample through a filter and an ADSR amplitude envelope.
#[derive(Clone, Copy)]
pub(super) struct Voice {
    pub(super) active: bool,
    pub(super) note: u8,
    /// [`SINGLE_ZONE`] or an index into `SamplerDevice::zones`.
    pub(super) zone: u16,
    /// The note-on that started it: a note-off releases all of one note-on's stacked voices.
    pub(super) trigger: u64,
    pub(super) position: f64,
    /// Frames of PCM per output frame, always positive; `direction` gives the sign.
    pub(super) increment: f64,
    /// +1 or −1 (flips on a Ping-Pong bounce).
    pub(super) direction: f64,
    pub(super) in_loop: bool,
    /// Hit the end of a non-looping region: holding there while `fade` runs to 0.
    pub(super) ending: bool,
    pub(super) fade: f32,
    pub(super) gain: f32,
    pub(super) envelope: AdsrEnvelope,
    pub(super) filters: [Svf; 2],
    pub(super) age: u64,
}

impl Voice {
    /// Idle voice with no playback, sized for `sample_rate`.
    pub(super) fn idle(sample_rate: f32) -> Self {
        Self {
            active: false,
            note: 0,
            zone: SINGLE_ZONE,
            trigger: 0,
            position: 0.0,
            increment: 1.0,
            direction: 1.0,
            in_loop: false,
            ending: false,
            fade: 1.0,
            gain: 0.0,
            envelope: AdsrEnvelope::new(sample_rate),
            filters: [Svf::new(); 2],
            age: 0,
        }
    }

    /// True while the voice is sounding and not yet in release.
    pub(super) fn is_held(&self) -> bool {
        self.active && !matches!(self.envelope.state(), AdsrState::Idle | AdsrState::Release)
    }
}

/// Is `pos` inside the loop for a voice moving in `direction`?
pub(super) fn inside_loop(pos: f64, direction: f64, l: (f64, f64)) -> bool {
    if direction > 0.0 {
        pos >= l.0 && pos < l.1
    } else {
        pos > l.0 && pos <= l.1
    }
}

/// Move `v` by one output frame and apply the loop / region boundary rules.
pub(super) fn advance(v: &mut Voice, r: &Regions, mode: LoopMode) {
    if v.ending {
        return;
    }
    v.position += v.increment * v.direction;
    if mode != LoopMode::Off {
        let l = r.loop_;
        if !v.in_loop && inside_loop(v.position, v.direction, l) {
            v.in_loop = true;
        }
        if v.in_loop {
            match mode {
                LoopMode::On => {
                    let outside = if v.direction > 0.0 {
                        v.position >= l.1 || v.position < l.0
                    } else {
                        v.position > l.1 || v.position < l.0
                    };
                    if outside {
                        v.position = l.0 + (v.position - l.0).rem_euclid(r.loop_len());
                    }
                }
                _ => {
                    if v.direction > 0.0 && v.position >= l.1 {
                        v.position = 2.0 * l.1 - v.position;
                        v.direction = -1.0;
                    } else if v.direction < 0.0 && v.position < l.0 {
                        v.position = 2.0 * l.0 - v.position;
                        v.direction = 1.0;
                    }
                    v.position = v.position.clamp(l.0, l.1);
                }
            }
            return;
        }
    }
    if v.direction > 0.0 && v.position >= r.play.1 {
        v.ending = true;
        v.position = (r.play.1 - 1.0).max(r.play.0);
    } else if v.direction < 0.0 && v.position <= r.play.0 {
        v.ending = true;
        v.position = r.play.0;
    }
}

/// The voice's stereo output frame at its position, with the loop crossfade applied.
pub(super) fn read_voice(
    sample: &SampleBuffer,
    v: &Voice,
    r: &Regions,
    mode: LoopMode,
) -> (f32, f32) {
    let (l, rt) = interpolate_frame(sample, v.position);
    if mode != LoopMode::On || !v.in_loop {
        return (l, rt);
    }
    let len = r.loop_len();
    let (xf, dist, other) = if v.direction > 0.0 {
        (r.xfade_fwd, r.loop_.1 - v.position, v.position - len)
    } else {
        (r.xfade_rev, v.position - r.loop_.0, v.position + len)
    };
    if xf <= 0.0 || dist >= xf {
        return (l, rt);
    }
    let t = (1.0 - dist / xf).clamp(0.0, 1.0) as f32 * FRAC_PI_2;
    let (out_gain, in_gain) = (t.cos(), t.sin());
    let (l2, r2) = interpolate_frame(sample, other);
    (l * out_gain + l2 * in_gain, rt * out_gain + r2 * in_gain)
}

/// Cutoff for `note`: `cutoff * 2^(key_track * (note - root) / 12)`.
pub fn tracked_cutoff(cutoff_hz: f32, key_track: f32, note: u8, root: u8) -> f32 {
    cutoff_hz * 2.0_f32.powf(key_track * (note as f32 - root as f32) / 12.0)
}

/// Everything the voice renderer needs besides the voices themselves.
pub(super) struct RenderCtx<'a> {
    pub(super) single: &'a Zone,
    pub(super) zones: &'a [Zone],
    pub(super) filter: Option<FilterMode>,
    pub(super) filter_key_track: f32,
    pub(super) sample_rate: f32,
    pub(super) fade_step: f32,
}

/// Pitch/speed ratio: `speed * 2^((tune + keytrack*(note-root))/12)`.
pub fn playback_increment(speed: f32, tune: f32, key_track: bool, note: u8, root: u8) -> f64 {
    let key_delta = if key_track {
        note as f32 - root as f32
    } else {
        0.0
    };
    let semitones = tune + key_delta;
    (speed as f64) * 2.0_f64.powf(semitones as f64 / 12.0)
}

/// Frames of sample PCM to advance per device output frame so pitch stays native.
pub fn sample_rate_ratio(sample_rate: f32, device_sample_rate: f32) -> f64 {
    sample_rate.max(1.0) as f64 / device_sample_rate.max(1.0) as f64
}

/// Mix active voices into `outputs` for `len` frames starting at `start`, in filter chunks.
pub(super) fn render_active_voices(
    ctx: &RenderCtx,
    voices: &mut [Voice],
    cutoff: &mut SmoothedParam,
    resonance: &mut SmoothedParam,
    outputs: &mut [f32],
    start: usize,
    len: usize,
) {
    let mut done = 0;
    while done < len {
        let n = FILTER_CHUNK.min(len - done);
        for _ in 1..n {
            cutoff.next();
            resonance.next();
        }
        let (cut, res) = (cutoff.next(), resonance.next());
        for voice in voices.iter_mut().filter(|v| v.active) {
            let Some((zone, sample)) = zone_at(ctx.single, ctx.zones, voice.zone)
                .and_then(|z| z.sample.as_ref().map(|s| (z, s)))
            else {
                voice.active = false;
                continue;
            };
            let filter = ctx.filter.map(|mode| {
                let hz = tracked_cutoff(cut, ctx.filter_key_track, voice.note, zone.root);
                let coefs = SvfCoefs::new(
                    cutoff_to_g(hz, ctx.sample_rate),
                    resonance_to_k(res, mode),
                    mode,
                );
                (mode, coefs, compensation_coef(hz * 0.5, ctx.sample_rate))
            });
            for i in 0..n {
                if !voice.active {
                    break;
                }
                let env = voice.envelope.process_sample();
                let (mut l, mut r) = read_voice(sample, voice, &zone.regions, zone.loop_mode);
                if let Some((mode, coefs, comp)) = &filter {
                    l = voice.filters[0].process(l, *mode, coefs, *comp, res);
                    r = voice.filters[1].process(r, *mode, coefs, *comp, res);
                }
                let g = voice.gain * env * voice.fade;
                let idx = (start + done + i) * 2;
                if idx + 1 < outputs.len() {
                    outputs[idx] += l * g;
                    outputs[idx + 1] += r * g;
                }
                advance(voice, &zone.regions, zone.loop_mode);
                if voice.ending {
                    voice.fade -= ctx.fade_step;
                    if voice.fade <= 0.0 {
                        voice.active = false;
                    }
                }
                if !voice.envelope.is_active() {
                    voice.active = false;
                }
            }
        }
        done += n;
    }
}
