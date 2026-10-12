//! Device slots (spec 040): fixed, named slot chains built into a device that isn't otherwise
//! a container (PolySynth, Delay, Reverb).
//!
//! The engine owns the chains. A slotted device creates one [`ChainDevice`] per [`SlotSpec`] in
//! its constructor and exposes them as fixed container children (child *i* = slot *i*), so
//! paths, parameter messages and modulator routes address a slot's devices as
//! `{device}/child/{slot}/child/{n}` like in any container. Each device decides where in its
//! signal path a slot runs; this module holds the chains, the scratch buffers and the rules for
//! what a slot accepts.

use super::containers::container::{device_at_path, DeviceContainer, DevicePath};
use super::containers::ChainDevice;
use super::device::{AudioDevice, DeviceCategory, DeviceVariant};
use super::note_fx::host::OUTPUT_CAPACITY;
use super::note_fx::NoteBuffer;

/// Frames per sub-block of a loop slot (Delay FB FX, Reverb Tank FX). No delay line is read
/// within `LOOP_BLOCK + 2` samples of being written while a loop slot is in use.
pub const LOOP_BLOCK: usize = 64;

/// What a slot accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotKind {
    /// Note effects only.
    Note,
    /// Audio effects (no instruments, no note effects).
    Audio,
    /// Audio effects that run inside a feedback loop in sub-blocks: like `Audio`, but without
    /// CLAP and without devices that process asynchronously.
    Loop,
}

impl SlotKind {
    /// The kind string sent to Godot in `/builtin/info`.
    pub fn as_str(&self) -> &'static str {
        match self {
            SlotKind::Note => "note",
            SlotKind::Audio => "audio",
            SlotKind::Loop => "loop",
        }
    }

    /// Ok when `device`, and every device nested inside it, fits this kind. The error names the
    /// offending device.
    pub fn accepts(&self, device: &dyn AudioDevice) -> Result<(), String> {
        let name = device.device_name();
        match self {
            SlotKind::Note => {
                if !device.is_note_effect() && !is_plain_container(device) {
                    return Err(format!("{} is not a note effect", name));
                }
            }
            SlotKind::Audio | SlotKind::Loop => {
                if device.device_category() == DeviceCategory::Instrument {
                    return Err(format!("{} is an instrument", name));
                }
                if device.is_note_effect() {
                    return Err(format!("{} is a note effect", name));
                }
                if *self == SlotKind::Loop {
                    if device.device_variant() == DeviceVariant::Clap {
                        return Err(format!("{} is a plugin that can't run in a loop", name));
                    }
                    if device.has_async_blocks() {
                        return Err(format!("{} processes asynchronously", name));
                    }
                }
            }
        }
        if let Some(container) = device.as_container() {
            for i in 0..container.child_count() {
                if let Some(child) = container.child(i) {
                    self.accepts(child)?;
                }
            }
        }
        Ok(())
    }
}

/// A Chain used as a wrapper is not itself a note effect; a note slot takes it when everything
/// inside passes (checked by the recursion in `accepts`).
fn is_plain_container(device: &dyn AudioDevice) -> bool {
    device.device_id() == "sonara.builtin.chain"
}

/// One device slot: its key (stable, used by Godot), display name and kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SlotSpec {
    pub key: &'static str,
    pub name: &'static str,
    pub kind: SlotKind,
}

/// The slot chains of a slotted device plus the scratch buffers its slot processing needs.
/// Everything is allocated in [`DeviceSlots::new`] and resized only in [`DeviceSlots::prepare`].
pub struct DeviceSlots {
    specs: &'static [SlotSpec],
    chains: Vec<Box<dyn AudioDevice>>,
    /// Stereo interleaved scratch of `max_frames` frames (wet signal, whole-block FX output).
    pub slot_buf: Vec<f32>,
    /// Stereo interleaved loop-slot input of `LOOP_BLOCK` frames.
    pub loop_in: Vec<f32>,
    /// Stereo interleaved loop-slot output of `LOOP_BLOCK` frames.
    pub loop_out: Vec<f32>,
    /// Notes that fall off the end of a Note FX slot.
    pub note_sink: NoteBuffer,
}

impl DeviceSlots {
    pub fn new(specs: &'static [SlotSpec], max_frames: usize) -> Self {
        Self {
            specs,
            chains: specs
                .iter()
                .map(|_| Box::new(ChainDevice::new(max_frames)) as Box<dyn AudioDevice>)
                .collect(),
            slot_buf: vec![0.0; max_frames * 2],
            loop_in: vec![0.0; LOOP_BLOCK * 2],
            loop_out: vec![0.0; LOOP_BLOCK * 2],
            note_sink: NoteBuffer::new(OUTPUT_CAPACITY),
        }
    }

    pub fn specs(&self) -> &'static [SlotSpec] {
        self.specs
    }

    /// Command thread, stream stopped: grow the scratch, and the slot chains' own ping-pong
    /// buffers, for blocks of up to `max_frames`. A chain truncates a block longer than its
    /// buffers, so they must keep up with `slot_buf`.
    pub fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        if self.slot_buf.len() < max_frames * 2 {
            self.slot_buf.resize(max_frames * 2, 0.0);
        }
        for chain in &mut self.chains {
            chain.prepare(sample_rate, max_frames);
        }
    }

    /// Reset every slot chain (and so every device in them) and drop pending sink notes.
    pub fn reset(&mut self) {
        for chain in &mut self.chains {
            chain.reset();
        }
        self.note_sink.clear();
        self.slot_buf.fill(0.0);
        self.loop_in.fill(0.0);
        self.loop_out.fill(0.0);
    }

    /// The slot chain `index` as a device (run it with `process_block`).
    pub fn chain_mut(&mut self, index: usize) -> Option<&mut dyn AudioDevice> {
        self.chains.get_mut(index).map(|c| c.as_mut() as _)
    }

    /// The devices in slot `index`, for the note helpers (`route_note`, `run_note_phase`).
    pub fn children_mut(&mut self, index: usize) -> Option<&mut Vec<Box<dyn AudioDevice>>> {
        self.chains
            .get_mut(index)?
            .as_container_mut()?
            .chain_children_mut()
    }

    /// The devices in note slot `index` together with the note sink, as a split borrow for
    /// `run_note_phase(children, n, Some(sink))` and the sink-taking release helpers.
    pub fn children_and_sink(
        &mut self,
        index: usize,
    ) -> Option<(&mut Vec<Box<dyn AudioDevice>>, &mut NoteBuffer)> {
        let children = self
            .chains
            .get_mut(index)?
            .as_container_mut()?
            .chain_children_mut()?;
        Some((children, &mut self.note_sink))
    }

    /// Number of devices (enabled or not) in slot `index`.
    pub fn len(&self, index: usize) -> usize {
        self.chains
            .get(index)
            .and_then(|c| c.as_container())
            .map_or(0, |c| c.child_count())
    }

    /// True when slot `index` holds at least one enabled device. Bypassed devices don't count,
    /// so a slot with only bypassed devices keeps the device on its plain code path. Not
    /// cached: a child's bypass toggles without its parent being told.
    pub fn is_live(&self, index: usize) -> bool {
        let Some(container) = self.chains.get(index).and_then(|c| c.as_container()) else {
            return false;
        };
        (0..container.child_count()).any(|i| container.child(i).is_some_and(|c| c.is_enabled()))
    }

    /// True when slot `index` holds a device (at any depth) that processes asynchronously.
    pub fn has_async(&self, index: usize) -> bool {
        self.chains
            .get(index)
            .is_some_and(|c| any_async(c.as_ref()))
    }
}

fn any_async(device: &dyn AudioDevice) -> bool {
    if device.has_async_blocks() {
        return true;
    }
    let Some(container) = device.as_container() else {
        return false;
    };
    (0..container.child_count()).any(|i| container.child(i).is_some_and(any_async))
}

impl DeviceContainer for DeviceSlots {
    fn child_count(&self) -> usize {
        self.chains.len()
    }

    fn child(&self, index: usize) -> Option<&dyn AudioDevice> {
        self.chains.get(index).map(|c| c.as_ref())
    }

    fn child_mut(&mut self, index: usize) -> Option<&mut dyn AudioDevice> {
        self.chains.get_mut(index).map(|c| c.as_mut() as _)
    }

    /// Slots are fixed: the device is refused (and dropped) with a warning.
    fn insert_child(&mut self, index: usize, device: Box<dyn AudioDevice>) {
        tracing::warn!(
            "device slots are fixed: refusing to add {} at slot index {}",
            device.device_name(),
            index
        );
    }

    fn remove_child(&mut self, _index: usize) -> Option<Box<dyn AudioDevice>> {
        None
    }

    fn move_child(&mut self, _from: usize, _to: usize) {}
}

/// Check that `device` may go into the list at `parent_path`. Finds the innermost ancestor
/// list that is a slot chain of a slotted device and checks the device (and everything nested
/// in it) against that slot's kind. A direct insert into a slotted device is refused. Lists
/// that aren't inside a slot always pass.
pub fn check_insert(
    devices: &[Box<dyn AudioDevice>],
    parent_path: &DevicePath,
    device: &dyn AudioDevice,
) -> Result<(), String> {
    let mut list = *parent_path;
    while !list.is_empty() {
        let host_path = list.parent();
        if !host_path.is_empty() {
            if let (Some(host), Some(slot)) =
                (device_at_path(devices, &host_path), list.leaf_index())
            {
                let specs = host.device_slots();
                if !specs.is_empty() {
                    let Some(spec) = specs.get(slot) else {
                        return Err(format!("{} has no slot {}", host.device_name(), slot));
                    };
                    return spec.kind.accepts(device).map_err(|why| {
                        format!(
                            "{} slot of {} refuses {}: {}",
                            spec.name,
                            host.device_name(),
                            device.device_name(),
                            why
                        )
                    });
                }
            }
        }
        list = host_path;
    }
    // The parent itself being a slotted device means the insert targets the device, not a slot.
    if !parent_path.is_empty() {
        if let Some(host) = device_at_path(devices, parent_path) {
            if !host.device_slots().is_empty() {
                return Err(format!(
                    "{} has fixed slots: add devices to one of its slots",
                    host.device_name()
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::audio::devices::note_fx::routing::test_devices::{Recorder, Shift};
    use crate::audio::devices::{ParamId, ParamInfo, ParamValue};

    pub static TEST_SLOTS: [SlotSpec; 3] = [
        SlotSpec {
            key: "note_fx",
            name: "Note FX",
            kind: SlotKind::Note,
        },
        SlotSpec {
            key: "fx",
            name: "FX",
            kind: SlotKind::Audio,
        },
        SlotSpec {
            key: "loop_fx",
            name: "Loop FX",
            kind: SlotKind::Loop,
        },
    ];

    /// A slotted device with one slot of each kind.
    pub struct TestSlotted {
        pub slots: DeviceSlots,
    }

    impl TestSlotted {
        pub fn new() -> Self {
            Self {
                slots: DeviceSlots::new(&TEST_SLOTS, 64),
            }
        }
    }

    impl AudioDevice for TestSlotted {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], n: usize) {
            crate::audio::devices::container::copy_interleaved(inputs, outputs, n);
        }
        fn set_parameter(&mut self, _id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.slotted"
        }
        fn device_name(&self) -> &str {
            "Slotted"
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
        fn reset(&mut self) {
            self.slots.reset();
        }
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
        fn device_slots(&self) -> &'static [SlotSpec] {
            &TEST_SLOTS
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
    }

    /// A plain effect (category Effect, built-in).
    pub struct Fx {
        pub variant: DeviceVariant,
        pub async_blocks: bool,
        pub enabled: bool,
    }

    impl Fx {
        pub fn new() -> Self {
            Self {
                variant: DeviceVariant::BuiltIn,
                async_blocks: false,
                enabled: true,
            }
        }
    }

    impl AudioDevice for Fx {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], n: usize) {
            crate::audio::devices::container::copy_interleaved(inputs, outputs, n);
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
            self.variant
        }
        fn has_async_blocks(&self) -> bool {
            self.async_blocks
        }
        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }
        fn reset(&mut self) {}
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

    fn chain_with(devices: Vec<Box<dyn AudioDevice>>) -> Box<dyn AudioDevice> {
        let mut chain = ChainDevice::new(8);
        for (i, d) in devices.into_iter().enumerate() {
            chain.insert_child(i, d);
        }
        Box::new(chain)
    }

    #[test]
    fn kind_accepts() {
        let shift = Shift::new(12);
        let (recorder, _) = Recorder::new(); // an Instrument
        let fx = Fx::new();
        assert!(SlotKind::Note.accepts(&shift).is_ok());
        assert!(SlotKind::Note.accepts(&fx).is_err());
        assert!(SlotKind::Note.accepts(&recorder).is_err());

        assert!(SlotKind::Audio.accepts(&fx).is_ok());
        assert!(SlotKind::Audio.accepts(&recorder).is_err());
        assert!(SlotKind::Audio.accepts(&shift).is_err());

        // A chain of effects passes; one hiding an instrument or note effect doesn't.
        let ok = chain_with(vec![Box::new(Fx::new()), Box::new(Fx::new())]);
        assert!(SlotKind::Audio.accepts(ok.as_ref()).is_ok());
        let (inst, _) = Recorder::new();
        let bad = chain_with(vec![Box::new(Fx::new()), Box::new(inst)]);
        assert!(SlotKind::Audio.accepts(bad.as_ref()).is_err());
        let bad_note = chain_with(vec![Box::new(Shift::new(1)), Box::new(Fx::new())]);
        assert!(SlotKind::Note.accepts(bad_note.as_ref()).is_err());
        let note_chain = chain_with(vec![Box::new(Shift::new(1))]);
        assert!(SlotKind::Note.accepts(note_chain.as_ref()).is_ok());

        // Loop also rejects CLAP and async devices.
        let mut clap = Fx::new();
        clap.variant = DeviceVariant::Clap;
        assert!(SlotKind::Audio.accepts(&clap).is_ok());
        assert!(SlotKind::Loop.accepts(&clap).is_err());
        let mut asy = Fx::new();
        asy.async_blocks = true;
        assert!(SlotKind::Audio.accepts(&asy).is_ok());
        assert!(SlotKind::Loop.accepts(&asy).is_err());
        let nested = chain_with(vec![Box::new(clap)]);
        assert!(SlotKind::Loop.accepts(nested.as_ref()).is_err());

        assert_eq!(SlotKind::Note.as_str(), "note");
        assert_eq!(SlotKind::Audio.as_str(), "audio");
        assert_eq!(SlotKind::Loop.as_str(), "loop");
    }

    #[test]
    fn fixed_children_refuse_edits() {
        let mut slots = DeviceSlots::new(&TEST_SLOTS, 16);
        assert_eq!(slots.child_count(), 3);
        slots.insert_child(0, Box::new(Fx::new()));
        assert_eq!(slots.child_count(), 3);
        assert!(slots.remove_child(0).is_none());
        slots.move_child(0, 1);
        assert_eq!(slots.child_count(), 3);
        assert!(slots.child(0).is_some() && slots.child(3).is_none());
        // The chains stay empty: the refused device was not put anywhere.
        assert!(slots.children_mut(0).unwrap().is_empty());
    }

    #[test]
    fn is_live_ignores_bypassed() {
        let mut slots = DeviceSlots::new(&TEST_SLOTS, 16);
        assert!(!slots.is_live(1));
        let mut bypassed = Fx::new();
        bypassed.enabled = false;
        slots.children_mut(1).unwrap().push(Box::new(bypassed));
        assert!(!slots.is_live(1));
        slots.children_mut(1).unwrap().push(Box::new(Fx::new()));
        assert!(slots.is_live(1));
        assert!(!slots.is_live(0));
        assert!(!slots.is_live(9));
        assert!(!slots.has_async(1));
        let mut asy = Fx::new();
        asy.async_blocks = true;
        slots.children_mut(1).unwrap().push(Box::new(asy));
        assert!(slots.has_async(1));
    }

    #[test]
    fn prepare_grows_slot_chains_with_the_scratch() {
        // A chain truncates blocks longer than its buffers, so prepare must grow them too.
        let mut slots = DeviceSlots::new(&TEST_SLOTS, 16);
        slots.children_mut(1).unwrap().push(Box::new(Fx::new()));
        slots.prepare(48_000.0, 256);
        let input = vec![1.0f32; 256 * 2];
        let mut output = vec![0.0f32; 256 * 2];
        slots
            .chain_mut(1)
            .unwrap()
            .process_block(&input, &mut output, 256);
        assert!(output.iter().all(|s| *s != 0.0), "block was truncated");
    }
}
