//! Mid/Side Split and L/R Split (spec 043): two audio effects that split the signal into two
//! device slots (spec 040), run each slot's chain, and sum the results.
//!
//! | | Mid/Side Split | L/R Split |
//! |---|---|---|
//! | Slot 0 input | `(M, M)`, `M = (L+R)/2` | `(L, 0)` |
//! | Slot 1 input | `(S, -S)`, `S = (L-R)/2` | `(0, R)` |
//!
//! The output is `level_0 · slot0 + level_1 · slot1`. With empty slots and unity levels the sum
//! is the input (and the device copies it, so it is sample-identical).
//!
//! Gain and Solo per slot fold into a smoothed level. A soloed-out slot keeps running its chain,
//! so tails and compressor state don't jump on unsolo. A slot reporting latency delays the other
//! to match (spec 042 part D), like Multiband.

use super::effect::{pass_through, TailSleep};
use crate::audio::devices::container::DeviceContainer;
use crate::audio::devices::param_table::{
    linear, slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::slots::{DeviceSlots, SlotKind, SlotSpec};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue,
};
use crate::audio::dsp::block_delay::AlignDelay;
use crate::audio::dsp::gain::db_to_gain;
use crate::audio::dsp::smoothing::SmoothedParam;
use crate::audio::stream::MAX_BLOCK_FRAMES;

// === Parameters ===

pub const GAIN_A: ParamId = 0;
pub const SOLO_A: ParamId = 1;
pub const GAIN_B: ParamId = 2;
pub const SOLO_B: ParamId = 3;

const PARAM_COUNT: usize = 4;
/// Bottom of the Gain range; this value and below is silence (as Utility).
const GAIN_FLOOR_DB: f32 = -60.0;
const RAMP_MS: f32 = 10.0;

static MS_SLOTS: [SlotSpec; 2] = [
    SlotSpec {
        key: "mid",
        name: "Mid",
        kind: SlotKind::Audio,
    },
    SlotSpec {
        key: "side",
        name: "Side",
        kind: SlotKind::Audio,
    },
];

static LR_SLOTS: [SlotSpec; 2] = [
    SlotSpec {
        key: "left",
        name: "Left",
        kind: SlotKind::Audio,
    },
    SlotSpec {
        key: "right",
        name: "Right",
        kind: SlotKind::Audio,
    },
];

const MS_SPECS: [ParamSpec; PARAM_COUNT] = [
    spec(
        GAIN_A,
        "Mid Gain",
        "Mid",
        "dB",
        linear(GAIN_FLOOR_DB, 24.0),
        0.0,
    ),
    spec(SOLO_A, "Mid Solo", "Mid", "", Kind::Bool, 0.0),
    spec(
        GAIN_B,
        "Side Gain",
        "Side",
        "dB",
        linear(GAIN_FLOOR_DB, 24.0),
        0.0,
    ),
    spec(SOLO_B, "Side Solo", "Side", "", Kind::Bool, 0.0),
];
const LR_SPECS: [ParamSpec; PARAM_COUNT] = [
    spec(
        GAIN_A,
        "Left Gain",
        "Left",
        "dB",
        linear(GAIN_FLOOR_DB, 24.0),
        0.0,
    ),
    spec(SOLO_A, "Left Solo", "Left", "", Kind::Bool, 0.0),
    spec(
        GAIN_B,
        "Right Gain",
        "Right",
        "dB",
        linear(GAIN_FLOOR_DB, 24.0),
        0.0,
    ),
    spec(SOLO_B, "Right Solo", "Right", "", Kind::Bool, 0.0),
];
const MS_ID_SLOTS: [u8; PARAM_COUNT] = slot_table(&MS_SPECS);
const LR_ID_SLOTS: [u8; PARAM_COUNT] = slot_table(&LR_SPECS);
static MS_TABLE: ParamTable = ParamTable::new(&MS_SPECS, &MS_ID_SLOTS);
static LR_TABLE: ParamTable = ParamTable::new(&LR_SPECS, &LR_ID_SLOTS);

fn gain_from_db(db: f32) -> f32 {
    if db <= GAIN_FLOOR_DB {
        0.0
    } else {
        db_to_gain(db)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SplitMode {
    MidSide,
    LeftRight,
}

impl SplitMode {
    /// The two slot inputs for one input frame.
    #[inline]
    fn split(self, l: f32, r: f32) -> ([f32; 2], [f32; 2]) {
        match self {
            SplitMode::MidSide => {
                let m = (l + r) * 0.5;
                let s = (l - r) * 0.5;
                ([m, m], [s, -s])
            }
            SplitMode::LeftRight => ([l, 0.0], [0.0, r]),
        }
    }
}

/// Built-in Mid/Side Split and L/R Split.
pub struct SplitDevice {
    mode: SplitMode,
    table: &'static ParamTable,
    slot_specs: &'static [SlotSpec],
    values: ParamValues<PARAM_COUNT>,
    slots: DeviceSlots,
    /// Slot inputs and chain outputs, `capacity` stereo frames each.
    buf_a: Vec<f32>,
    buf_b: Vec<f32>,
    out_a: Vec<f32>,
    out_b: Vec<f32>,
    /// Whole-block output while an async device sits in a slot (`begin_block`/`finish_block`).
    whole_buf: Vec<f32>,
    whole_pending: usize,
    capacity: usize,
    gain_lin: [f32; 2],
    solo: [bool; 2],
    sm_level: [SmoothedParam; 2],
    levels_dirty: bool,
    /// Slot output delays: `latency − own`.
    align: [AlignDelay; 2],
    /// The input delayed by the latency, for the paths that skip the chains. Fed every block.
    thru: AlignDelay,
    sleep: TailSleep,
    is_enabled: bool,
    is_active: bool,
}

impl SplitDevice {
    pub fn mid_side(sample_rate: f32, max_frames: usize) -> Self {
        Self::new(SplitMode::MidSide, sample_rate, max_frames)
    }

    pub fn left_right(sample_rate: f32, max_frames: usize) -> Self {
        Self::new(SplitMode::LeftRight, sample_rate, max_frames)
    }

    fn new(mode: SplitMode, sample_rate: f32, max_frames: usize) -> Self {
        let capacity = max_frames.max(1);
        let (table, slot_specs): (&'static ParamTable, &'static [SlotSpec]) = match mode {
            SplitMode::MidSide => (&MS_TABLE, &MS_SLOTS),
            SplitMode::LeftRight => (&LR_TABLE, &LR_SLOTS),
        };
        let n2 = capacity * 2;
        let mut device = Self {
            mode,
            table,
            slot_specs,
            values: ParamValues::new(table),
            slots: DeviceSlots::new(slot_specs, capacity),
            buf_a: vec![0.0; n2],
            buf_b: vec![0.0; n2],
            out_a: vec![0.0; n2],
            out_b: vec![0.0; n2],
            whole_buf: vec![0.0; n2],
            whole_pending: 0,
            capacity,
            gain_lin: [1.0; 2],
            solo: [false; 2],
            sm_level: std::array::from_fn(|_| SmoothedParam::new(1.0, sample_rate, RAMP_MS)),
            levels_dirty: false,
            align: std::array::from_fn(|_| AlignDelay::default()),
            thru: AlignDelay::default(),
            sleep: TailSleep::new(sample_rate),
            is_enabled: true,
            is_active: true,
        };
        for spec in table.specs {
            device.apply(spec.id, spec.default);
        }
        device.retarget_levels();
        device.snap_levels();
        device
    }

    fn apply(&mut self, id: ParamId, real: f32) {
        match id {
            GAIN_A => self.gain_lin[0] = gain_from_db(real),
            GAIN_B => self.gain_lin[1] = gain_from_db(real),
            SOLO_A => self.solo[0] = real >= 0.5,
            SOLO_B => self.solo[1] = real >= 0.5,
            _ => return,
        }
        self.levels_dirty = true;
    }

    /// Per-slot level target: its gain, or 0 when another slot is soloed and this one isn't.
    fn retarget_levels(&mut self) {
        self.levels_dirty = false;
        let any_solo = self.solo[0] || self.solo[1];
        for i in 0..2 {
            let audible = !any_solo || self.solo[i];
            self.sm_level[i].set_target(if audible { self.gain_lin[i] } else { 0.0 });
        }
    }

    fn snap_levels(&mut self) {
        for sm in self.sm_level.iter_mut() {
            sm.snap(sm.target());
        }
    }

    fn levels_are_unity(&self) -> bool {
        self.sm_level
            .iter()
            .all(|sm| sm.is_settled() && sm.current() == 1.0)
    }

    /// Process `frames` frames (at most `capacity`).
    fn render(&mut self, input: &[f32], output: &mut [f32], frames: usize) {
        if self.levels_dirty {
            self.retarget_levels();
        }
        let n2 = frames * 2;
        self.thru.write(input, frames);
        let live = [self.slots.is_live(0), self.slots.is_live(1)];

        if !live[0] && !live[1] {
            // Plain path: no chain calls. The source is the input, delayed like the live path.
            let src: &[f32] = if self.thru.frames() > 0 {
                self.thru.read(&mut self.out_a[..n2], frames);
                &self.out_a[..n2]
            } else {
                &input[..n2]
            };
            if self.levels_are_unity() {
                output[..n2].copy_from_slice(src);
                return;
            }
            for f in 0..frames {
                let (a, b) = self.mode.split(src[f * 2], src[f * 2 + 1]);
                let l0 = self.sm_level[0].next();
                let l1 = self.sm_level[1].next();
                output[f * 2] = l0 * a[0] + l1 * b[0];
                output[f * 2 + 1] = l0 * a[1] + l1 * b[1];
            }
            return;
        }

        for f in 0..frames {
            let (a, b) = self.mode.split(input[f * 2], input[f * 2 + 1]);
            self.buf_a[f * 2] = a[0];
            self.buf_a[f * 2 + 1] = a[1];
            self.buf_b[f * 2] = b[0];
            self.buf_b[f * 2 + 1] = b[1];
        }
        for (i, (src, dst)) in [
            (&self.buf_a, &mut self.out_a),
            (&self.buf_b, &mut self.out_b),
        ]
        .into_iter()
        .enumerate()
        {
            let dst = &mut dst[..n2];
            match self.slots.chain_mut(i).filter(|_| live[i]) {
                Some(chain) => chain.process_block(&src[..n2], dst, frames),
                None => dst.copy_from_slice(&src[..n2]),
            }
            self.align[i].apply(dst, frames);
        }
        for f in 0..frames {
            let l0 = self.sm_level[0].next();
            let l1 = self.sm_level[1].next();
            output[f * 2] = l0 * self.out_a[f * 2] + l1 * self.out_b[f * 2];
            output[f * 2 + 1] = l0 * self.out_a[f * 2 + 1] + l1 * self.out_b[f * 2 + 1];
        }
    }

    /// True when a device in slot `index` is still awake (a tail that may be ringing).
    fn slot_awake(&self, index: usize) -> bool {
        fn awake(device: &dyn AudioDevice) -> bool {
            if let Some(container) = device.as_container() {
                return (0..container.child_count()).any(|i| container.child(i).is_some_and(awake));
            }
            device.is_enabled() && !device.is_sleeping()
        }
        self.slots.chain(index).is_some_and(awake)
    }
}

impl AudioDevice for SplitDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        if !self.is_enabled || !self.is_active {
            if self.thru.frames() > 0 {
                self.thru.process(inputs, outputs, sample_count);
            } else {
                pass_through(inputs, outputs, sample_count);
            }
            self.sleep.on_block(sample_count);
            return;
        }
        let frames = sample_count.min(inputs.len() / 2).min(outputs.len() / 2);
        let mut done = 0;
        while done < frames {
            let seg = (frames - done).min(self.capacity);
            self.render(
                &inputs[done * 2..(done + seg) * 2],
                &mut outputs[done * 2..(done + seg) * 2],
                seg,
            );
            done += seg;
        }
        self.sleep.on_block(frames);
    }

    /// With an async device (a plugin) in a slot the wrapper must not split the block: it is
    /// rendered here, synchronously, and `finish_block` hands it out.
    fn begin_block(&mut self, inputs: &[f32], sample_count: usize) -> bool {
        if !self.has_async_blocks() {
            return false;
        }
        let frames = sample_count.min(inputs.len() / 2);
        if frames * 2 > self.whole_buf.len() {
            return false;
        }
        let mut out = std::mem::take(&mut self.whole_buf);
        self.process_block(inputs, &mut out[..frames * 2], frames);
        self.whole_buf = out;
        self.whole_pending = frames;
        true
    }

    fn finish_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let frames = std::mem::take(&mut self.whole_pending);
        if frames == 0 {
            pass_through(inputs, outputs, sample_count);
            return;
        }
        let n = (frames * 2).min(outputs.len());
        outputs[..n].copy_from_slice(&self.whole_buf[..n]);
    }

    fn has_async_blocks(&self) -> bool {
        (0..2).any(|i| self.slots.is_live(i) && self.slots.has_async(i))
    }

    /// The slower of the two live slot chains; the other slot is delayed to match.
    fn latency_frames(&self) -> u32 {
        (0..2)
            .filter(|&i| self.slots.is_live(i))
            .filter_map(|i| self.slots.chain(i))
            .map(|chain| chain.latency_frames())
            .max()
            .unwrap_or(0)
    }

    fn update_latency(&mut self, sample_rate: f32) -> u32 {
        for i in 0..2 {
            if let Some(chain) = self.slots.chain_mut(i) {
                chain.update_latency(sample_rate);
            }
        }
        let latency = self.latency_frames();
        for i in 0..2 {
            let own = if self.slots.is_live(i) {
                self.slots
                    .chain(i)
                    .map_or(0, |c| c.latency_frames().min(latency))
            } else {
                0
            };
            self.align[i].set((latency - own) as usize, MAX_BLOCK_FRAMES);
        }
        self.thru.set(latency as usize, MAX_BLOCK_FRAMES);
        latency
    }

    fn choke(&mut self, frame_offset: usize) {
        for i in 0..2 {
            if let Some(chain) = self.slots.chain_mut(i) {
                chain.choke(frame_offset);
            }
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.sleep.wake();
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
        match self.mode {
            SplitMode::MidSide => "sonara.builtin.ms_split",
            SplitMode::LeftRight => "sonara.builtin.lr_split",
        }
    }

    fn device_name(&self) -> &str {
        match self.mode {
            SplitMode::MidSide => "Mid/Side Split",
            SplitMode::LeftRight => "L/R Split",
        }
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Effect
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        self.table.infos()
    }

    fn reset(&mut self) {
        self.slots.reset();
        for buf in [
            &mut self.buf_a,
            &mut self.buf_b,
            &mut self.out_a,
            &mut self.out_b,
        ] {
            buf.fill(0.0);
        }
        // Dropping the history by re-setting the same value would keep it; rebuild instead.
        for align in self.align.iter_mut().chain([&mut self.thru]) {
            let frames = align.frames();
            align.set(0, MAX_BLOCK_FRAMES);
            align.set(frames, MAX_BLOCK_FRAMES);
        }
        self.whole_pending = 0;
        self.snap_levels();
        self.sleep.wake();
    }

    fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        if max_frames > self.capacity {
            self.capacity = max_frames;
            let n2 = max_frames * 2;
            for buf in [
                &mut self.buf_a,
                &mut self.buf_b,
                &mut self.out_a,
                &mut self.out_b,
                &mut self.whole_buf,
            ] {
                buf.resize(n2, 0.0);
            }
        }
        self.slots.prepare(sample_rate, max_frames);
        for sm in self.sm_level.iter_mut() {
            sm.set_ramp(sample_rate, RAMP_MS);
        }
        self.sleep.set_sample_rate(sample_rate);
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
        self.is_enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.is_enabled = enabled;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    // === Slots (spec 040) ===

    fn device_slots(&self) -> &'static [SlotSpec] {
        self.slot_specs
    }

    fn as_container(&self) -> Option<&dyn DeviceContainer> {
        Some(&self.slots)
    }

    fn as_container_mut(&mut self) -> Option<&mut dyn DeviceContainer> {
        Some(&mut self.slots)
    }

    fn is_container(&self) -> bool {
        true
    }

    // === Sleep ===

    fn is_sleeping(&self) -> bool {
        self.sleep.is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.sleep.wake();
        for i in 0..2 {
            if let Some(chain) = self.slots.chain_mut(i) {
                chain.mark_activity();
            }
        }
    }

    /// The device has no tail of its own: it sleeps after the usual quiet time, and only once
    /// every device in both slots has gone to sleep too (a delay or reverb still ringing).
    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        let was_sleeping = self.sleep.is_sleeping();
        self.sleep.update(has_audio_activity);
        if self.sleep.is_sleeping() && (self.slot_awake(0) || self.slot_awake(1)) {
            self.sleep.wake();
        }
        was_sleeping != self.sleep.is_sleeping()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::dsp::test_util::{left, render, right, rms, stereo, white_noise};
    use crate::audio::mixing::test_support::LatencyDevice;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    const SR: f32 = 48_000.0;
    const BLOCK: usize = 256;

    /// Multiplies its input per channel; counts blocks; optionally async/awake.
    struct TestFx {
        gain: [f32; 2],
        calls: Arc<AtomicUsize>,
        async_blocks: bool,
        sleeping: bool,
    }

    impl TestFx {
        fn new(gain: [f32; 2]) -> Self {
            Self {
                gain,
                calls: Arc::new(AtomicUsize::new(0)),
                async_blocks: false,
                sleeping: false,
            }
        }
    }

    impl AudioDevice for TestFx {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], n: usize) {
            self.calls.fetch_add(1, Ordering::Relaxed);
            for i in 0..n * 2 {
                outputs[i] = inputs[i] * self.gain[i % 2];
            }
        }
        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.fx"
        }
        fn device_name(&self) -> &str {
            "Fx"
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
        fn has_async_blocks(&self) -> bool {
            self.async_blocks
        }
        fn is_sleeping(&self) -> bool {
            self.sleeping
        }
    }

    fn make(mode: SplitMode) -> SplitDevice {
        let mut d = SplitDevice::new(mode, SR, 4096);
        d.prepare(SR, 4096);
        d
    }

    fn put(d: &mut SplitDevice, slot: usize, device: Box<dyn AudioDevice>) {
        d.slots.children_mut(slot).unwrap().push(device);
    }

    fn set_real(d: &mut SplitDevice, id: ParamId, real: f32) {
        let norm = d.table.spec(id).unwrap().to_norm(real);
        d.set_parameter(id, norm);
    }

    /// Run enough silence for the level smoothers to settle.
    fn settle(d: &mut SplitDevice) {
        let silence = vec![0.0f32; 4800 * 2];
        render(d, &silence, &[BLOCK]);
    }

    fn lr_noise(frames: usize) -> Vec<f32> {
        let l = white_noise(frames, 0.5, 1);
        let r = white_noise(frames, 0.5, 2);
        crate::audio::dsp::test_util::interleave(&l, &r)
    }

    /// Decode an interleaved L/R signal into (mid, side).
    fn decode(x: &[f32]) -> (Vec<f32>, Vec<f32>) {
        let (l, r) = (left(x), right(x));
        let m = l.iter().zip(&r).map(|(l, r)| (l + r) * 0.5).collect();
        let s = l.iter().zip(&r).map(|(l, r)| (l - r) * 0.5).collect();
        (m, s)
    }

    #[test]
    fn slot_keys_names_and_kinds() {
        let ms = make(SplitMode::MidSide);
        let specs = ms.device_slots();
        assert_eq!(specs.len(), 2);
        assert_eq!((specs[0].key, specs[0].name), ("mid", "Mid"));
        assert_eq!((specs[1].key, specs[1].name), ("side", "Side"));
        assert!(specs.iter().all(|s| s.kind == SlotKind::Audio));
        assert_eq!(ms.device_id(), "sonara.builtin.ms_split");
        assert_eq!(ms.device_name(), "Mid/Side Split");

        let lr = make(SplitMode::LeftRight);
        let specs = lr.device_slots();
        assert_eq!((specs[0].key, specs[0].name), ("left", "Left"));
        assert_eq!((specs[1].key, specs[1].name), ("right", "Right"));
        assert!(specs.iter().all(|s| s.kind == SlotKind::Audio));
        assert_eq!(lr.device_id(), "sonara.builtin.lr_split");
        assert_eq!(lr.device_name(), "L/R Split");
        assert_eq!(lr.parameters().len(), 4);
    }

    #[test]
    fn empty_slots_are_sample_identical() {
        for mode in [SplitMode::MidSide, SplitMode::LeftRight] {
            let mut d = make(mode);
            let input = lr_noise(2000);
            assert_eq!(render(&mut d, &input, &[BLOCK, 77]), input);
        }
    }

    #[test]
    fn ms_solo_side_of_mono_is_silent_and_solo_mid_of_antiphase_is_silent() {
        let mut d = make(SplitMode::MidSide);
        set_real(&mut d, SOLO_B, 1.0);
        settle(&mut d);
        let mono = stereo(&white_noise(2000, 0.5, 3));
        assert!(rms(&render(&mut d, &mono, &[BLOCK])) < 1e-6);

        let mut d = make(SplitMode::MidSide);
        set_real(&mut d, SOLO_A, 1.0);
        settle(&mut d);
        let n = white_noise(2000, 0.5, 4);
        let anti: Vec<f32> = n.iter().flat_map(|x| [*x, -*x]).collect();
        assert!(rms(&render(&mut d, &anti, &[BLOCK])) < 1e-6);
    }

    #[test]
    fn lr_solo_left_and_right() {
        let input = lr_noise(2000);
        let mut d = make(SplitMode::LeftRight);
        set_real(&mut d, SOLO_A, 1.0);
        settle(&mut d);
        let out = render(&mut d, &input, &[BLOCK]);
        assert_eq!(left(&out), left(&input));
        assert!(right(&out).iter().all(|x| *x == 0.0));

        let mut d = make(SplitMode::LeftRight);
        set_real(&mut d, SOLO_B, 1.0);
        settle(&mut d);
        let out = render(&mut d, &input, &[BLOCK]);
        assert!(left(&out).iter().all(|x| *x == 0.0));
        assert_eq!(right(&out), right(&input));
    }

    #[test]
    fn mid_gain_scales_only_the_mid_component() {
        let mut d = make(SplitMode::MidSide);
        set_real(&mut d, GAIN_A, -6.0);
        settle(&mut d);
        let input = lr_noise(2000);
        let out = render(&mut d, &input, &[BLOCK]);
        let (mi, si) = decode(&input);
        let (mo, so) = decode(&out);
        let g = db_to_gain(-6.0);
        for i in 0..mi.len() {
            assert!((mo[i] - mi[i] * g).abs() < 1e-5);
            assert!((so[i] - si[i]).abs() < 1e-5);
        }
    }

    #[test]
    fn gain_device_in_side_slot_widens_the_image() {
        let mut d = make(SplitMode::MidSide);
        put(&mut d, 1, Box::new(TestFx::new([2.0, 2.0])));
        let input = lr_noise(2000);
        let out = render(&mut d, &input, &[BLOCK]);
        let (mi, si) = decode(&input);
        let (mo, so) = decode(&out);
        for i in 0..mi.len() {
            assert!((mo[i] - mi[i]).abs() < 1e-5);
            assert!((so[i] - si[i] * 2.0).abs() < 1e-5);
        }
    }

    #[test]
    fn soloed_out_slot_still_runs() {
        let mut d = make(SplitMode::MidSide);
        let fx = TestFx::new([1.0, 1.0]);
        let calls = fx.calls.clone();
        put(&mut d, 1, Box::new(fx));
        set_real(&mut d, SOLO_A, 1.0);
        let input = lr_noise(1024);
        render(&mut d, &input, &[BLOCK]);
        assert_eq!(calls.load(Ordering::Relaxed), 4);
    }

    #[test]
    fn latency_in_one_slot_delays_the_whole_output() {
        const DELAY: usize = 100;
        let mut d = make(SplitMode::LeftRight);
        put(&mut d, 0, Box::new(LatencyDevice::new(DELAY, 1.0)));
        assert_eq!(d.update_latency(SR), DELAY as u32);
        assert_eq!(d.latency_frames(), DELAY as u32);
        let input = lr_noise(2000);
        let out = render(&mut d, &input, &[BLOCK, 100]);
        assert!(out[..DELAY * 2].iter().all(|x| x.abs() < 1e-6));
        for i in DELAY * 2..out.len() {
            assert!((out[i] - input[i - DELAY * 2]).abs() < 1e-6, "sample {i}");
        }
    }

    #[test]
    fn async_device_in_a_slot_matches_the_sync_path() {
        let build = || {
            let mut d = make(SplitMode::MidSide);
            let mut fx = TestFx::new([0.5, 0.5]);
            fx.async_blocks = true;
            put(&mut d, 1, Box::new(fx));
            d
        };
        let input = lr_noise(2048);
        let mut a = build();
        let x = render(&mut a, &input, &[BLOCK]);
        let mut b = build();
        assert!(b.has_async_blocks());
        let mut y = vec![0.0f32; input.len()];
        for start in (0..input.len() / 2).step_by(BLOCK) {
            let i = &input[start * 2..(start + BLOCK) * 2];
            let o = &mut y[start * 2..(start + BLOCK) * 2];
            assert!(b.begin_block(i, BLOCK));
            b.finish_block(i, o, BLOCK);
        }
        assert_eq!(x, y);
        assert!(!make(SplitMode::MidSide).has_async_blocks());
    }

    #[test]
    fn a_tail_in_a_slot_keeps_the_split_awake() {
        let quiet = vec![0.0f32; BLOCK * 2];
        let sleep_time = |awake_fx: bool| {
            let mut out = vec![0.0f32; BLOCK * 2];
            let mut d = make(SplitMode::LeftRight);
            if awake_fx {
                let mut fx = TestFx::new([1.0, 1.0]);
                fx.sleeping = false;
                put(&mut d, 0, Box::new(fx));
            }
            for block in 0..(SR as usize * 10 / BLOCK) {
                d.process_block(&quiet, &mut out, BLOCK);
                d.update_sleep_state(false);
                if d.is_sleeping() {
                    return Some(block);
                }
            }
            None
        };
        assert!(sleep_time(false).is_some());
        assert!(sleep_time(true).is_none());
    }
}
