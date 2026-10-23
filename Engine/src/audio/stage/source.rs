//! One stage source: its direct sound placed in the room and its reflections for the Stage return.
//!
//! - The input goes into two history lines (one per point), then every tap is a block-wide read
//!   at a delay that ramps from last block's value to this block's, so the inner loops are plain
//!   slice passes and a moving source gets a natural Doppler shift.
//! - Position, size and rotation chase their targets with a ~30 ms one-pole evaluated at the
//!   block boundary; the taps are recomputed per block from the smoothed values.
//! - A stereo source is one point at size 0 and two points (its L and R inputs) when wider.
//!   Mono input is always one point.
//! - A new room crossfades over 50 ms: the old reflections keep rendering from a frozen copy of
//!   the old bank while the new one fades in. A changed mic setup crossfades the direct sound too.
//! - The mic setup (spec 052) decides how many reads a tap takes: one for Pan and the coincident
//!   setups (capsule gains summed), one per capsule for the spaced ones, each with the capsule as
//!   the receiver. Without Distance delay the spaced delays are measured from the point's
//!   earliest capsule arrival, so the array adds no latency.
//! - Everything is allocated in [`StageSource::new`]; `render` never allocates.

use super::image_source::{direct_tap, distance, taps, Tap, TapSet};
use super::mic::{rear_amount, MicArray, MAX_ARRAY_SPAN_M, MAX_CAPSULES};
use super::{
    OutputMode, RoomModel, StageParams, SumMode, Vec3, FIRST_ORDER_SURFACES, SPEED_OF_SOUND,
};
use crate::audio::dsp::one_pole::{one_pole_g, OnePole};
use std::f32::consts::{FRAC_1_SQRT_2, FRAC_PI_2};

const POSITION_TAU_S: f32 = 0.030;
const ROOM_FADE_S: f32 = 0.050;
/// Time to fade reflections out or in when Has room or the output mode changes.
const LEVEL_RAMP_S: f32 = 0.020;
/// Size at which a stereo source's two points carry the full L and R inputs. Below it they blend
/// toward the sum, so a source shrinking to size 0 collapses to one point without a level step.
const SPREAD_FULL_SIZE_M: f32 = 0.5;
/// Below this smoothed size a stereo source renders as one point.
const TWO_POINT_MIN_SIZE_M: f32 = 1e-3;

const FIRST: usize = FIRST_ORDER_SURFACES;
const SECOND: usize = 18;
/// Surface buses 0..6 plus the second-order bus.
const BUSES: usize = FIRST + 1;
const SECOND_BUS: usize = FIRST;

/// Which history lines a tap reads.
#[derive(Clone, Copy, PartialEq)]
enum Reads {
    A,
    B,
    /// A + B, a single point carrying both lines.
    Both,
}

/// A contiguous history of one point's signal. Blocks are appended after `history` samples of
/// past, so a tap read is `buf[start + i - delay]` for output sample `i` with no wrap-around; the
/// past is moved to the front when the end is reached.
struct Line {
    buf: Vec<f32>,
    history: usize,
    /// Where the current block's first sample sits.
    start: usize,
    fill: usize,
}

impl Line {
    fn new(history: usize, max_frames: usize) -> Self {
        Self {
            buf: vec![0.0; history + max_frames * 2],
            history,
            start: history,
            fill: history,
        }
    }

    fn push_block(&mut self, block: &[f32]) {
        if self.fill + block.len() > self.buf.len() {
            self.buf.copy_within(self.fill - self.history..self.fill, 0);
            self.fill = self.history;
        }
        self.start = self.fill;
        self.buf[self.fill..self.fill + block.len()].copy_from_slice(block);
        self.fill += block.len();
    }

    /// Read `out.len()` samples at a delay that moves linearly from `d0` to `d1` samples over the
    /// block, with linear interpolation. `add` accumulates instead of overwriting.
    fn read(&self, d0: f32, d1: f32, out: &mut [f32], add: bool) {
        let n = out.len();
        let max = (self.history - 2) as f32;
        let (d0, d1) = (d0.clamp(0.0, max), d1.clamp(0.0, max));
        if (d1 - d0).abs() < 1e-3 {
            let whole = d1 as usize;
            let frac = d1 - whole as f32;
            let base = self.start - whole;
            let a = &self.buf[base..base + n];
            let b = &self.buf[base - 1..base - 1 + n];
            if add {
                for ((o, &x0), &x1) in out.iter_mut().zip(a).zip(b) {
                    *o += x0 + (x1 - x0) * frac;
                }
            } else {
                for ((o, &x0), &x1) in out.iter_mut().zip(a).zip(b) {
                    *o = x0 + (x1 - x0) * frac;
                }
            }
        } else {
            let step = (d1 - d0) / n as f32;
            for (i, o) in out.iter_mut().enumerate() {
                let d = d0 + step * i as f32;
                let whole = d as usize;
                let frac = d - whole as f32;
                let idx = self.start + i - whole;
                let v = self.buf[idx] + (self.buf[idx - 1] - self.buf[idx]) * frac;
                if add {
                    *o += v;
                } else {
                    *o = v;
                }
            }
        }
    }
}

/// One read of a tap: its delay and stereo gains, what is ramped across a block.
#[derive(Clone, Copy, Default)]
struct CapsuleRamp {
    delay: f32,
    left: f32,
    right: f32,
}

/// A tap's reads, one per capsule in use (`MicArray::reads`; always slot 0 for Pan and the
/// coincident setups).
#[derive(Clone, Copy, Default)]
struct TapRamp {
    caps: [CapsuleRamp; MAX_CAPSULES],
}

/// `tmp * (from → to)` added into the left and right buses.
fn pan_add(tmp: &[f32], from: CapsuleRamp, to: CapsuleRamp, out_l: &mut [f32], out_r: &mut [f32]) {
    let n = tmp.len();
    if from.left == to.left && from.right == to.right {
        for ((l, r), &s) in out_l.iter_mut().zip(out_r.iter_mut()).zip(tmp) {
            *l += s * to.left;
            *r += s * to.right;
        }
    } else {
        let inv = 1.0 / n as f32;
        let (dl, dr) = ((to.left - from.left) * inv, (to.right - from.right) * inv);
        for (i, ((l, r), &s)) in out_l.iter_mut().zip(out_r.iter_mut()).zip(tmp).enumerate() {
            *l += s * (from.left + dl * i as f32);
            *r += s * (from.right + dr * i as f32);
        }
    }
}

/// Shortest signed angle from `from` to `to`, degrees.
fn angle_delta(from: f32, to: f32) -> f32 {
    (to - from + 180.0).rem_euclid(360.0) - 180.0
}

#[derive(Clone, Copy, Default)]
struct Smoothed {
    x: f32,
    y: f32,
    z: f32,
    size: f32,
    rotation: f32,
    primed: bool,
}

impl Smoothed {
    fn update(&mut self, p: &StageParams, frames: usize, sample_rate: f32) {
        if !self.primed {
            *self = Smoothed {
                x: p.x,
                y: p.y,
                z: p.z,
                size: p.size,
                rotation: p.rotation_deg,
                primed: true,
            };
            return;
        }
        let a = 1.0 - (-(frames as f32) / (POSITION_TAU_S * sample_rate)).exp();
        self.x += (p.x - self.x) * a;
        self.y += (p.y - self.y) * a;
        self.z += (p.z - self.z) * a;
        self.size += (p.size - self.size) * a;
        self.rotation += angle_delta(self.rotation, p.rotation_deg) * a;
    }
}

/// Where this block's points are: one, or two `size` apart along the rotation.
struct Geometry {
    points: [Vec3; 2],
    count: usize,
    centre: Vec3,
    reads: [Reads; 2],
    centre_reads: Reads,
}

/// Reflections of one room: the previous block's tap values (to ramp from) and the damping
/// filters of the surface and second-order buses.
///
/// It also holds the direct sound's state (spec 052), so a mic change can render the direct from
/// the old and the new setup at once.
#[derive(Clone)]
struct Bank {
    room: RoomModel,
    mic: MicArray,
    direct_taps: [TapRamp; 2],
    direct_valid: [bool; 2],
    direct_lp: [[OnePole; MAX_CAPSULES]; 2],
    first: [[TapRamp; FIRST]; 2],
    first_valid: [bool; 2],
    second: [TapRamp; SECOND],
    second_valid: bool,
    lp: [[OnePole; 2]; BUSES],
}

impl Bank {
    fn new(room: RoomModel) -> Self {
        Self {
            room,
            mic: MicArray::for_setup(room.mic),
            direct_taps: [TapRamp::default(); 2],
            direct_valid: [false; 2],
            direct_lp: [[OnePole::new(); MAX_CAPSULES]; 2],
            first: [[TapRamp::default(); FIRST]; 2],
            first_valid: [false; 2],
            second: [TapRamp::default(); SECOND],
            second_valid: false,
            lp: [[OnePole::new(); 2]; BUSES],
        }
    }

    fn invalidate(&mut self) {
        self.first_valid = [false; 2];
        self.second_valid = false;
    }

    fn invalidate_direct(&mut self) {
        self.direct_valid = [false; 2];
        self.direct_lp = [[OnePole::new(); MAX_CAPSULES]; 2];
    }
}

/// Cutoff of a surface's damping filter: bright at 0, dull at 1.
fn damping_cutoff_hz(damping: f32) -> f32 {
    let bright = 1.0 - damping.clamp(0.0, 1.0);
    16_000.0 * bright * bright + 500.0
}

/// Cutoff of the air absorption on the direct sound at `r` meters (and behind the listener).
fn air_cutoff_hz(r: f32, rear: f32) -> f32 {
    18_000.0 / (1.0 + r / 8.0) * (1.0 - 0.5 * rear)
}

/// Scratch, sized in `new`.
struct Scratch {
    sig_a: Vec<f32>,
    sig_b: Vec<f32>,
    tmp: Vec<f32>,
    /// The old setup's direct sound while a mic change crossfades.
    direct_l: Vec<f32>,
    direct_r: Vec<f32>,
    bus_l: Vec<Vec<f32>>,
    bus_r: Vec<Vec<f32>>,
}

struct Fade {
    bank: Bank,
    pos: usize,
}

/// A running fade's gains over one chunk, each from the chunk's start to its end.
#[derive(Clone, Copy)]
struct FadeGains {
    new: (f32, f32),
    old: (f32, f32),
    finished: bool,
}

pub struct StageSource {
    sample_rate: f32,
    max_frames: usize,
    lines: [Line; 2],
    scratch: Scratch,
    smooth: Smoothed,
    /// Last block's two-point blend, ramped across the next block.
    blend: f32,
    bank: Bank,
    fade: Option<Fade>,
    /// 1 while reflections render, ramped to 0 for Has room and Direct only.
    level: f32,
    primed: bool,
}

impl StageSource {
    /// `max_frames` is the largest block `render` is called with (longer ones are chunked).
    /// Allocates for the largest room.
    pub fn new(sample_rate: f32, max_frames: usize) -> Self {
        let max_frames = max_frames.max(1);
        let longest = RoomModel {
            width: super::MAX_WIDTH,
            depth: super::MAX_DEPTH,
            height: super::MAX_HEIGHT,
            ..RoomModel::default()
        }
        .max_path();
        let history =
            ((longest + MAX_ARRAY_SPAN_M) / SPEED_OF_SOUND * sample_rate).ceil() as usize + 8;
        let buses = |n: usize| (0..BUSES).map(|_| vec![0.0; n]).collect::<Vec<_>>();
        Self {
            sample_rate,
            max_frames,
            lines: [
                Line::new(history, max_frames),
                Line::new(history, max_frames),
            ],
            scratch: Scratch {
                sig_a: vec![0.0; max_frames],
                sig_b: vec![0.0; max_frames],
                tmp: vec![0.0; max_frames],
                direct_l: vec![0.0; max_frames],
                direct_r: vec![0.0; max_frames],
                bus_l: buses(max_frames),
                bus_r: buses(max_frames),
            },
            smooth: Smoothed::default(),
            blend: 0.0,
            bank: Bank::new(RoomModel::default()),
            fade: None,
            level: 1.0,
            primed: false,
        }
    }

    pub fn room(&self) -> &RoomModel {
        &self.bank.room
    }

    /// Change the room. After the first block this starts a 50 ms crossfade from the old
    /// reflections to the new; the direct sound follows the new listener and Distance delay
    /// through the per-block ramps. A changed mic setup crossfades the direct sound as well.
    pub fn set_room(&mut self, room: RoomModel) {
        let room = room.clamped();
        if room == self.bank.room {
            return;
        }
        if self.primed && self.fade.is_none() {
            self.fade = Some(Fade {
                bank: self.bank.clone(),
                pos: 0,
            });
        }
        let mic_changed = room.mic != self.bank.room.mic;
        self.bank.room = room;
        self.bank.invalidate();
        if mic_changed {
            self.bank.mic = MicArray::for_setup(room.mic);
            self.bank.invalidate_direct();
        }
    }

    /// Silence the history and snap to the current parameters (transport jumps, a rebuild).
    pub fn reset(&mut self) {
        for line in &mut self.lines {
            line.buf.fill(0.0);
            line.fill = line.history;
            line.start = line.history;
        }
        self.smooth.primed = false;
        self.primed = false;
        self.fade = None;
        self.bank.invalidate();
        self.bank.lp = [[OnePole::new(); 2]; BUSES];
        self.bank.invalidate_direct();
    }

    /// Place `buf_l`/`buf_r` (the channel's signal after the fader) in the room. The direct sound
    /// replaces the buffers' contents; the reflections replace `out_stage_l/r`, which are left
    /// silent for Has room and Direct only. `mono_input` marks a source whose L and R are one
    /// signal: it stays a point whatever its size.
    pub fn render(
        &mut self,
        buf_l: &mut [f32],
        buf_r: &mut [f32],
        out_stage_l: &mut [f32],
        out_stage_r: &mut [f32],
        params: &StageParams,
        mono_input: bool,
        frames: usize,
    ) {
        let frames = frames
            .min(buf_l.len())
            .min(buf_r.len())
            .min(out_stage_l.len())
            .min(out_stage_r.len());
        let mut done = 0;
        while done < frames {
            let n = (frames - done).min(self.max_frames);
            let range = done..done + n;
            self.render_chunk(
                &mut buf_l[range.clone()],
                &mut buf_r[range.clone()],
                &mut out_stage_l[range.clone()],
                &mut out_stage_r[range],
                params,
                mono_input,
            );
            done += n;
        }
    }

    fn render_chunk(
        &mut self,
        buf_l: &mut [f32],
        buf_r: &mut [f32],
        out_l: &mut [f32],
        out_r: &mut [f32],
        params: &StageParams,
        mono_input: bool,
    ) {
        let n = buf_l.len();
        let sr = self.sample_rate;
        self.smooth.update(params, n, sr);
        let size = self.smooth.size.max(0.0);

        // Input to the two lines. Stereo: each point's signal blends from half the sum (one
        // point) to its own channel (full spread) with the size.
        let blend_to = (size / SPREAD_FULL_SIZE_M).clamp(0.0, 1.0);
        if !self.primed {
            self.blend = blend_to;
        }
        let blend_from = self.blend;
        let sum_gain = match params.sum_mode {
            SumMode::LPlusR => FRAC_1_SQRT_2,
            SumMode::Mid => 0.5,
        };
        if mono_input {
            for i in 0..n {
                self.scratch.sig_a[i] = (buf_l[i] + buf_r[i]) * 0.5;
            }
            self.scratch.sig_b[..n].fill(0.0);
        } else {
            let step = (blend_to - blend_from) / n as f32;
            for i in 0..n {
                let half = (buf_l[i] + buf_r[i]) * sum_gain * 0.5;
                let t = blend_from + step * i as f32;
                self.scratch.sig_a[i] = half + (buf_l[i] - half) * t;
                self.scratch.sig_b[i] = half + (buf_r[i] - half) * t;
            }
        }
        self.blend = blend_to;
        self.lines[0].push_block(&self.scratch.sig_a[..n]);
        self.lines[1].push_block(&self.scratch.sig_b[..n]);

        let two_point = !mono_input && size > TWO_POINT_MIN_SIZE_M;
        let single = if mono_input { Reads::A } else { Reads::Both };
        let room = self.bank.room;
        let geometry = |room: &RoomModel, s: &Smoothed| -> Geometry {
            let centre = room.clamp_point(Vec3::new(s.x, s.y, s.z));
            if two_point {
                let (sin, cos) = s.rotation.to_radians().sin_cos();
                let half = size * 0.5;
                let off = Vec3::new(cos * half, sin * half, 0.0);
                Geometry {
                    points: [
                        room.clamp_point(Vec3::new(centre.x - off.x, centre.y - off.y, centre.z)),
                        room.clamp_point(Vec3::new(centre.x + off.x, centre.y + off.y, centre.z)),
                    ],
                    count: 2,
                    centre,
                    reads: [Reads::A, Reads::B],
                    centre_reads: Reads::Both,
                }
            } else {
                Geometry {
                    points: [centre; 2],
                    count: 1,
                    centre,
                    reads: [single; 2],
                    centre_reads: single,
                }
            }
        };

        // A running fade: its gains serve the reflections and, when the mic setup differs, the
        // direct sound.
        let fade = self.fade_gains(n);
        let mic_fade = match &self.fade {
            Some(f) if f.bank.room.mic != room.mic => fade,
            _ => None,
        };
        let geo = geometry(&room, &self.smooth);
        self.render_direct(&geometry, &geo, buf_l, buf_r, mic_fade);

        // Reflections: ramp the level toward its target, render nothing while it is 0.
        let target = if params.has_room || room.output_mode == OutputMode::DirectOnly {
            0.0
        } else {
            1.0
        };
        if !self.primed {
            self.level = target;
        }
        let level0 = self.level;
        let level1 = if target > level0 {
            (level0 + n as f32 / (LEVEL_RAMP_S * sr)).min(target)
        } else {
            (level0 - n as f32 / (LEVEL_RAMP_S * sr)).max(target)
        };
        self.level = level1;
        out_l.fill(0.0);
        out_r.fill(0.0);
        if level0 > 0.0 || level1 > 0.0 {
            self.render_reflections(&geometry, out_l, out_r, (level0, level1), fade);
        } else {
            if mic_fade.is_none() {
                self.fade = None;
            }
            self.bank.invalidate();
        }
        if let Some(gains) = fade {
            if let Some(f) = &mut self.fade {
                f.pos += n;
            }
            if gains.finished {
                self.fade = None;
            }
        }
        self.primed = true;
    }

    /// The running fade's gains for a chunk of `n` frames.
    fn fade_gains(&self, n: usize) -> Option<FadeGains> {
        let fade = self.fade.as_ref()?;
        let fade_len = (ROOM_FADE_S * self.sample_rate) as usize;
        let p0 = (fade.pos as f32 / fade_len as f32).min(1.0);
        let p1 = ((fade.pos + n) as f32 / fade_len as f32).min(1.0);
        let sin = |p: f32| (p * FRAC_PI_2).sin();
        let cos = |p: f32| (p * FRAC_PI_2).cos();
        Some(FadeGains {
            new: (sin(p0), sin(p1)),
            old: (cos(p0), cos(p1)),
            finished: p1 >= 1.0,
        })
    }

    /// The direct path: each point's line read, air-absorbed, panned and written over the buffer.
    /// While a mic change fades, the old setup's direct sound is rendered too and the two are
    /// crossfaded.
    fn render_direct(
        &mut self,
        geometry: &dyn Fn(&RoomModel, &Smoothed) -> Geometry,
        geo: &Geometry,
        buf_l: &mut [f32],
        buf_r: &mut [f32],
        mic_fade: Option<FadeGains>,
    ) {
        let n = buf_l.len();
        let sr = self.sample_rate;
        render_direct_bank(
            &mut self.bank,
            geo,
            &self.lines,
            &mut self.scratch.tmp[..n],
            sr,
            buf_l,
            buf_r,
        );
        if let (Some(g), Some(fade)) = (mic_fade, self.fade.as_mut()) {
            let old_geo = geometry(&fade.bank.room, &self.smooth);
            let old_l = &mut self.scratch.direct_l[..n];
            let old_r = &mut self.scratch.direct_r[..n];
            render_direct_bank(
                &mut fade.bank,
                &old_geo,
                &self.lines,
                &mut self.scratch.tmp[..n],
                sr,
                old_l,
                old_r,
            );
            let inv = 1.0 / n as f32;
            let (new_step, old_step) = ((g.new.1 - g.new.0) * inv, (g.old.1 - g.old.0) * inv);
            for i in 0..n {
                let (gn, go) = (g.new.0 + new_step * i as f32, g.old.0 + old_step * i as f32);
                buf_l[i] = buf_l[i] * gn + old_l[i] * go;
                buf_r[i] = buf_r[i] * gn + old_r[i] * go;
            }
        }
    }

    fn render_reflections(
        &mut self,
        geometry: &dyn Fn(&RoomModel, &Smoothed) -> Geometry,
        out_l: &mut [f32],
        out_r: &mut [f32],
        level: (f32, f32),
        fade: Option<FadeGains>,
    ) {
        let (mut new_gain, mut old_gain) = ((level.0, level.1), (0.0, 0.0));
        if let Some(g) = fade {
            new_gain = (level.0 * g.new.0, level.1 * g.new.1);
            old_gain = (level.0 * g.old.0, level.1 * g.old.1);
        }
        let smooth = self.smooth;

        let geo = geometry(&self.bank.room, &smooth);
        render_bank(
            &mut self.bank,
            &geo,
            &self.lines,
            &mut self.scratch,
            self.sample_rate,
            out_l,
            out_r,
            new_gain,
        );
        if let Some(fade) = &mut self.fade {
            let geo = geometry(&fade.bank.room, &smooth);
            render_bank(
                &mut fade.bank,
                &geo,
                &self.lines,
                &mut self.scratch,
                self.sample_rate,
                out_l,
                out_r,
                old_gain,
            );
        }
    }
}

/// One bank's direct sound: each point's line read per capsule, air-absorbed, mixed to left and
/// right and written over `out_l/r`.
fn render_direct_bank(
    bank: &mut Bank,
    geo: &Geometry,
    lines: &[Line; 2],
    tmp: &mut [f32],
    sr: f32,
    out_l: &mut [f32],
    out_r: &mut [f32],
) {
    let room = bank.room;
    let reads = bank.mic.reads();
    out_l.fill(0.0);
    out_r.fill(0.0);
    for k in 0..2 {
        if k >= geo.count {
            bank.direct_valid[k] = false;
            continue;
        }
        let point = geo.points[k];
        let mut to = TapRamp::default();
        let mut rear = [0.0f32; MAX_CAPSULES];
        let mut dist = [0.0f32; MAX_CAPSULES];
        if bank.mic.is_spaced() {
            let mut direct = [Tap::default(); MAX_CAPSULES];
            let mut earliest = f32::MAX;
            for c in 0..reads {
                let pos = bank.mic.capsule_position_in(c, &room);
                direct[c] = direct_tap(point, pos, true);
                dist[c] = distance(point, pos);
                earliest = earliest.min(direct[c].delay_s);
            }
            let reference = if room.distance_delay { 0.0 } else { earliest };
            for c in 0..reads {
                let g = bank.mic.capsule_gains(c, direct[c].dir);
                rear[c] = rear_amount(direct[c].dir);
                to.caps[c] = CapsuleRamp {
                    delay: (direct[c].delay_s - reference) * sr,
                    left: direct[c].gain * g[0],
                    right: direct[c].gain * g[1],
                };
            }
        } else {
            let tap = direct_tap(point, room.listener, room.distance_delay);
            let mut gains = [0.0; 2];
            rear[0] = bank.mic.coincident_gains(tap.dir, &mut gains);
            dist[0] = distance(point, room.listener);
            to.caps[0] = CapsuleRamp {
                delay: tap.delay_s * sr,
                left: tap.gain * gains[0],
                right: tap.gain * gains[1],
            };
        }
        let n = out_l.len();
        for c in 0..reads {
            let from = if bank.direct_valid[k] {
                bank.direct_taps[k].caps[c]
            } else {
                to.caps[c]
            };
            let g = one_pole_g(air_cutoff_hz(dist[c], rear[c]), sr);
            read_tap(
                lines,
                geo.reads[k],
                from.delay,
                to.caps[c].delay,
                &mut tmp[..n],
            );
            for s in &mut tmp[..n] {
                *s = bank.direct_lp[k][c].lowpass(*s, g);
            }
            pan_add(&tmp[..n], from, to.caps[c], out_l, out_r);
        }
        bank.direct_taps[k] = to;
        bank.direct_valid[k] = true;
    }
}

fn read_tap(lines: &[Line; 2], reads: Reads, d0: f32, d1: f32, out: &mut [f32]) {
    match reads {
        Reads::A => lines[0].read(d0, d1, out, false),
        Reads::B => lines[1].read(d0, d1, out, false),
        Reads::Both => {
            lines[0].read(d0, d1, out, false);
            lines[1].read(d0, d1, out, true);
        }
    }
}

/// The taps of one point heard by a mic array: one set for Pan and coincident setups (heard at
/// the Listener), one per capsule for spaced ones (heard at the capsule, always with absolute
/// flight times).
struct ArrayTaps {
    sets: [TapSet; MAX_CAPSULES],
    /// Spaced setups without Distance delay: the earliest direct arrival, taken off every delay.
    reference_s: f32,
}

fn array_taps(room: &RoomModel, mic: &MicArray, point: Vec3) -> ArrayTaps {
    let mut out = ArrayTaps {
        sets: [TapSet::default(); MAX_CAPSULES],
        reference_s: 0.0,
    };
    if mic.is_spaced() {
        let mut earliest = f32::MAX;
        for c in 0..mic.reads() {
            let pos = mic.capsule_position_in(c, room);
            out.sets[c] = taps(room, point, pos, true);
            earliest = earliest.min(out.sets[c].direct.delay_s);
        }
        if !room.distance_delay {
            out.reference_s = earliest;
        }
    } else {
        out.sets[0] = taps(room, point, room.listener, room.distance_delay);
    }
    out
}

/// The reads of one tap (picked from each set by `pick`) with their delays and gains.
fn tap_ramp(
    arr: &ArrayTaps,
    mic: &MicArray,
    sample_rate: f32,
    pick: impl Fn(&TapSet) -> &Tap,
) -> TapRamp {
    let mut ramp = TapRamp::default();
    if mic.is_spaced() {
        for c in 0..mic.reads() {
            let tap = pick(&arr.sets[c]);
            let g = mic.capsule_gains(c, tap.dir);
            ramp.caps[c] = CapsuleRamp {
                delay: (tap.delay_s - arr.reference_s) * sample_rate,
                left: tap.gain * g[0],
                right: tap.gain * g[1],
            };
        }
    } else {
        let tap = pick(&arr.sets[0]);
        let mut gains = [0.0; 2];
        mic.coincident_gains(tap.dir, &mut gains);
        ramp.caps[0] = CapsuleRamp {
            delay: tap.delay_s * sample_rate,
            left: tap.gain * gains[0],
            right: tap.gain * gains[1],
        };
    }
    ramp
}

/// Read a tap's capsules from `from` to `to` and add them into the buses.
#[allow(clippy::too_many_arguments)]
fn add_tap(
    lines: &[Line; 2],
    reads: Reads,
    reads_per_tap: usize,
    from: &TapRamp,
    to: &TapRamp,
    tmp: &mut [f32],
    bus_l: &mut [f32],
    bus_r: &mut [f32],
) {
    for c in 0..reads_per_tap {
        read_tap(lines, reads, from.caps[c].delay, to.caps[c].delay, tmp);
        pan_add(tmp, from.caps[c], to.caps[c], bus_l, bus_r);
    }
}

/// One bank's first-order taps (a bus per surface) and second-order taps (one bus) filtered by
/// damping and added into `out_l/r` with a gain ramp.
#[allow(clippy::too_many_arguments)]
fn render_bank(
    bank: &mut Bank,
    geo: &Geometry,
    lines: &[Line; 2],
    scratch: &mut Scratch,
    sample_rate: f32,
    out_l: &mut [f32],
    out_r: &mut [f32],
    gain: (f32, f32),
) {
    let n = out_l.len();
    let room = bank.room;
    let mic = bank.mic;
    let reads = mic.reads();
    for b in 0..BUSES {
        scratch.bus_l[b][..n].fill(0.0);
        scratch.bus_r[b][..n].fill(0.0);
    }

    let mut centre_taps: Option<ArrayTaps> = None;
    for k in 0..geo.count {
        let arr = array_taps(&room, &mic, geo.points[k]);
        for t in 0..FIRST {
            let to = tap_ramp(&arr, &mic, sample_rate, |s| &s.first[t]);
            let from = if bank.first_valid[k] {
                bank.first[k][t]
            } else {
                to
            };
            let bus = arr.sets[0].first[t].surface.map_or(0, |s| s as usize);
            add_tap(
                lines,
                geo.reads[k],
                reads,
                &from,
                &to,
                &mut scratch.tmp[..n],
                &mut scratch.bus_l[bus][..n],
                &mut scratch.bus_r[bus][..n],
            );
            bank.first[k][t] = to;
        }
        bank.first_valid[k] = true;
        if geo.count == 1 {
            centre_taps = Some(arr);
        }
    }
    for k in geo.count..2 {
        bank.first_valid[k] = false;
    }

    // Second order from the centre point's mono sum.
    let arr = centre_taps.unwrap_or_else(|| array_taps(&room, &mic, geo.centre));
    for t in 0..SECOND {
        let to = tap_ramp(&arr, &mic, sample_rate, |s| &s.second[t]);
        let from = if bank.second_valid {
            bank.second[t]
        } else {
            to
        };
        add_tap(
            lines,
            geo.centre_reads,
            reads,
            &from,
            &to,
            &mut scratch.tmp[..n],
            &mut scratch.bus_l[SECOND_BUS][..n],
            &mut scratch.bus_r[SECOND_BUS][..n],
        );
        bank.second[t] = to;
    }
    bank.second_valid = true;

    // Damping per bus, then the summed, gain-ramped result.
    let second_damping = arr.sets[0].second.iter().map(|t| t.damping).sum::<f32>() / SECOND as f32;
    let step = (gain.1 - gain.0) / n as f32;
    for b in 0..BUSES {
        let damping = if b == SECOND_BUS {
            second_damping
        } else {
            room.surfaces[b].hf_damping
        };
        let g = one_pole_g(damping_cutoff_hz(damping), sample_rate);
        let (bus_l, bus_r) = (&mut scratch.bus_l[b], &mut scratch.bus_r[b]);
        for i in 0..n {
            let ramp = gain.0 + step * i as f32;
            out_l[i] += bank.lp[b][0].lowpass(bus_l[i], g) * ramp;
            out_r[i] += bank.lp[b][1].lowpass(bus_r[i], g) * ramp;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{pink_noise, rms, sine, white_noise};
    use crate::audio::stage::mic::MicSetup;
    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;

    // Counts allocations made on the test's own thread while `COUNTING` is set.
    struct CountingAlloc;
    thread_local! {
        static COUNTING: Cell<bool> = const { Cell::new(false) };
        static ALLOCS: Cell<usize> = const { Cell::new(0) };
    }
    unsafe impl GlobalAlloc for CountingAlloc {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            if COUNTING.with(|c| c.get()) {
                ALLOCS.with(|a| a.set(a.get() + 1));
            }
            System.alloc(layout)
        }
        unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
            System.dealloc(ptr, layout)
        }
        unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
            if COUNTING.with(|c| c.get()) {
                ALLOCS.with(|a| a.set(a.get() + 1));
            }
            System.realloc(ptr, layout, new_size)
        }
    }
    #[global_allocator]
    static ALLOC: CountingAlloc = CountingAlloc;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 512;

    fn room() -> RoomModel {
        RoomModel {
            width: 20.0,
            depth: 25.0,
            height: 10.0,
            listener: Vec3::new(10.0, 18.0, 1.5),
            ..RoomModel::default()
        }
    }

    fn params(x: f32, y: f32) -> StageParams {
        StageParams {
            x,
            y,
            z: 1.5,
            ..StageParams::default()
        }
    }

    fn source(room: RoomModel) -> StageSource {
        let mut s = StageSource::new(SR, BLOCK);
        s.set_room(room);
        s
    }

    /// Output of a block-by-block render: direct L/R and the reflections L/R.
    #[derive(Default)]
    struct Out {
        l: Vec<f32>,
        r: Vec<f32>,
        sl: Vec<f32>,
        sr: Vec<f32>,
    }

    fn run(s: &mut StageSource, l: &[f32], r: &[f32], p: &StageParams, mono: bool, out: &mut Out) {
        for (cl, cr) in l.chunks(BLOCK).zip(r.chunks(BLOCK)) {
            let n = cl.len();
            let (mut bl, mut br) = (cl.to_vec(), cr.to_vec());
            let (mut sl, mut sr) = (vec![9.0; n], vec![9.0; n]);
            s.render(&mut bl, &mut br, &mut sl, &mut sr, p, mono, n);
            out.l.extend(bl);
            out.r.extend(br);
            out.sl.extend(sl);
            out.sr.extend(sr);
        }
    }

    fn render(room: RoomModel, l: &[f32], r: &[f32], p: &StageParams, mono: bool) -> Out {
        let mut s = source(room);
        let mut out = Out::default();
        run(&mut s, l, r, p, mono, &mut out);
        out
    }

    fn noise(frames: usize) -> Vec<f32> {
        white_noise(frames, 0.5, 7)
    }

    fn hf_ratio(x: &[f32]) -> f32 {
        let mut hp = OnePole::new();
        let g = one_pole_g(8_000.0, SR);
        let hf: Vec<f32> = x.iter().map(|&v| hp.highpass(v, g)).collect();
        rms(&hf) / rms(x)
    }

    fn max_step(x: &[f32]) -> f32 {
        x.windows(2)
            .map(|w| (w[1] - w[0]).abs())
            .fold(0.0, f32::max)
    }

    #[test]
    fn farther_is_quieter_and_duller() {
        let x = noise(BLOCK * 20);
        // 3 m and 15 m in front of the listener.
        let near = render(room(), &x, &x, &params(10.0, 15.0), true);
        let far = render(room(), &x, &x, &params(10.0, 3.0), true);
        let tail = BLOCK * 4..;
        assert!(rms(&far.l[tail.clone()]) < rms(&near.l[tail.clone()]) * 0.5);
        assert!(hf_ratio(&far.l[tail.clone()]) < hf_ratio(&near.l[tail]) * 0.95);
    }

    #[test]
    fn left_source_is_left() {
        let x = noise(BLOCK * 8);
        let out = render(room(), &x, &x, &params(5.0, 8.0), true);
        assert!(rms(&out.l) > rms(&out.r) * 1.5);
        let out = render(room(), &x, &x, &params(15.0, 8.0), true);
        assert!(rms(&out.r) > rms(&out.l) * 1.5);
    }

    #[test]
    fn size_spreads_stereo_inputs() {
        let x = noise(BLOCK * 8);
        let silent = vec![0.0; x.len()];
        let at = |size: f32| StageParams {
            size,
            ..params(10.0, 8.0)
        };
        // Wide: the left input sits at the left point, so it is louder on the left output than
        // the right input is.
        let l_only = render(room(), &x, &silent, &at(10.0), false);
        let r_only = render(room(), &silent, &x, &at(10.0), false);
        assert!(rms(&l_only.l) > rms(&r_only.l) * 2.0);
        assert!(rms(&r_only.r) > rms(&l_only.r) * 2.0);
        // Size 0: one centred point, both inputs match.
        let l_only = render(room(), &x, &silent, &at(0.0), false);
        let r_only = render(room(), &silent, &x, &at(0.0), false);
        assert!((rms(&l_only.l) - rms(&r_only.l)).abs() < 1e-4);
        assert!((rms(&l_only.r) - rms(&r_only.r)).abs() < 1e-4);
    }

    #[test]
    fn mono_ignores_size() {
        let x = noise(BLOCK * 8);
        let at = |size: f32| StageParams {
            size,
            ..params(10.0, 8.0)
        };
        let a = render(room(), &x, &x, &at(0.0), true);
        let b = render(room(), &x, &x, &at(10.0), true);
        for (u, v) in a.l.iter().zip(&b.l).chain(a.sl.iter().zip(&b.sl)) {
            assert!((u - v).abs() < 1e-6);
        }
    }

    #[test]
    fn position_jump_has_no_step() {
        let x = sine(440.0, SR, BLOCK * 40, 0.5);
        let natural = {
            let o = render(room(), &x, &x, &params(5.0, 8.0), true);
            max_step(&o.l[BLOCK * 4..]).max(max_step(&o.r[BLOCK * 4..]))
        };
        let mut s = source(room());
        let mut out = Out::default();
        let half = BLOCK * 20;
        run(
            &mut s,
            &x[..half],
            &x[..half],
            &params(5.0, 8.0),
            true,
            &mut out,
        );
        run(
            &mut s,
            &x[half..],
            &x[half..],
            &params(15.0, 8.0),
            true,
            &mut out,
        );
        // The jump crosses the listener's centre: the pan gains glide instead of stepping.
        assert!(
            max_step(&out.l) <= natural * 1.5,
            "{} vs {natural}",
            max_step(&out.l)
        );
        assert!(max_step(&out.r) <= natural * 1.5);
        assert!(max_step(&out.sl[BLOCK * 4..]) < 0.5);
        // And it did move.
        assert!(rms(&out.l[..half]) > rms(&out.r[..half]) * 2.0);
        assert!(rms(&out.r[half + BLOCK * 15..]) > rms(&out.l[half + BLOCK * 15..]) * 2.0);
    }

    #[test]
    fn room_change_crossfades() {
        let x = sine(200.0, SR, BLOCK * 80, 0.5);
        let mut s = source(room());
        let p = params(6.0, 8.0);
        let mut out = Out::default();
        let before = BLOCK * 30;
        run(&mut s, &x[..before], &x[..before], &p, true, &mut out);
        let steady = max_step(&out.sl[BLOCK * 10..]);
        let mut bigger = room();
        bigger.width = 40.0;
        bigger.depth = 35.0;
        s.set_room(bigger);
        let mut after = Out::default();
        run(&mut s, &x[before..], &x[before..], &p, true, &mut after);
        // The reflections change a lot but the output stays continuous through the switch.
        let joined: Vec<f32> = out.sl[out.sl.len() - 8..]
            .iter()
            .chain(after.sl[..BLOCK * 6].iter())
            .copied()
            .collect();
        assert!(
            max_step(&joined) < steady * 2.0,
            "{} vs {steady}",
            max_step(&joined)
        );
        // Once the fade is over it sounds like a source that always had the new room.
        let fresh = render(bigger, &x, &x, &p, true);
        let tail = before + BLOCK * 30;
        let diff: Vec<f32> = after.sl[tail - before..]
            .iter()
            .zip(&fresh.sl[tail..])
            .map(|(a, b)| a - b)
            .collect();
        assert!(rms(&diff) < 0.01 * rms(&fresh.sl[tail..]), "{}", rms(&diff));
        assert!(s.fade.is_none());
    }

    #[test]
    fn has_room_writes_no_reflections() {
        let x = noise(BLOCK * 8);
        let with = render(room(), &x, &x, &params(8.0, 8.0), true);
        assert!(rms(&with.sl) > 0.01);
        let has_room = StageParams {
            has_room: true,
            ..params(8.0, 8.0)
        };
        let out = render(room(), &x, &x, &has_room, true);
        assert!(out.sl.iter().chain(&out.sr).all(|&v| v == 0.0));
        assert!(rms(&out.l) > 0.05, "direct sound is still rendered");
        let mut direct_only = room();
        direct_only.output_mode = OutputMode::DirectOnly;
        let out = render(direct_only, &x, &x, &params(8.0, 8.0), true);
        assert!(out.sl.iter().chain(&out.sr).all(|&v| v == 0.0));
    }

    #[test]
    fn impulse_arrives_with_distance_delay_only_when_on() {
        let mut x = vec![0.0; BLOCK * 8];
        x[0] = 1.0;
        let peak = |v: &[f32]| {
            v.iter()
                .enumerate()
                .max_by(|a, b| a.1.abs().total_cmp(&b.1.abs()))
                .unwrap()
                .0
        };
        // 17 m in front of the listener.
        let p = params(10.0, 1.0);
        let off = render(room(), &x, &x, &p, true);
        // The air-absorption low-pass moves the peak by a sample at most.
        assert!(peak(&off.l) <= 1, "{}", peak(&off.l));
        let mut delayed = room();
        delayed.distance_delay = true;
        let on = render(delayed, &x, &x, &p, true);
        let expected = 17.0 / SPEED_OF_SOUND * SR;
        assert!(
            (peak(&on.l) as f32 - expected).abs() <= 2.0,
            "{}",
            peak(&on.l)
        );
        // The first reflection lags the direct sound by the same amount in both.
        let first_refl = |o: &Out| peak(&o.sl);
        let lag = |o: &Out| first_refl(o) as i32 - peak(&o.l) as i32;
        assert!(
            (lag(&off) - lag(&on)).abs() <= 3,
            "{} vs {}",
            lag(&off),
            lag(&on)
        );
    }

    #[test]
    fn render_does_not_allocate() {
        let x = noise(BLOCK);
        let mut s = source(room());
        let mut out = Out::default();
        run(&mut s, &x, &x, &params(5.0, 8.0), false, &mut out);
        // Everything below must run on preallocated buffers: moving, resizing, a room change
        // with its crossfade, a chunked long block and every flag.
        let mut bl = vec![0.0f32; BLOCK * 3];
        let mut br = vec![0.0f32; BLOCK * 3];
        let (mut sl, mut sr) = (vec![0.0f32; BLOCK * 3], vec![0.0f32; BLOCK * 3]);
        bl.copy_from_slice(&noise(BLOCK * 3));
        br.copy_from_slice(&bl);
        COUNTING.with(|c| c.set(true));
        ALLOCS.with(|a| a.set(0));
        // Every mic setup, switched mid-render so each one crossfades from the last.
        let mut cur = room();
        for i in 0..40 {
            if i % 4 == 0 {
                cur.mic = MicSetup::ALL[(i / 4) % MicSetup::ALL.len()];
                s.set_room(cur);
            }
            let p = StageParams {
                x: (i % 7) as f32 * 2.0,
                size: (i % 5) as f32 * 3.0,
                rotation_deg: i as f32 * 40.0,
                has_room: i % 9 == 4,
                ..params(5.0, 8.0)
            };
            if i == 10 {
                cur.width = 33.0;
                cur.distance_delay = true;
                s.set_room(cur);
            }
            s.render(
                &mut bl,
                &mut br,
                &mut sl,
                &mut sr,
                &p,
                i % 3 == 0,
                BLOCK * 3,
            );
        }
        s.reset();
        s.render(
            &mut bl,
            &mut br,
            &mut sl,
            &mut sr,
            &params(1.0, 1.0),
            true,
            100,
        );
        COUNTING.with(|c| c.set(false));
        assert_eq!(ALLOCS.with(|a| a.get()), 0, "render allocated");
    }

    // ---- Mic setups (spec 052) ----

    fn mic_room(mic: MicSetup) -> RoomModel {
        RoomModel {
            width: 40.0,
            mic,
            ..room()
        }
    }

    fn impulse_in(len: usize) -> Vec<f32> {
        let mut x = vec![0.0; len];
        x[0] = 1.0;
        x
    }

    fn peak_index(v: &[f32]) -> usize {
        v.iter()
            .enumerate()
            .max_by(|a, b| a.1.abs().total_cmp(&b.1.abs()))
            .unwrap()
            .0
    }

    /// First sample whose magnitude passes `threshold`.
    fn first_over(v: &[f32], threshold: f32) -> usize {
        v.iter().position(|s| s.abs() > threshold).unwrap()
    }

    #[test]
    fn ab_time_difference() {
        let x = impulse_in(BLOCK * 2);
        // 10 m to the right of the listener: the right capsule is 0.6 m nearer.
        let out = render(mic_room(MicSetup::Ab), &x, &x, &params(20.0, 18.0), true);
        let (l, r) = (peak_index(&out.l), peak_index(&out.r));
        let expected = 0.6 / SPEED_OF_SOUND * SR;
        assert!(
            ((l as f32 - r as f32) - expected).abs() <= 1.0,
            "L {l} R {r} expected {expected}"
        );
        assert!(r <= 1, "no latency is added: R at {r}");
        // Straight ahead: both capsules are equally far.
        let out = render(mic_room(MicSetup::Ab), &x, &x, &params(10.0, 8.0), true);
        assert_eq!(peak_index(&out.l), peak_index(&out.r));
    }

    #[test]
    fn decca_centre_arrives_first() {
        let x = impulse_in(BLOCK * 2);
        // 10 m straight ahead.
        let out = render(mic_room(MicSetup::Decca), &x, &x, &params(10.0, 8.0), true);
        let (l0, r0) = (first_over(&out.l, 0.05), first_over(&out.r, 0.05));
        assert_eq!(l0, r0, "the centre capsule lands on both outputs together");
        assert!(l0 <= 1, "the centre is the reference: {l0}");
        assert!((out.l[l0] - out.r[r0]).abs() < 1e-6);
        // L and R follow 1.55 m (sqrt(10^2 + 1) - 8.5 m) later.
        let later = ((101.0f32).sqrt() - 8.5) / SPEED_OF_SOUND * SR;
        let search = |v: &[f32]| {
            let from = (later as usize) - 8;
            from + peak_index(&v[from..from + 16])
        };
        for v in [&out.l, &out.r] {
            let i = search(v);
            assert!((i as f32 - later).abs() <= 2.0, "{i} vs {later}");
            assert!(v[i].abs() > 0.1);
        }
    }

    #[test]
    fn mic_setups_match_pan_level() {
        // Pink noise from a centred source 5 m in front of the listener.
        let x = pink_noise(BLOCK * 80, 0.5, 11);
        let level = |mic: MicSetup| {
            let out = render(mic_room(mic), &x, &x, &params(10.0, 13.0), true);
            let tail = BLOCK * 8..;
            let (l, r) = (rms(&out.l[tail.clone()]), rms(&out.r[tail]));
            10.0 * (l * l + r * r).log10()
        };
        let pan = level(MicSetup::Pan);
        for mic in MicSetup::ALL {
            let db = level(mic) - pan;
            assert!(db.abs() <= 1.5, "{mic:?}: {db:+.2} dB against Pan");
        }
    }

    #[test]
    fn mic_change_crossfades() {
        let x = sine(200.0, SR, BLOCK * 80, 0.5);
        let p = params(6.0, 8.0);
        for to in [
            MicSetup::Decca,
            MicSetup::Ab,
            MicSetup::Blumlein,
            MicSetup::MidSide,
        ] {
            let mut s = source(mic_room(MicSetup::Pan));
            let mut out = Out::default();
            let before = BLOCK * 30;
            run(&mut s, &x[..before], &x[..before], &p, true, &mut out);
            let steady = max_step(&out.l[BLOCK * 10..]).max(max_step(&out.r[BLOCK * 10..]));
            s.set_room(mic_room(to));
            assert!(s.fade.is_some());
            let mut after = Out::default();
            run(&mut s, &x[before..], &x[before..], &p, true, &mut after);
            for (b, a) in [(&out.l, &after.l), (&out.r, &after.r)] {
                let joined: Vec<f32> = b[b.len() - 8..]
                    .iter()
                    .chain(a[..BLOCK * 6].iter())
                    .copied()
                    .collect();
                assert!(
                    max_step(&joined) < steady * 2.0,
                    "{to:?}: {} vs {steady}",
                    max_step(&joined)
                );
            }
            assert!(s.fade.is_none(), "the fade ends");
            // Afterwards it sounds like a source that always had the new setup.
            let fresh = render(mic_room(to), &x, &x, &p, true);
            let tail = before + BLOCK * 30;
            for (a, f) in [(&after.l, &fresh.l), (&after.r, &fresh.r)] {
                let diff: Vec<f32> = a[tail - before..]
                    .iter()
                    .zip(&f[tail..])
                    .map(|(a, b)| a - b)
                    .collect();
                assert!(
                    rms(&diff) < 0.01 * rms(&f[tail..]).max(1e-3),
                    "{to:?}: {}",
                    rms(&diff)
                );
            }
        }
    }

    #[test]
    fn room_change_with_same_mic_keeps_the_direct_ramp() {
        let x = noise(BLOCK * 4);
        let mut s = source(mic_room(MicSetup::Ab));
        let mut out = Out::default();
        run(&mut s, &x, &x, &params(5.0, 8.0), true, &mut out);
        let mut moved = mic_room(MicSetup::Ab);
        moved.listener.x = 14.0;
        s.set_room(moved);
        assert!(
            s.bank.direct_valid[0],
            "direct state survives a room change"
        );
        s.set_room(mic_room(MicSetup::Decca));
        assert!(!s.bank.direct_valid[0], "but not a mic change");
    }

    /// Cost of the stage pass per mic setup: `cargo test --release stage_cost_per_mic_setup --
    /// --ignored --nocapture`.
    #[test]
    #[ignore]
    fn stage_cost_per_mic_setup() {
        const SOURCES: usize = 32;
        const FRAMES: usize = 256;
        const BLOCKS: usize = 600;
        let input = noise(FRAMES * 4);
        let mut baseline = 0.0;
        for mic in MicSetup::ALL {
            let room = RoomModel {
                width: crate::audio::stage::MAX_WIDTH,
                depth: crate::audio::stage::MAX_DEPTH,
                height: crate::audio::stage::MAX_HEIGHT,
                listener: Vec3::new(30.0, 30.0, 1.5),
                mic,
                ..RoomModel::default()
            };
            let mut sources: Vec<StageSource> = (0..SOURCES)
                .map(|_| {
                    let mut s = StageSource::new(SR, FRAMES);
                    s.set_room(room);
                    s
                })
                .collect();
            let params: Vec<StageParams> = (0..SOURCES)
                .map(|i| StageParams {
                    x: 10.0 + (i % 8) as f32 * 5.0,
                    y: 4.0 + (i / 8) as f32 * 5.0,
                    size: if i % 2 == 0 { 0.0 } else { 6.0 },
                    ..StageParams::default()
                })
                .collect();
            let (mut bl, mut br) = (vec![0.0f32; FRAMES], vec![0.0f32; FRAMES]);
            let (mut sl, mut sr) = (vec![0.0f32; FRAMES], vec![0.0f32; FRAMES]);
            let mut pass = |sources: &mut Vec<StageSource>, block: usize| {
                for (s, p) in sources.iter_mut().zip(&params) {
                    let o = (block % 4) * FRAMES;
                    bl.copy_from_slice(&input[o..o + FRAMES]);
                    br.copy_from_slice(&input[o..o + FRAMES]);
                    s.render(&mut bl, &mut br, &mut sl, &mut sr, p, false, FRAMES);
                }
            };
            for b in 0..50 {
                pass(&mut sources, b);
            }
            let start = std::time::Instant::now();
            for b in 0..BLOCKS {
                pass(&mut sources, b);
            }
            let per_block_us = start.elapsed().as_secs_f64() * 1e6 / BLOCKS as f64;
            if mic == MicSetup::Pan {
                baseline = per_block_us;
            }
            println!(
                "{mic:?}: {per_block_us:.0} us per block of {SOURCES} sources ({:.2}x Pan)",
                per_block_us / baseline
            );
        }
    }
}
