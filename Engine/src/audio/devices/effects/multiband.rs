//! Multiband FX container (spec 016): splits the input into 2–6 bands with Linkwitz-Riley
//! crossovers, runs each band through its own child (a slot chain), and sums the bands back.
//!
//! - There are six fixed **band positions**, low to high. Any 2–6 are *active* (parameter
//!   `10·p + 0`). Band position = child index + 1. Inactive positions and their children are never
//!   processed (D10).
//! - Each band owns its **low edge** (D3). The crossovers are the low edges of every active band
//!   except the lowest, forced into ascending order with a minimum ratio (D6).
//! - Bands are split by [`MultibandSplitter`] over the *active* bands only. All bands carry the
//!   phase compensation of the splitter, so the sum is flat in magnitude.
//! - **Mix** crossfades the splitter's phase-aligned dry with the summed bands, so a Mix below 100 %
//!   doesn't comb-filter.
//! - Band gain, mute and solo are device parameters (D11). Mute and solo are folded into a smoothed
//!   per-band level. A muted band still runs its children, so compressor state and tails don't
//!   jump on unmute.
//! - When the active set changes the output fades out over 5 ms, the splitter switches topology and
//!   resets its filter state, and the output fades back in (D13). A block is split at those points.
//!   Nothing allocates.
//!
//! Cost with no children: only the splitter, about 35 biquads per sample and channel at six bands
//! (the LR4 stages are shared). Children (chains) sleep on their own, so this container has no sleep
//! state (ADR 0008).

use crate::audio::devices::container::DeviceContainer;
use crate::audio::devices::container::{
    copy_interleaved, insert_into_vec, move_in_vec, remove_from_vec,
};
use crate::audio::devices::param_table::{
    flatten, linear, log, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
};
use crate::audio::dsp::crossover::{MultibandSplitter, MAX_BANDS};
use crate::audio::dsp::gain::db_to_gain;
use crate::audio::dsp::smoothing::SmoothedParam;
use tracing::warn;

// === Parameters ===

pub const MIX: ParamId = 0;
pub const OUTPUT: ParamId = 1;

/// Number of band positions (and child slot chains).
pub const BAND_COUNT: usize = MAX_BANDS;

/// `Active` parameter of band position `p` (1..=6).
#[cfg(test)]
pub const fn band_active_id(p: usize) -> ParamId {
    (p * 10) as ParamId
}
/// `Low Edge` parameter of band position `p` (2..=6).
#[cfg(test)]
pub const fn band_edge_id(p: usize) -> ParamId {
    (p * 10 + 1) as ParamId
}
/// `Gain` parameter of band position `p`.
#[cfg(test)]
pub const fn band_gain_id(p: usize) -> ParamId {
    (p * 10 + 2) as ParamId
}
/// `Mute` parameter of band position `p`.
#[cfg(test)]
pub const fn band_mute_id(p: usize) -> ParamId {
    (p * 10 + 3) as ParamId
}
/// `Solo` parameter of band position `p`.
#[cfg(test)]
pub const fn band_solo_id(p: usize) -> ParamId {
    (p * 10 + 4) as ParamId
}

/// Default low edges of band positions 2..=6 (Hz).
#[cfg(test)]
const DEFAULT_EDGES: [f32; 5] = [60.0, 200.0, 700.0, 2500.0, 8000.0];

macro_rules! band_params {
    ($p:literal, $active:expr) => {
        [
            spec(
                $p * 10,
                concat!("Band ", $p, " Active"),
                concat!("Band ", $p),
                "",
                Kind::Bool,
                $active,
            )
            .not_automatable(),
            spec(
                $p * 10 + 2,
                concat!("Band ", $p, " Gain"),
                concat!("Band ", $p),
                "dB",
                linear(-24.0, 24.0),
                0.0,
            ),
            spec(
                $p * 10 + 3,
                concat!("Band ", $p, " Mute"),
                concat!("Band ", $p),
                "",
                Kind::Bool,
                0.0,
            ),
            spec(
                $p * 10 + 4,
                concat!("Band ", $p, " Solo"),
                concat!("Band ", $p),
                "",
                Kind::Bool,
                0.0,
            ),
        ]
    };
}

macro_rules! band_edge {
    ($p:literal, $hz:expr) => {
        spec(
            $p * 10 + 1,
            concat!("Band ", $p, " Low Edge"),
            concat!("Band ", $p),
            "Hz",
            log(20.0, 20_000.0),
            $hz,
        )
    };
}

const OUTPUT_MODULE: [ParamSpec; 2] = [
    spec(MIX, "Mix", "Output", "%", linear(0.0, 100.0), 100.0),
    spec(OUTPUT, "Output", "Output", "dB", linear(-24.0, 24.0), 0.0),
];
const BAND1: [ParamSpec; 4] = band_params!(1, 1.0);
const BAND2: [ParamSpec; 5] = {
    let b = band_params!(2, 0.0);
    [b[0], band_edge!(2, 60.0), b[1], b[2], b[3]]
};
const BAND3: [ParamSpec; 5] = {
    let b = band_params!(3, 1.0);
    [b[0], band_edge!(3, 200.0), b[1], b[2], b[3]]
};
const BAND4: [ParamSpec; 5] = {
    let b = band_params!(4, 0.0);
    [b[0], band_edge!(4, 700.0), b[1], b[2], b[3]]
};
const BAND5: [ParamSpec; 5] = {
    let b = band_params!(5, 1.0);
    [b[0], band_edge!(5, 2500.0), b[1], b[2], b[3]]
};
const BAND6: [ParamSpec; 5] = {
    let b = band_params!(6, 0.0);
    [b[0], band_edge!(6, 8000.0), b[1], b[2], b[3]]
};

const PARAM_COUNT: usize = 31;
const SPECS: [ParamSpec; PARAM_COUNT] = flatten(&[
    &OUTPUT_MODULE,
    &BAND1,
    &BAND2,
    &BAND3,
    &BAND4,
    &BAND5,
    &BAND6,
]);
const SLOTS: [u8; 65] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

// === Constants ===

/// Fade out and fade in around a change of the active set (D13).
const TOPOLOGY_FADE_MS: f32 = 5.0;
/// Smoothing of gain, mute/solo, mix and output.
const RAMP_MS: f32 = 10.0;
/// Smallest ratio between neighbouring crossovers (D6).
const MIN_RATIO: f32 = 1.1;
const MAX_EDGE_HZ: f32 = 20_000.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Fade {
    Steady,
    /// Fading out, still on the old topology.
    Out,
    /// Fading in on the new topology.
    In,
}

/// Built-in Multiband FX container.
pub struct MultibandDevice {
    sample_rate: f32,
    children: Vec<Box<dyn AudioDevice>>,
    splitter: MultibandSplitter,
    band_bufs: [Vec<f32>; BAND_COUNT],
    child_out: Vec<f32>,
    sum: Vec<f32>,
    dry: Vec<f32>,
    /// Frames the buffers hold.
    capacity: usize,
    values: ParamValues<PARAM_COUNT>,
    /// Raw low edge per band position (index 0 is unused).
    raw_edges: [f32; BAND_COUNT],
    /// Band gain in linear units per position.
    gain_lin: [f32; BAND_COUNT],
    mute: [bool; BAND_COUNT],
    solo: [bool; BAND_COUNT],
    /// Active positions as set by the parameters (bit `p` = position `p + 1`).
    live_mask: u8,
    /// The mask the splitter currently runs.
    applied_mask: u8,
    /// Active positions (0-based) of `applied_mask`, ascending.
    applied: [u8; BAND_COUNT],
    applied_len: usize,
    edges_dirty: bool,
    levels_dirty: bool,
    warned_few_bands: bool,
    fade: Fade,
    fade_pos: usize,
    fade_len: usize,
    sm_level: [SmoothedParam; BAND_COUNT],
    sm_mix: SmoothedParam,
    sm_out: SmoothedParam,
    enabled: bool,
}

impl MultibandDevice {
    /// Create a Multiband FX with the default active set and no children. Buffers hold
    /// `max_buffer_size` stereo frames.
    pub fn new(sample_rate: f32, max_buffer_size: usize) -> Self {
        let capacity = max_buffer_size.max(1);
        let interleaved = capacity * 2;
        let smoother = |v: f32| SmoothedParam::new(v, sample_rate, RAMP_MS);
        let mut device = Self {
            sample_rate,
            children: Vec::with_capacity(BAND_COUNT),
            splitter: MultibandSplitter::new(sample_rate),
            band_bufs: std::array::from_fn(|_| vec![0.0; interleaved]),
            child_out: vec![0.0; interleaved],
            sum: vec![0.0; interleaved],
            dry: vec![0.0; interleaved],
            capacity,
            values: ParamValues::new(&TABLE),
            raw_edges: [20.0, 60.0, 200.0, 700.0, 2500.0, 8000.0],
            gain_lin: [1.0; BAND_COUNT],
            mute: [false; BAND_COUNT],
            solo: [false; BAND_COUNT],
            live_mask: 0,
            applied_mask: 0,
            applied: [0; BAND_COUNT],
            applied_len: 0,
            edges_dirty: false,
            levels_dirty: false,
            warned_few_bands: false,
            fade: Fade::Steady,
            fade_pos: 0,
            fade_len: fade_frames(sample_rate),
            sm_level: std::array::from_fn(|_| smoother(0.0)),
            sm_mix: smoother(1.0),
            sm_out: smoother(1.0),
            enabled: true,
        };
        for spec in TABLE.specs {
            device.apply(spec.id, spec.default);
        }
        device.apply_topology();
        device.snap_levels();
        device.sm_mix.snap(device.sm_mix.target());
        device.sm_out.snap(device.sm_out.target());
        device
    }

    /// Fold a real parameter value into the derived state.
    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            MIX => self.sm_mix.set_target((real * 0.01).clamp(0.0, 1.0)),
            OUTPUT => self.sm_out.set_target(db_to_gain(real)),
            _ => {
                let p = (id / 10) as usize;
                if !(1..=BAND_COUNT).contains(&p) {
                    return;
                }
                let i = p - 1;
                match id % 10 {
                    0 => {
                        if real >= 0.5 {
                            self.live_mask |= 1 << i;
                        } else {
                            self.live_mask &= !(1 << i);
                        }
                    }
                    1 => {
                        self.raw_edges[i] = real;
                        self.edges_dirty = true;
                    }
                    2 => {
                        self.gain_lin[i] = db_to_gain(real);
                        self.levels_dirty = true;
                    }
                    3 => {
                        self.mute[i] = real >= 0.5;
                        self.levels_dirty = true;
                    }
                    4 => {
                        self.solo[i] = real >= 0.5;
                        self.levels_dirty = true;
                    }
                    _ => {}
                }
            }
        }
    }

    /// Switch the splitter to `live_mask` and reset its state. Called at the bottom of the fade.
    fn apply_topology(&mut self) {
        self.applied_mask = self.live_mask;
        self.applied_len = 0;
        for i in 0..BAND_COUNT {
            if self.applied_mask & (1 << i) != 0 {
                self.applied[self.applied_len] = i as u8;
                self.applied_len += 1;
            }
        }
        if self.applied_len < 2 {
            if !self.warned_few_bands {
                warn!("Multiband FX has fewer than 2 active bands; passing audio through");
                self.warned_few_bands = true;
            }
        } else {
            self.warned_few_bands = false;
            self.splitter.set_topology(self.applied_len - 1);
            self.update_edges();
            self.splitter.snap();
            self.splitter.reset();
        }
        self.levels_dirty = true;
        self.retarget_levels();
        self.snap_levels();
    }

    /// Crossovers (D6) of the applied active bands, handed to the splitter.
    fn update_edges(&mut self) {
        self.edges_dirty = false;
        if self.applied_len < 2 {
            return;
        }
        let ceiling = MAX_EDGE_HZ.min(self.sample_rate * 0.45);
        let mut freqs = [0.0f32; BAND_COUNT - 1];
        let mut prev = 0.0f32;
        for j in 1..self.applied_len {
            let raw = self.raw_edges[self.applied[j] as usize];
            let f = if j == 1 {
                raw
            } else {
                raw.max(prev * MIN_RATIO)
            };
            let f = f.min(ceiling);
            freqs[j - 1] = f;
            prev = f;
        }
        self.splitter.set_targets(&freqs[..self.applied_len - 1]);
    }

    /// Per-band level target: gain, or 0 when inactive, muted or soloed out.
    fn retarget_levels(&mut self) {
        self.levels_dirty = false;
        let active = &self.applied[..self.applied_len];
        let any_solo = active.iter().any(|&p| self.solo[p as usize]);
        for i in 0..BAND_COUNT {
            let is_active = self.applied_mask & (1 << i) != 0 && self.applied_len >= 2;
            let audible = is_active && !self.mute[i] && (!any_solo || self.solo[i]);
            self.sm_level[i].set_target(if audible { self.gain_lin[i] } else { 0.0 });
        }
    }

    fn snap_levels(&mut self) {
        for sm in self.sm_level.iter_mut() {
            sm.snap(sm.target());
        }
    }

    /// Fade gain for frame `i` of the current segment.
    #[inline]
    fn fade_gain(&self, i: usize) -> f32 {
        let t = (self.fade_pos + i) as f32 / self.fade_len as f32;
        match self.fade {
            Fade::Steady => 1.0,
            Fade::Out => 1.0 - t,
            Fade::In => t,
        }
    }

    /// Process `frames` frames (at most `capacity`) on the current topology.
    fn process_segment(&mut self, input: &[f32], output: &mut [f32], frames: usize) {
        let n2 = frames * 2;
        if self.applied_len < 2 {
            for f in 0..frames {
                let g = self.fade_gain(f);
                output[f * 2] = input[f * 2] * g;
                output[f * 2 + 1] = input[f * 2 + 1] * g;
            }
            return;
        }

        self.splitter
            .split(input, &mut self.band_bufs, &mut self.dry[..n2], frames);
        self.sum[..n2].fill(0.0);

        for j in 0..self.applied_len {
            let p = self.applied[j] as usize;
            let band = &self.band_bufs[j][..n2];
            let src: &[f32] = match self.children.get_mut(p) {
                Some(child) => {
                    child.process_block(band, &mut self.child_out[..n2], frames);
                    &self.child_out[..n2]
                }
                None => band,
            };
            let level = &mut self.sm_level[p];
            if level.is_settled() {
                let g = level.current();
                if g != 0.0 {
                    for (s, x) in self.sum[..n2].iter_mut().zip(src) {
                        *s += x * g;
                    }
                }
            } else {
                for f in 0..frames {
                    let g = level.next();
                    self.sum[f * 2] += src[f * 2] * g;
                    self.sum[f * 2 + 1] += src[f * 2 + 1] * g;
                }
            }
        }

        for f in 0..frames {
            let mix = self.sm_mix.next();
            let gain = self.sm_out.next() * self.fade_gain(f);
            for ch in 0..2 {
                let i = f * 2 + ch;
                output[i] = (self.dry[i] * (1.0 - mix) + self.sum[i] * mix) * gain;
            }
        }
    }
}

fn fade_frames(sample_rate: f32) -> usize {
    ((TOPOLOGY_FADE_MS * 0.001 * sample_rate).round() as usize).max(1)
}

impl DeviceContainer for MultibandDevice {
    fn child_count(&self) -> usize {
        self.children.len()
    }

    fn child(&self, index: usize) -> Option<&dyn AudioDevice> {
        self.children.get(index).map(|c| c.as_ref())
    }

    fn child_mut(&mut self, index: usize) -> Option<&mut dyn AudioDevice> {
        self.children
            .get_mut(index)
            .map(|c| c.as_mut() as &mut dyn AudioDevice)
    }

    fn insert_child(&mut self, index: usize, device: Box<dyn AudioDevice>) {
        if self.children.len() >= BAND_COUNT {
            warn!("Multiband FX has {BAND_COUNT} band slots; dropping an extra child");
            return;
        }
        insert_into_vec(&mut self.children, index, device);
    }

    fn remove_child(&mut self, index: usize) -> Option<Box<dyn AudioDevice>> {
        remove_from_vec(&mut self.children, index)
    }

    fn move_child(&mut self, from: usize, to: usize) {
        move_in_vec(&mut self.children, from, to);
    }
}

impl AudioDevice for MultibandDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.enabled {
            copy_interleaved(inputs, outputs, sample_count);
            return;
        }
        let frames = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);

        let mut done = 0;
        while done < frames {
            if self.fade == Fade::Steady && self.live_mask != self.applied_mask {
                self.fade = Fade::Out;
                self.fade_pos = 0;
            }
            if self.edges_dirty {
                self.update_edges();
            }
            if self.levels_dirty {
                self.retarget_levels();
            }

            let ramp_left = match self.fade {
                Fade::Steady => usize::MAX,
                _ => self.fade_len - self.fade_pos,
            };
            let seg = (frames - done).min(ramp_left).min(self.capacity);
            self.process_segment(
                &inputs[done * 2..(done + seg) * 2],
                &mut outputs[done * 2..(done + seg) * 2],
                seg,
            );

            if self.fade != Fade::Steady {
                self.fade_pos += seg;
                if self.fade_pos >= self.fade_len {
                    self.fade_pos = 0;
                    if self.fade == Fade::Out {
                        self.apply_topology();
                        self.fade = Fade::In;
                    } else {
                        self.fade = Fade::Steady;
                    }
                }
            }
            done += seg;
        }
    }

    fn choke(&mut self, frame_offset: usize) {
        for child in &mut self.children {
            child.choke(frame_offset);
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        if let Some((_, real)) = self.values.set(param_id, value) {
            self.apply(param_id, real);
        }
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        if let Some((_, real)) = self.values.set_offset(param_id, offset) {
            self.apply(param_id, real);
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.values.get(param_id)
    }

    fn device_id(&self) -> &str {
        "sonara.builtin.multiband"
    }

    fn device_name(&self) -> &str {
        "Multiband FX"
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
        self.splitter.reset();
        for child in &mut self.children {
            child.reset();
        }
        for buf in &mut self.band_bufs {
            buf.fill(0.0);
        }
        self.child_out.fill(0.0);
        self.sum.fill(0.0);
        self.dry.fill(0.0);
        self.snap_levels();
        self.sm_mix.snap(self.sm_mix.target());
        self.sm_out.snap(self.sm_out.target());
    }

    fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        for child in &mut self.children {
            child.prepare(sample_rate, max_frames);
        }
        if max_frames > self.capacity {
            self.capacity = max_frames;
            let interleaved = max_frames * 2;
            for buf in &mut self.band_bufs {
                buf.resize(interleaved, 0.0);
            }
            self.child_out.resize(interleaved, 0.0);
            self.sum.resize(interleaved, 0.0);
            self.dry.resize(interleaved, 0.0);
        }
        if sample_rate != self.sample_rate {
            self.sample_rate = sample_rate;
            self.splitter = MultibandSplitter::new(sample_rate);
            self.fade_len = fade_frames(sample_rate);
            for sm in self
                .sm_level
                .iter_mut()
                .chain([&mut self.sm_mix, &mut self.sm_out])
            {
                sm.set_ramp(sample_rate, RAMP_MS);
            }
            self.apply_topology();
            self.fade = Fade::Steady;
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

    fn mark_activity(&mut self) {
        for child in &mut self.children {
            child.mark_activity();
        }
    }

    fn as_container(&self) -> Option<&dyn DeviceContainer> {
        Some(self)
    }

    fn as_container_mut(&mut self) -> Option<&mut dyn DeviceContainer> {
        Some(self)
    }

    fn is_container(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{rms, sine, stereo, white_noise};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 256;

    /// Multiplies its input; counts the blocks it processed.
    struct TestGain {
        gain: f32,
        calls: Arc<AtomicUsize>,
    }

    impl TestGain {
        fn boxed(gain: f32) -> (Box<dyn AudioDevice>, Arc<AtomicUsize>) {
            let calls = Arc::new(AtomicUsize::new(0));
            let dev = Box::new(Self {
                gain,
                calls: calls.clone(),
            });
            (dev, calls)
        }
    }

    impl AudioDevice for TestGain {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            self.calls.fetch_add(1, Ordering::Relaxed);
            let n = (sample_count * 2).min(inputs.len()).min(outputs.len());
            for i in 0..n {
                outputs[i] = inputs[i] * self.gain;
            }
        }
        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.gain"
        }
        fn device_name(&self) -> &str {
            "Gain"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Effect
        }
        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }
        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }
        fn reset(&mut self) {}
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    fn device() -> MultibandDevice {
        MultibandDevice::new(SR, 4096)
    }

    /// Fill band slots `0..count` with unity children, then put `last` in slot `count`.
    fn with_children(dev: &mut MultibandDevice, count: usize, last: Box<dyn AudioDevice>) {
        for i in 0..count {
            let (child, _) = TestGain::boxed(1.0);
            dev.insert_child(i, child);
        }
        dev.insert_child(count, last);
    }

    fn set_real(dev: &mut MultibandDevice, id: ParamId, real: f32) {
        let norm = TABLE.spec(id).unwrap().to_norm(real);
        dev.set_parameter(id, norm);
    }

    fn set_active(dev: &mut MultibandDevice, positions: &[usize]) {
        for p in 1..=BAND_COUNT {
            let on = positions.contains(&p);
            set_real(dev, band_active_id(p), if on { 1.0 } else { 0.0 });
        }
    }

    fn run(dev: &mut MultibandDevice, input: &[f32], block: usize) -> Vec<f32> {
        let mut out = vec![0.0f32; input.len()];
        for (i, o) in input.chunks(block * 2).zip(out.chunks_mut(block * 2)) {
            dev.process_block(i, o, i.len() / 2);
        }
        out
    }

    /// Gain in dB of a sine through the device, measured after it settled.
    fn tone_db(dev: &mut MultibandDevice, freq: f32) -> f32 {
        let input = stereo(&sine(freq, SR, 24_000, 0.5));
        let out = run(dev, &input, BLOCK);
        let half = input.len() / 2;
        20.0 * (rms(&out[half..]) / rms(&input[half..])).max(1e-9).log10()
    }

    /// Run the device on silence so a topology change has finished.
    fn flush(dev: &mut MultibandDevice) {
        let silence = vec![0.0f32; 8192];
        run(dev, &silence, BLOCK);
    }

    #[test]
    fn param_table_matches_spec() {
        assert_eq!(TABLE.len(), PARAM_COUNT);
        let dev = device();
        assert_eq!(dev.live_mask, 0b010101);
        assert!(TABLE.slot(11).is_none());
        let active = TABLE.spec(band_active_id(1)).unwrap();
        assert!(!active.automatable);
        for p in 2..=BAND_COUNT {
            let edge = TABLE.spec(band_edge_id(p)).unwrap();
            assert!((edge.default - DEFAULT_EDGES[p - 2]).abs() < 1e-3);
        }
        assert_eq!(dev.parameters().len(), PARAM_COUNT);
    }

    #[test]
    fn defaults_are_flat() {
        let mut dev = device();
        for freq in [40.0, 100.0, 200.0, 500.0, 1000.0, 2500.0, 5000.0, 10_000.0] {
            let db = tone_db(&mut dev, freq);
            assert!(db.abs() < 0.1, "{freq} Hz: {db} dB");
        }
    }

    #[test]
    fn child_on_band_three_removes_only_its_range() {
        let mut dev = device();
        with_children(&mut dev, 2, TestGain::boxed(0.0).0);
        assert!(tone_db(&mut dev, 1000.0) < -25.0);
        assert!(tone_db(&mut dev, 50.0).abs() < 0.5);
        assert!(tone_db(&mut dev, 8000.0).abs() < 0.5);
    }

    #[test]
    fn merged_bands_follow_the_active_set() {
        let mut dev = device();
        set_active(&mut dev, &[1, 3, 6]);
        flush(&mut dev);
        with_children(&mut dev, 2, TestGain::boxed(0.0).0);
        // Band 3 now covers 200 Hz to 8 kHz (bands 4 and 5 are merged into it).
        assert!(tone_db(&mut dev, 1000.0) < -25.0);
        assert!(tone_db(&mut dev, 3000.0) < -25.0);
        assert!(tone_db(&mut dev, 16_000.0).abs() < 0.5);
        assert!(tone_db(&mut dev, 50.0).abs() < 0.5);

        let mut dev = device();
        set_active(&mut dev, &[1, 3, 6]);
        flush(&mut dev);
        with_children(&mut dev, 5, TestGain::boxed(0.0).0);
        assert!(tone_db(&mut dev, 16_000.0) < -25.0);
        assert!(tone_db(&mut dev, 3000.0).abs() < 0.5);
    }

    #[test]
    fn mute_and_solo() {
        let mut dev = device();
        set_real(&mut dev, band_mute_id(1), 1.0);
        assert!(tone_db(&mut dev, 40.0) < -25.0);
        assert!(tone_db(&mut dev, 1000.0).abs() < 0.5);
        set_real(&mut dev, band_mute_id(1), 0.0);

        set_real(&mut dev, band_solo_id(3), 1.0);
        assert!(tone_db(&mut dev, 1000.0).abs() < 0.5);
        assert!(tone_db(&mut dev, 40.0) < -25.0);
        assert!(tone_db(&mut dev, 8000.0) < -25.0);
        set_real(&mut dev, band_solo_id(3), 0.0);

        // A solo on an inactive band does nothing.
        set_real(&mut dev, band_solo_id(2), 1.0);
        assert!(tone_db(&mut dev, 40.0).abs() < 0.5);
    }

    #[test]
    fn muted_band_still_processes_its_child() {
        let mut dev = device();
        let (child, calls) = TestGain::boxed(1.0);
        dev.insert_child(0, child);
        set_real(&mut dev, band_mute_id(1), 1.0);
        run(&mut dev, &vec![0.1; 512], BLOCK);
        assert!(calls.load(Ordering::Relaxed) > 0);
    }

    #[test]
    fn inactive_band_child_is_never_called() {
        let mut dev = device();
        let (c1, calls1) = TestGain::boxed(1.0);
        let (c2, calls2) = TestGain::boxed(1.0);
        dev.insert_child(0, c1);
        dev.insert_child(1, c2);
        run(&mut dev, &vec![0.1; 2048], BLOCK);
        assert!(calls1.load(Ordering::Relaxed) > 0);
        assert_eq!(calls2.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn out_of_order_edges_are_split_ascending() {
        let mut dev = device();
        set_real(&mut dev, band_edge_id(3), 3000.0);
        set_real(&mut dev, band_edge_id(5), 500.0);
        with_children(&mut dev, 4, TestGain::boxed(0.0).0);
        // Band 5 starts at 3300 Hz (3000 x 1.1), not 500 Hz.
        assert!(tone_db(&mut dev, 1000.0).abs() < 0.5);
        let db = tone_db(&mut dev, 8000.0);
        assert!(db < -25.0, "{db}");
    }

    #[test]
    fn toggling_a_band_does_not_jump() {
        let mut dev = device();
        let input = stereo(&sine(100.0, SR, 48_000, 0.5));
        let mut out = Vec::new();
        for (i, chunk) in input.chunks(BLOCK * 2).enumerate() {
            if i == 100 {
                set_real(&mut dev, band_active_id(2), 1.0);
            }
            if i == 160 {
                set_real(&mut dev, band_active_id(3), 0.0);
            }
            let mut o = vec![0.0f32; chunk.len()];
            dev.process_block(chunk, &mut o, chunk.len() / 2);
            out.extend(o);
        }
        let max_step = out
            .chunks_exact(2)
            .zip(out.chunks_exact(2).skip(1))
            .map(|(a, b)| (b[0] - a[0]).abs())
            .fold(0.0f32, f32::max);
        assert!(max_step < 0.03, "max step {max_step}");
        assert!(out.iter().all(|x| x.is_finite()));
    }

    #[test]
    fn toggling_mid_block_in_a_long_block_finishes() {
        let mut dev = device();
        set_active(&mut dev, &[1, 2, 4, 5, 6]);
        let input = stereo(&white_noise(4096, 0.3, 1));
        let out = run(&mut dev, &input, 4096);
        assert!(out.iter().all(|x| x.is_finite()));
        assert_eq!(dev.fade, Fade::Steady);
        assert_eq!(dev.applied_len, 5);
    }

    #[test]
    fn seventh_child_is_dropped() {
        let mut dev = device();
        for i in 0..7 {
            let (child, _) = TestGain::boxed(1.0);
            dev.insert_child(i, child);
        }
        assert_eq!(dev.child_count(), BAND_COUNT);
    }

    #[test]
    fn mix_zero_equals_aligned_dry() {
        let mut dev = device();
        set_real(&mut dev, MIX, 0.0);
        let mut reference = MultibandSplitter::new(SR);
        reference.set_topology(2);
        reference.set_targets(&[200.0, 2500.0]);
        reference.snap();

        let input = stereo(&white_noise(8192, 0.3, 7));
        let out = run(&mut dev, &input, BLOCK);

        let mut bands: [Vec<f32>; MAX_BANDS] = std::array::from_fn(|_| vec![0.0; input.len()]);
        let mut dry = vec![0.0f32; input.len()];
        reference.split(&input, &mut bands, &mut dry, input.len() / 2);
        // Skip the 10 ms Mix ramp.
        let from = 1024 * 2;
        for i in from..input.len() {
            assert!((out[i] - dry[i]).abs() < 1e-5, "sample {i}");
        }
    }

    #[test]
    fn fewer_than_two_active_passes_through() {
        let mut dev = device();
        set_active(&mut dev, &[3]);
        flush(&mut dev);
        let input = stereo(&white_noise(2048, 0.3, 3));
        let out = run(&mut dev, &input, BLOCK);
        for i in 0..input.len() {
            assert!((out[i] - input[i]).abs() < 1e-6);
        }
    }

    #[test]
    fn band_gain_and_output_apply() {
        let mut dev = device();
        set_real(&mut dev, band_gain_id(3), 6.0);
        let db = tone_db(&mut dev, 1000.0);
        assert!((db - 6.0).abs() < 0.3, "{db}");
        set_real(&mut dev, band_gain_id(3), 0.0);
        set_real(&mut dev, OUTPUT, -6.0);
        let db = tone_db(&mut dev, 1000.0);
        assert!((db + 6.0).abs() < 0.3, "{db}");
    }

    #[test]
    fn disabled_copies_input() {
        let mut dev = device();
        dev.set_enabled(false);
        let input = stereo(&white_noise(256, 0.3, 5));
        assert_eq!(run(&mut dev, &input, BLOCK), input);
    }
}
