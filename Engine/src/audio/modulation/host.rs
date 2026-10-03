//! The `ModulatedDevice` wrapper: the engine's mono evaluation path.
//!
//! A device that carries modulators is a plain device boxed inside a `ModulatedDevice`. The
//! wrapper owns the modulator block, the route matrix and the resolved targets, and it forwards
//! every trait method to the device it wraps (see ADR-0014). It is inserted when a device gets
//! its first modulator ([`wrap_at_path`]) and removed when it loses the last one
//! ([`unwrap_at_path`]), so a device without modulators costs nothing.
//!
//! Evaluation is by control step (`CONTROL_STEP` frames): every modulator is advanced, the
//! routes are summed per target, and each target gets `set_param_mod(offset)` — `offset` next
//! to the base value, never written into it. A builtin inner device is processed in sub-blocks
//! of up to `CONTROL_STEP` frames so its MIDI can be rebased sample-accurately; an asynchronous
//! inner (a CLAP plugin) keeps whole blocks and will get frame-stamped `PARAM_MOD` events
//! instead (spec 018 Phase 5).
//!
//! Routes may target the device itself (`param/{id}`), a device nested inside it
//! (`child/{i.j…}/param/{id}`) or another modulator of the same device
//! (`mod/{mod_id}/param/{id}`, stored but not evaluated until Phase 9).

use super::matrix::ModMatrix;
use super::{ModulatorKind, ModulatorState, MAX_MODULATORS, MAX_ROUTES};
use crate::audio::devices::container::{
    copy_interleaved, device_at_path_mut, insert_device, remove_device,
};
use crate::audio::devices::{AudioDevice, DeviceContainer, DevicePath, ParamId};
use crate::audio::modulation::kinds::LFO_RETRIGGER;
use crate::audio::transport::Transport;
use tracing::warn;

/// Frames between control steps: the mono path updates its offsets this often.
pub const CONTROL_STEP: usize = 64;

/// Notes the wrapper holds between a `send_midi_event` and the block that consumes them.
const MIDI_QUEUE: usize = 256;

/// Smallest offset change worth pushing to a device (below it the parameter ramp would just be
/// restarted for nothing).
const OFFSET_EPSILON: f32 = 1e-7;

/// A queued note, with the frame offset it was sent with.
#[derive(Clone, Copy)]
struct QueuedMidi {
    note: u8,
    velocity: u8,
    is_note_on: bool,
    frame_offset: usize,
}

const NO_MIDI: QueuedMidi = QueuedMidi {
    note: 0,
    velocity: 0,
    is_note_on: false,
    frame_offset: 0,
};

/// A resolved route destination, relative to the owning device.
#[derive(Clone, Copy, PartialEq)]
enum ModTarget {
    /// A parameter of the device itself.
    Own(ParamId),
    /// A parameter of a device nested inside it, by relative path.
    Child(DevicePath, ParamId),
    /// A parameter of another modulator of the same device (Phase 9: stored, not evaluated).
    Modulator(u8, ParamId),
}

impl ModTarget {
    fn param_id(self) -> ParamId {
        match self {
            ModTarget::Own(id) | ModTarget::Child(_, id) | ModTarget::Modulator(_, id) => id,
        }
    }
}

const NO_TARGET: ModTarget = ModTarget::Own(0);

/// What the command thread and the automation path can do with a wrapped device.
///
/// A device is wrapped by a [`ModulatedDevice`] when it has modulators; the wrapper is reached
/// through [`AudioDevice::as_modulated_mut`].
pub trait Modulated {
    /// Number of modulators the device instance carries.
    fn modulator_count(&self) -> usize;

    /// True when any modulator follows the note stream (envelopes, velocity, keytrack, random,
    /// or an LFO with Retrigger = Note), so a note should wake the device.
    fn has_note_driven_modulator(&self) -> bool;

    /// Add a modulator with its kind's default parameters.
    fn add_modulator(&mut self, mod_id: u8, kind: ModulatorKind) -> Result<(), String>;

    /// Remove a modulator and every route out of it.
    fn remove_modulator(&mut self, mod_id: u8) -> Result<(), String>;

    /// Remove every modulator and route.
    fn clear_modulators(&mut self);

    /// The current normalized value of a modulator parameter.
    fn get_modulator_param(&self, mod_id: u8, param_id: ParamId) -> Option<f32>;

    /// Set a modulator parameter. Returns its canonical normalized value.
    fn set_modulator_param(
        &mut self,
        mod_id: u8,
        param_id: ParamId,
        norm: f32,
    ) -> Result<f32, String>;

    /// Add, update or (amount 0) remove a route from `mod_id` to `target`
    /// (`param/{id}`, `child/{i.j…}/param/{id}` or `mod/{mod_id}/param/{id}`). Returns the
    /// clamped amount.
    fn set_modulator_route(&mut self, mod_id: u8, target: &str, amount: f32)
        -> Result<f32, String>;

    /// Every route, as `(mod_id, target string, amount)`.
    fn modulator_routes(&self) -> Vec<(u8, String, f32)>;

    /// The modulators and their kinds, in slot order.
    fn modulator_kinds(&self) -> Vec<(u8, ModulatorKind)>;

    /// Reset every applied offset back to the base. Called before unwrapping.
    fn reset_offsets(&mut self);

    /// Move the wrapped device out (leaving the wrapper empty). Called while unwrapping.
    fn take_inner(&mut self) -> Option<Box<dyn AudioDevice>>;
}

/// A device plus its modulators, routes and resolved targets. See the module docs.
pub struct ModulatedDevice {
    /// The wrapped device. `None` only between `take_inner` and the wrapper being dropped.
    inner: Option<Box<dyn AudioDevice>>,
    sample_rate: f32,
    mods: [Option<ModulatorState>; MAX_MODULATORS],
    /// Routes; a route's `slot` is an index into `targets`.
    routes: ModMatrix<MAX_ROUTES>,
    targets: [ModTarget; MAX_ROUTES],
    target_len: usize,
    /// Offsets pushed in by an enclosing wrapper (absolute, per parameter).
    external: [(ParamId, f32); MAX_ROUTES],
    external_len: usize,
    /// This step's own offsets per parameter, keyed by the parameter ID.
    own: [(ParamId, f32); MAX_ROUTES],
    own_len: usize,
    /// Scratch: modulator values for the current step, indexed by modulator slot.
    values: [f32; MAX_MODULATORS],
    /// What was applied at the last control step, so stale targets can be zeroed.
    applied: [(ModTarget, f32); MAX_ROUTES],
    applied_len: usize,
    transport: Transport,
    midi: [QueuedMidi; MIDI_QUEUE],
    midi_len: usize,
    midi_dropped: u64,
}

impl ModulatedDevice {
    /// Wrap `inner`, which keeps its own sample rate.
    pub fn new(inner: Box<dyn AudioDevice>, sample_rate: f32) -> Self {
        Self {
            inner: Some(inner),
            sample_rate: sample_rate.max(1.0),
            mods: [None; MAX_MODULATORS],
            routes: ModMatrix::new(),
            targets: [NO_TARGET; MAX_ROUTES],
            target_len: 0,
            external: [(0, 0.0); MAX_ROUTES],
            external_len: 0,
            own: [(0, 0.0); MAX_ROUTES],
            own_len: 0,
            values: [0.0; MAX_MODULATORS],
            applied: [(NO_TARGET, 0.0); MAX_ROUTES],
            applied_len: 0,
            transport: Transport::default(),
            midi: [NO_MIDI; MIDI_QUEUE],
            midi_len: 0,
            midi_dropped: 0,
        }
    }

    /// The wrapped device. Panics only if called after `take_inner` on a live wrapper.
    #[inline]
    fn dev(&self) -> &dyn AudioDevice {
        self.inner
            .as_deref()
            .expect("modulated device was unwrapped")
    }

    #[inline]
    fn dev_mut(&mut self) -> &mut dyn AudioDevice {
        self.inner
            .as_deref_mut()
            .expect("modulated device was unwrapped")
    }

    fn slot(&self, mod_id: u8) -> Result<usize, String> {
        let slot = mod_id as usize;
        if slot >= MAX_MODULATORS {
            return Err(format!(
                "modulator id {mod_id} is at or above the capacity of {MAX_MODULATORS}"
            ));
        }
        Ok(slot)
    }

    fn external_offset(&self, param_id: ParamId) -> f32 {
        self.external[..self.external_len]
            .iter()
            .find(|(id, _)| *id == param_id)
            .map(|(_, off)| *off)
            .unwrap_or(0.0)
    }

    fn set_external(&mut self, param_id: ParamId, offset: f32) {
        for entry in &mut self.external[..self.external_len] {
            if entry.0 == param_id {
                entry.1 = offset;
                return;
            }
        }
        if self.external_len < MAX_ROUTES {
            self.external[self.external_len] = (param_id, offset);
            self.external_len += 1;
        }
    }

    /// The resolved target's index, allocating one if it is new.
    fn target_slot(&mut self, target: ModTarget) -> Result<usize, String> {
        for (i, existing) in self.targets[..self.target_len].iter().enumerate() {
            if *existing == target {
                return Ok(i);
            }
        }
        if self.target_len == MAX_ROUTES {
            return Err("modulation target capacity reached".to_string());
        }
        self.targets[self.target_len] = target;
        self.target_len += 1;
        Ok(self.target_len - 1)
    }

    /// Advance every modulator by `frames` and store the values, without applying them.
    fn advance(&mut self, frames: usize) {
        for (i, slot) in self.mods.iter_mut().enumerate() {
            self.values[i] = match slot {
                Some(state) => state.advance(frames, &self.transport),
                None => 0.0,
            };
        }
    }

    /// Advance the modulators and apply the summed offsets. The mono control step.
    fn control_step(&mut self, frames: usize) {
        self.advance(frames);

        let mut acc = [0.0f32; MAX_ROUTES];
        self.routes.accumulate(&self.values, &mut acc);

        let mut dests = [0usize; MAX_ROUTES];
        let dest_len = self.routes.dests().len();
        dests[..dest_len].copy_from_slice(self.routes.dests());

        let mut plan = [(NO_TARGET, 0.0f32); MAX_ROUTES];
        let mut plan_len = 0;
        self.own_len = 0;
        for &slot in &dests[..dest_len] {
            let target = self.targets[slot];
            match target {
                ModTarget::Own(param_id) => {
                    let off = acc[slot];
                    plan[plan_len] = (target, off + self.external_offset(param_id));
                    plan_len += 1;
                    self.own[self.own_len] = (param_id, off);
                    self.own_len += 1;
                }
                ModTarget::Child(..) => {
                    plan[plan_len] = (target, acc[slot]);
                    plan_len += 1;
                }
                // Phase 9: modulator-to-modulator routes are stored but not evaluated.
                ModTarget::Modulator(..) => {}
            }
        }
        // External offsets on parameters this wrapper has no own route to.
        for i in 0..self.external_len {
            if plan_len == MAX_ROUTES {
                break;
            }
            let (param_id, off) = self.external[i];
            if !self.own[..self.own_len]
                .iter()
                .any(|(id, _)| *id == param_id)
            {
                plan[plan_len] = (ModTarget::Own(param_id), off);
                plan_len += 1;
            }
        }

        // Zero anything applied last step that has dropped out of the plan.
        let old = self.applied;
        let old_len = self.applied_len;
        for i in 0..old_len {
            let target = old[i].0;
            if !plan[..plan_len].iter().any(|(t, _)| *t == target) {
                self.apply(target, 0.0);
            }
        }
        for i in 0..plan_len {
            let (target, off) = plan[i];
            let previous = old[..old_len]
                .iter()
                .find(|(t, _)| *t == target)
                .map(|(_, value)| *value);
            // Re-applying an unchanged offset would restart a device's parameter ramp every
            // control step, so only push the value when it actually moved.
            if let Some(previous) = previous {
                if (previous - off).abs() <= OFFSET_EPSILON {
                    continue;
                }
            }
            self.apply(target, off);
        }
        self.applied = plan;
        self.applied_len = plan_len;
    }

    /// Push one target's offset to the device that owns it.
    fn apply(&mut self, target: ModTarget, offset: f32) {
        match target {
            ModTarget::Own(param_id) => {
                if offset != 0.0 {
                    self.dev_mut().mark_activity();
                }
                self.dev_mut().set_param_mod(param_id, offset);
            }
            ModTarget::Child(path, param_id) => {
                if let Some(device) = child_at_path_mut(self.dev_mut(), &path) {
                    if offset != 0.0 {
                        device.mark_activity();
                    }
                    device.set_param_mod(param_id, offset);
                }
            }
            ModTarget::Modulator(..) => {}
        }
    }

    /// Hand the wrapper's queued notes to the inner device, rebasing offsets into a sub-block
    /// starting at `base`.
    fn deliver_midi(&mut self, base: usize, frames: usize) {
        let end = base + frames;
        let mut read = 0;
        let mut write = 0;
        while read < self.midi_len {
            let event = self.midi[read];
            if event.frame_offset < end {
                let offset = event.frame_offset.saturating_sub(base);
                self.dev_mut().send_midi_event(
                    event.note,
                    event.velocity,
                    event.is_note_on,
                    offset,
                );
                read += 1;
            } else {
                self.midi[write] = event;
                write += 1;
                read += 1;
            }
        }
        self.midi_len = write;
    }

    /// Hand over every queued note unchanged (the whole block is one piece).
    fn deliver_all_midi(&mut self) {
        for i in 0..self.midi_len {
            let event = self.midi[i];
            self.dev_mut().send_midi_event(
                event.note,
                event.velocity,
                event.is_note_on,
                event.frame_offset,
            );
        }
        self.midi_len = 0;
    }

    /// Validate a route target string against the devices and modulators this wrapper holds.
    fn resolve_target(&self, spec: &str) -> Result<ModTarget, String> {
        let parts: Vec<&str> = spec.split('/').filter(|p| !p.is_empty()).collect();
        match parts.as_slice() {
            ["param", id] => {
                let param_id = parse_param_id(id)?;
                let device = self.dev();
                if !is_modulatable(device, param_id) {
                    return Err(format!(
                        "'{}' is not a modulatable parameter of {}",
                        param_id,
                        device.device_name()
                    ));
                }
                Ok(ModTarget::Own(param_id))
            }
            ["child", indices, "param", id] => {
                let path = parse_child_path(indices)?;
                let param_id = parse_param_id(id)?;
                let device = child_at_path(self.dev(), &path)
                    .ok_or_else(|| format!("no device at child/{indices}"))?;
                if !is_modulatable(device, param_id) {
                    return Err(format!(
                        "'{}' is not a modulatable parameter of {}",
                        param_id,
                        device.device_name()
                    ));
                }
                Ok(ModTarget::Child(path, param_id))
            }
            ["mod", mod_id, "param", id] => {
                let mod_id: u8 = mod_id
                    .parse()
                    .map_err(|_| format!("'{mod_id}' is not a modulator id"))?;
                let param_id = parse_param_id(id)?;
                let state = self.mods[self.slot(mod_id)?]
                    .as_ref()
                    .ok_or_else(|| format!("no modulator {mod_id}"))?;
                if state.params().table().slot(param_id).is_none() {
                    return Err(format!(
                        "'{}' is not a parameter of {}",
                        param_id,
                        state.kind().name()
                    ));
                }
                Ok(ModTarget::Modulator(mod_id, param_id))
            }
            _ => Err(format!("unrecognized route target '{spec}'")),
        }
    }

    fn target_string(target: &ModTarget) -> String {
        match target {
            ModTarget::Own(id) => format!("param/{id}"),
            ModTarget::Child(path, id) => {
                let indices: Vec<String> = path.indices().iter().map(|i| i.to_string()).collect();
                format!("child/{}/param/{}", indices.join("."), id)
            }
            ModTarget::Modulator(mod_id, id) => format!("mod/{mod_id}/param/{id}"),
        }
    }
}

/// The interleaved frame window for a sub-block, clamped to what the caller actually supplied.
/// Devices may be handed a shorter (even empty) input than `sample_count`; the plain device
/// sees the same short buffer, so the wrapped one must too.
fn window(start_frame: usize, frames: usize, len: usize) -> std::ops::Range<usize> {
    let start = (start_frame * 2).min(len);
    let end = ((start_frame + frames) * 2).min(len);
    start..end.max(start)
}

/// The device at a path relative to `device`, walking its containers. An empty path is the
/// device itself.
fn child_at_path<'a>(
    device: &'a dyn AudioDevice,
    path: &DevicePath,
) -> Option<&'a dyn AudioDevice> {
    let mut current = device;
    for &index in path.indices() {
        current = current.as_container()?.child(index)?;
    }
    Some(current)
}

fn child_at_path_mut<'a>(
    device: &'a mut dyn AudioDevice,
    path: &DevicePath,
) -> Option<&'a mut dyn AudioDevice> {
    let mut current = device;
    for &index in path.indices() {
        current = current.as_container_mut()?.child_mut(index)?;
    }
    Some(current)
}

fn is_modulatable(device: &dyn AudioDevice, param_id: ParamId) -> bool {
    device
        .parameters()
        .into_iter()
        .any(|info| info.id == param_id && info.is_modulatable)
}

fn parse_param_id(text: &str) -> Result<ParamId, String> {
    text.parse()
        .map_err(|_| format!("'{text}' is not a parameter id"))
}

fn parse_child_path(text: &str) -> Result<DevicePath, String> {
    let mut indices = Vec::new();
    for part in text.split('.') {
        indices.push(
            part.parse::<usize>()
                .map_err(|_| format!("'{text}' is not a child path"))?,
        );
    }
    DevicePath::try_from_indices(&indices)
        .ok_or_else(|| format!("'{text}' is deeper than the device path limit"))
}

fn is_note_driven(state: &ModulatorState) -> bool {
    match state.kind() {
        ModulatorKind::Lfo => state.get_param(LFO_RETRIGGER).unwrap_or(0.0) >= 0.5,
        _ => true,
    }
}

impl Modulated for ModulatedDevice {
    fn modulator_count(&self) -> usize {
        self.mods.iter().filter(|m| m.is_some()).count()
    }

    fn has_note_driven_modulator(&self) -> bool {
        self.mods.iter().flatten().any(is_note_driven)
    }

    fn add_modulator(&mut self, mod_id: u8, kind: ModulatorKind) -> Result<(), String> {
        let slot = self.slot(mod_id)?;
        if self.mods[slot].is_some() {
            return Err(format!("modulator {mod_id} already exists"));
        }
        self.mods[slot] = Some(ModulatorState::new(kind, self.sample_rate));
        Ok(())
    }

    fn remove_modulator(&mut self, mod_id: u8) -> Result<(), String> {
        let slot = self.slot(mod_id)?;
        if self.mods[slot].take().is_none() {
            return Err(format!("no modulator {mod_id}"));
        }
        // Drop every route out of it; the control step zeroes the targets they fed.
        let mut to_clear = [0usize; MAX_ROUTES];
        let mut count = 0;
        for (i, route) in self.routes.routes().iter().enumerate() {
            if route.mod_slot == slot {
                to_clear[count] = i;
                count += 1;
            }
        }
        for i in (0..count).rev() {
            let route = self.routes.routes()[to_clear[i]];
            let _ = self
                .routes
                .set(route.mod_slot, route.param_id, route.slot, 0.0);
        }
        Ok(())
    }

    fn clear_modulators(&mut self) {
        self.reset_offsets();
        self.mods = [None; MAX_MODULATORS];
        self.routes.clear();
    }

    fn get_modulator_param(&self, mod_id: u8, param_id: ParamId) -> Option<f32> {
        let slot = self.slot(mod_id).ok()?;
        self.mods[slot].as_ref()?.get_param(param_id)
    }

    fn set_modulator_param(
        &mut self,
        mod_id: u8,
        param_id: ParamId,
        norm: f32,
    ) -> Result<f32, String> {
        let slot = self.slot(mod_id)?;
        let state = self.mods[slot]
            .as_mut()
            .ok_or_else(|| format!("no modulator {mod_id}"))?;
        state
            .set_param(param_id, norm)
            .ok_or_else(|| format!("no parameter {param_id} on modulator {mod_id}"))?;
        Ok(state.get_param(param_id).unwrap_or(norm))
    }

    fn set_modulator_route(
        &mut self,
        mod_id: u8,
        target: &str,
        amount: f32,
    ) -> Result<f32, String> {
        let slot = self.slot(mod_id)?;
        if self.mods[slot].is_none() {
            return Err(format!("no modulator {mod_id}"));
        }
        let target = self.resolve_target(target)?;
        let target_slot = self.target_slot(target)?;
        self.routes
            .set(slot, target.param_id(), target_slot, amount)
            .map_err(|e| e.to_string())?;
        let clamped = self
            .routes
            .routes()
            .iter()
            .find(|r| r.mod_slot == slot && r.slot == target_slot);
        Ok(clamped.map(|r| r.amount).unwrap_or(0.0))
    }

    fn modulator_routes(&self) -> Vec<(u8, String, f32)> {
        self.routes
            .routes()
            .iter()
            .map(|route| {
                (
                    route.mod_slot as u8,
                    Self::target_string(&self.targets[route.slot]),
                    route.amount,
                )
            })
            .collect()
    }

    fn modulator_kinds(&self) -> Vec<(u8, ModulatorKind)> {
        self.mods
            .iter()
            .enumerate()
            .filter_map(|(i, m)| m.as_ref().map(|state| (i as u8, state.kind())))
            .collect()
    }

    fn reset_offsets(&mut self) {
        let applied = self.applied;
        for i in 0..self.applied_len {
            self.apply(applied[i].0, 0.0);
        }
        self.applied_len = 0;
        for i in 0..self.external_len {
            let (param_id, _) = self.external[i];
            self.dev_mut().set_param_mod(param_id, 0.0);
        }
        self.external_len = 0;
        self.own_len = 0;
    }

    fn take_inner(&mut self) -> Option<Box<dyn AudioDevice>> {
        self.inner.take()
    }
}

impl AudioDevice for ModulatedDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        let mut done = 0;
        while done < sample_count {
            let frames = (sample_count - done).min(CONTROL_STEP);
            self.control_step(frames);
            self.deliver_midi(done, frames);
            let in_range = window(done, frames, inputs.len());
            let out_range = window(done, frames, outputs.len());
            if self.dev().is_sleeping() {
                copy_interleaved(&inputs[in_range.clone()], &mut outputs[out_range], frames);
            } else {
                self.dev_mut()
                    .process_block(&inputs[in_range], &mut outputs[out_range], frames);
            }
            done += frames;
        }
    }

    fn process_block_with_extra(
        &mut self,
        inputs: &[f32],
        outputs: &mut [f32],
        extra_outs: &mut [Vec<f32>],
        sample_count: usize,
    ) {
        // Extra-out buses can't be carved into per-sub-block slices without allocating, so this
        // path stays whole-block. It is the aux-source path, where a device is fed to the mixer
        // once; the normal chain path uses `process_block`.
        self.control_step(sample_count);
        self.deliver_all_midi();
        let count = (sample_count * 2).min(outputs.len());
        if self.dev().is_sleeping() {
            copy_interleaved(inputs, outputs, sample_count);
            for buffer in extra_outs.iter_mut() {
                let n = count.min(buffer.len());
                buffer[..n].fill(0.0);
            }
        } else {
            self.dev_mut()
                .process_block_with_extra(inputs, outputs, extra_outs, sample_count);
        }
    }

    fn begin_block(&mut self, inputs: &[f32], sample_count: usize) -> bool {
        if !self.dev().has_async_blocks() {
            return false;
        }
        // Asynchronous inner: no splitting. Hand over the notes first, because the plugin
        // stages them inside its own `begin_block`. The offsets will go out as frame-stamped
        // `PARAM_MOD` events here (Phase 5).
        self.deliver_all_midi();
        self.advance(sample_count);
        self.dev_mut().begin_block(inputs, sample_count)
    }

    fn finish_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        self.dev_mut().finish_block(inputs, outputs, sample_count);
    }

    fn extra_output_bus_count(&self) -> usize {
        self.dev().extra_output_bus_count()
    }

    fn send_midi_event(&mut self, note: u8, velocity: u8, is_note_on: bool, frame_offset: usize) {
        for state in self.mods.iter_mut().flatten() {
            if is_note_on {
                state.note_on(note, velocity, frame_offset);
            } else {
                state.note_off(note, frame_offset);
            }
        }
        if self.midi_len < MIDI_QUEUE {
            self.midi[self.midi_len] = QueuedMidi {
                note,
                velocity,
                is_note_on,
                frame_offset,
            };
            self.midi_len += 1;
        } else {
            self.midi_dropped += 1;
            if self.midi_dropped % 1024 == 1 {
                warn!(
                    "modulated device '{}' dropped {} MIDI events (queue full)",
                    self.dev().device_name(),
                    self.midi_dropped
                );
            }
        }
    }

    fn choke(&mut self, frame_offset: usize) {
        self.dev_mut().choke(frame_offset);
    }

    fn set_parameter(&mut self, param_id: ParamId, value: f32) {
        self.dev_mut().set_parameter(param_id, value);
    }

    fn set_parameter_at(&mut self, param_id: ParamId, value: f32, frame_offset: usize) {
        self.dev_mut()
            .set_parameter_at(param_id, value, frame_offset);
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        // An enclosing wrapper's offset. Recorded; the control step combines it with this
        // wrapper's own routes and pushes the sum before the next block is processed.
        self.set_external(param_id, offset);
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<f32> {
        self.dev().get_parameter(param_id)
    }

    fn device_id(&self) -> &str {
        self.dev().device_id()
    }

    fn device_name(&self) -> &str {
        self.dev().device_name()
    }

    fn device_category(&self) -> crate::audio::devices::DeviceCategory {
        self.dev().device_category()
    }

    fn device_variant(&self) -> crate::audio::devices::DeviceVariant {
        self.dev().device_variant()
    }

    fn audio_ports(&self) -> Vec<crate::audio::devices::AudioPort> {
        self.dev().audio_ports()
    }

    fn midi_ports(&self) -> Vec<crate::audio::devices::MidiPort> {
        self.dev().midi_ports()
    }

    fn accepts_note_input(&self) -> bool {
        self.dev().accepts_note_input() || self.has_note_driven_modulator()
    }

    fn has_async_blocks(&self) -> bool {
        self.dev().has_async_blocks()
    }

    fn parameters(&self) -> Vec<crate::audio::devices::ParamInfo> {
        self.dev().parameters()
    }

    fn mod_sources(&self) -> Vec<crate::audio::devices::ModSourceInfo> {
        self.dev().mod_sources()
    }

    fn set_mod_route(
        &mut self,
        source: &str,
        param_id: ParamId,
        amount: f32,
    ) -> Result<(), String> {
        self.dev_mut().set_mod_route(source, param_id, amount)
    }

    fn clear_mod_routes(&mut self) {
        self.dev_mut().clear_mod_routes();
    }

    fn mod_routes(&self) -> Vec<crate::audio::devices::ModRoute> {
        self.dev().mod_routes()
    }

    fn parameter_group(&self, param_id: ParamId) -> &'static str {
        self.dev().parameter_group(param_id)
    }

    fn has_dynamic_parameters(&self) -> bool {
        self.dev().has_dynamic_parameters()
    }

    fn file_loading_support(&self) -> Option<crate::audio::devices::FileLoadingSupport> {
        self.dev().file_loading_support()
    }

    fn loading_state(&self) -> Option<String> {
        self.dev().loading_state()
    }

    fn reset(&mut self) {
        self.dev_mut().reset();
        // Offsets are re-applied on the next control step; drop the stale bookkeeping.
        self.applied_len = 0;
        self.own_len = 0;
    }

    fn set_transport(&mut self, transport: &Transport) {
        self.transport = *transport;
        self.dev_mut().set_transport(transport);
    }

    fn version(&self) -> &str {
        self.dev().version()
    }

    fn latency_frames(&self) -> u32 {
        self.dev().latency_frames()
    }

    fn prepare(&mut self, sample_rate: f32, max_frames: usize) {
        self.sample_rate = sample_rate.max(1.0);
        for state in self.mods.iter_mut().flatten() {
            state.prepare(self.sample_rate);
        }
        self.dev_mut().prepare(sample_rate, max_frames);
    }

    fn is_active(&self) -> bool {
        self.dev().is_active()
    }

    fn activate(&mut self) -> Result<(), String> {
        self.dev_mut().activate()
    }

    fn deactivate(&mut self) -> Result<(), String> {
        self.dev_mut().deactivate()
    }

    fn is_enabled(&self) -> bool {
        self.dev().is_enabled()
    }

    fn set_enabled(&mut self, enabled: bool) {
        self.dev_mut().set_enabled(enabled);
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self.dev_mut().as_any_mut()
    }

    fn as_modulated_mut(&mut self) -> Option<&mut dyn Modulated> {
        Some(self)
    }

    fn as_container(&self) -> Option<&dyn DeviceContainer> {
        self.dev().as_container()
    }

    fn as_container_mut(&mut self) -> Option<&mut dyn DeviceContainer> {
        self.dev_mut().as_container_mut()
    }

    fn is_container(&self) -> bool {
        self.dev().is_container()
    }

    fn is_sleeping(&self) -> bool {
        // Keep being processed while any modulator is live, so its state keeps advancing even
        // when the wrapped device is asleep (ADR-0014).
        self.modulator_count() == 0 && self.dev().is_sleeping()
    }

    fn mark_activity(&mut self) {
        self.dev_mut().mark_activity();
    }

    fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
        self.dev_mut().update_sleep_state(has_audio_activity)
    }

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        self.dev_mut().subscribe_data(data_type)
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        self.dev_mut().unsubscribe_data(data_type);
    }

    fn configure_data(
        &mut self,
        data_type: &str,
        key: &str,
        value: f32,
    ) -> Result<Option<crate::audio::devices::DataBuild>, String> {
        self.dev_mut().configure_data(data_type, key, value)
    }

    fn apply_data_build(
        &mut self,
        built: Box<dyn std::any::Any + Send>,
    ) -> Option<Box<dyn std::any::Any + Send>> {
        self.dev_mut().apply_data_build(built)
    }

    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        self.dev_mut().poll_device_data()
    }
}

/// Replace the device at `path` with a [`ModulatedDevice`] around it, if it isn't wrapped yet.
pub fn wrap_at_path(
    devices: &mut Vec<Box<dyn AudioDevice>>,
    path: &DevicePath,
    sample_rate: f32,
) -> Result<(), String> {
    let index = path
        .leaf_index()
        .ok_or_else(|| "cannot modulate the channel itself".to_string())?;
    if device_at_path_mut(devices, path)
        .and_then(|device| device.as_modulated_mut())
        .is_some()
    {
        return Ok(());
    }
    let parent = path.parent();
    let inner = remove_device(devices, path).ok_or_else(|| format!("no device at {path}"))?;
    let wrapped = Box::new(ModulatedDevice::new(inner, sample_rate));
    insert_device(devices, &parent, index, wrapped).map(|_| ())
}

/// Put back the device the wrapper at `path` holds, dropping the wrapper.
pub fn unwrap_at_path(
    devices: &mut Vec<Box<dyn AudioDevice>>,
    path: &DevicePath,
) -> Result<(), String> {
    let index = path
        .leaf_index()
        .ok_or_else(|| "cannot modulate the channel itself".to_string())?;
    let parent = path.parent();
    let mut boxed = remove_device(devices, path).ok_or_else(|| format!("no device at {path}"))?;
    let inner = match boxed.as_modulated_mut() {
        Some(modulated) => {
            modulated.reset_offsets();
            modulated.take_inner()
        }
        None => None,
    };
    let device = inner.unwrap_or(boxed);
    insert_device(devices, &parent, index, device).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::container::{move_device, DeviceContainer};
    use crate::audio::devices::param_table::{linear, slot_table, spec, ParamSpec, ParamTable};
    use crate::audio::devices::{
        create_drum, create_effect, DeviceCategory, DeviceSleepState, DeviceVariant, LayerDevice,
        ParamInfo,
    };
    use crate::audio::dsp::test_util::{render, stereo, white_noise};
    use crate::audio::modulation::kinds::{ENV_ATTACK, LFO_RATE};
    use crate::audio::types::Channel;
    use std::any::Any;
    use std::time::Duration;

    const SR: f32 = 48_000.0;
    const MAX_FRAMES: usize = 4_096;
    /// Delay's Mix parameter (normalized; float, automatable, so modulatable).
    const DELAY_MIX: ParamId = 41;

    fn delay() -> Box<dyn AudioDevice> {
        create_effect("sonara.builtin.delay", SR, MAX_FRAMES).expect("delay")
    }

    fn wrap(devices: &mut Vec<Box<dyn AudioDevice>>) {
        wrap_at_path(devices, &DevicePath::root(0), SR).expect("wrap");
    }

    /// First interleaved frame whose left channel is non-zero.
    fn onset(buffer: &[f32]) -> Option<usize> {
        (0..buffer.len() / 2).find(|&i| buffer[i * 2].abs() > 1e-7)
    }

    #[test]
    fn wrap_unwrap_round_trips_and_can_be_repeated() {
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![delay()];
        wrap(&mut devices);
        assert!(devices[0].as_modulated_mut().is_some());
        // Wrapping again is a no-op.
        wrap(&mut devices);
        assert_eq!(devices.len(), 1);
        unwrap_at_path(&mut devices, &DevicePath::root(0)).expect("unwrap");
        assert!(devices[0].as_modulated_mut().is_none());
        assert_eq!(devices[0].device_id(), "sonara.builtin.delay");
        // Unwrapping a plain device puts it back untouched.
        unwrap_at_path(&mut devices, &DevicePath::root(0)).expect("unwrap plain");
        assert_eq!(devices[0].device_id(), "sonara.builtin.delay");
    }

    #[test]
    fn an_lfo_on_a_delay_moves_the_output() {
        let input = stereo(&white_noise(4_800, 0.5, 3));
        let mut plain = delay();
        let reference = render(plain.as_mut(), &input, &[512]);

        let mut devices: Vec<Box<dyn AudioDevice>> = vec![delay()];
        wrap(&mut devices);
        {
            let modulated = devices[0].as_modulated_mut().unwrap();
            modulated.add_modulator(0, ModulatorKind::Lfo).unwrap();
            modulated
                .set_modulator_param(0, LFO_RATE, 1.0)
                .expect("rate");
            modulated
                .set_modulator_route(0, "param/41", 0.7)
                .expect("route");
        }
        let modulated = render(devices[0].as_mut(), &input, &[512]);
        assert_ne!(modulated, reference, "the LFO did not move the mix");

        // The base is untouched: get_parameter still reports the unmodulated value.
        let base = devices[0].get_parameter(DELAY_MIX).unwrap();
        assert!((base - 0.3).abs() < 1e-6, "base moved to {base}");
    }

    #[test]
    fn a_route_into_a_layer_child_resolves_through_the_container() {
        let input = stereo(&white_noise(4_800, 0.5, 9));
        let mut plain: Box<dyn AudioDevice> = {
            let mut layer = LayerDevice::new(MAX_FRAMES);
            layer.insert_child(0, delay());
            Box::new(layer)
        };
        let reference = render(plain.as_mut(), &input, &[512]);

        let mut layer = LayerDevice::new(MAX_FRAMES);
        layer.insert_child(0, delay());
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![Box::new(layer)];
        wrap(&mut devices);
        {
            let modulated = devices[0].as_modulated_mut().unwrap();
            modulated.add_modulator(0, ModulatorKind::Lfo).unwrap();
            modulated
                .set_modulator_route(0, "child/0/param/41", 0.7)
                .expect("route through the container");
            assert_eq!(
                modulated.modulator_routes(),
                vec![(0, "child/0/param/41".to_string(), 0.7)]
            );
        }
        let modulated = render(devices[0].as_mut(), &input, &[512]);
        assert_ne!(modulated, reference, "the child route had no effect");

        // An unresolvable or non-modulatable target is refused.
        let modulated = devices[0].as_modulated_mut().unwrap();
        assert!(modulated
            .set_modulator_route(0, "child/7/param/41", 0.5)
            .is_err());
        assert!(modulated.set_modulator_route(0, "param/999", 0.5).is_err());
    }

    #[test]
    fn sub_block_midi_rebasing_is_sample_accurate() {
        let input = vec![0.0f32; 512 * 2];
        let mut plain = create_drum("sonara.builtin.kick", SR, MAX_FRAMES).expect("kick");
        let mut out_plain = vec![0.0f32; 512 * 2];
        plain.send_midi_event(60, 100, true, 100);
        plain.process_block(&input, &mut out_plain, 512);

        let mut devices: Vec<Box<dyn AudioDevice>> =
            vec![create_drum("sonara.builtin.kick", SR, MAX_FRAMES).expect("kick")];
        wrap(&mut devices);
        // A modulator that routes nowhere, so only the block splitting is under test.
        devices[0]
            .as_modulated_mut()
            .unwrap()
            .add_modulator(0, ModulatorKind::Lfo)
            .unwrap();
        let mut out_wrapped = vec![0.0f32; 512 * 2];
        devices[0].send_midi_event(60, 100, true, 100);
        devices[0].process_block(&input, &mut out_wrapped, 512);

        assert_eq!(onset(&out_plain), Some(100));
        assert_eq!(
            onset(&out_wrapped),
            onset(&out_plain),
            "the wrapped drum's hit moved"
        );
        assert_eq!(
            out_wrapped, out_plain,
            "sub-block processing changed the sound"
        );
    }

    #[test]
    fn a_wrapped_device_survives_a_move_in_the_chain() {
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![delay(), delay()];
        wrap(&mut devices);
        devices[0]
            .as_modulated_mut()
            .unwrap()
            .add_modulator(0, ModulatorKind::Lfo)
            .unwrap();
        move_device(&mut devices, &DevicePath::default(), 0, 1).expect("move");
        assert!(devices[0].as_modulated_mut().is_none());
        let moved = devices[1]
            .as_modulated_mut()
            .expect("wrapper moved with it");
        assert_eq!(moved.modulator_count(), 1);
        assert_eq!(moved.modulator_kinds(), vec![(0, ModulatorKind::Lfo)]);
    }

    #[test]
    fn modulator_to_modulator_routes_are_stored_but_not_evaluated() {
        let input = stereo(&white_noise(2_400, 0.5, 4));

        // Modulator 0 (an envelope) is routed to modulator 1's rate; modulator 1 (an LFO) drives
        // the delay mix. If the mod-to-mod route were evaluated, the delay output would change.
        let mut reference_devices: Vec<Box<dyn AudioDevice>> = vec![delay()];
        wrap(&mut reference_devices);
        {
            let m = reference_devices[0].as_modulated_mut().unwrap();
            m.add_modulator(0, ModulatorKind::Adsr).unwrap();
            m.add_modulator(1, ModulatorKind::Lfo).unwrap();
            m.set_modulator_route(1, "param/41", 0.5).unwrap();
        }
        let reference = render(reference_devices[0].as_mut(), &input, &[512]);

        let mut devices: Vec<Box<dyn AudioDevice>> = vec![delay()];
        wrap(&mut devices);
        {
            let m = devices[0].as_modulated_mut().unwrap();
            m.add_modulator(0, ModulatorKind::Adsr).unwrap();
            m.add_modulator(1, ModulatorKind::Lfo).unwrap();
            m.set_modulator_route(1, "param/41", 0.5).unwrap();
            let amount = m.set_modulator_route(0, "mod/1/param/10", 0.5).unwrap();
            assert_eq!(amount, 0.5);
            assert!(m
                .modulator_routes()
                .contains(&(0, "mod/1/param/10".to_string(), 0.5)));
            assert!(m.get_modulator_param(1, ENV_ATTACK).is_some());
        }
        let modulated = render(devices[0].as_mut(), &input, &[512]);
        assert_eq!(
            modulated, reference,
            "a modulator-to-modulator route was evaluated before Phase 9"
        );
    }

    // === Note routing / waking ===

    const SPECS: [ParamSpec; 1] = [spec(0, "Mix", "Main", "%", linear(0.0, 100.0), 30.0)];
    const SLOTS: [u8; 1] = slot_table(&SPECS);
    static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

    /// A device that sleeps immediately and records what reaches it.
    struct Sleepy {
        sleep: DeviceSleepState,
        accepts: bool,
        notes: u32,
        last_mod: Option<f32>,
    }

    impl Sleepy {
        fn new(accepts: bool) -> Self {
            let mut sleep = DeviceSleepState::new();
            sleep.set_sleep_timeout(Duration::ZERO);
            Self {
                sleep,
                accepts,
                notes: 0,
                last_mod: None,
            }
        }
    }

    impl AudioDevice for Sleepy {
        fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}
        fn set_parameter(&mut self, _param_id: ParamId, _value: f32) {}
        fn set_param_mod(&mut self, _param_id: ParamId, offset: f32) {
            self.last_mod = Some(offset);
        }
        fn get_parameter(&self, _param_id: ParamId) -> Option<f32> {
            None
        }
        fn device_id(&self) -> &str {
            "test.sleepy"
        }
        fn device_name(&self) -> &str {
            "Sleepy"
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
        fn reset(&mut self) {}
        fn as_any_mut(&mut self) -> &mut dyn Any {
            self
        }
        fn accepts_note_input(&self) -> bool {
            self.accepts
        }
        fn send_midi_event(&mut self, _note: u8, _velocity: u8, _on: bool, _offset: usize) {
            self.notes += 1;
        }
        fn is_sleeping(&self) -> bool {
            self.sleep.is_sleeping()
        }
        fn mark_activity(&mut self) {
            self.sleep.mark_activity();
        }
        fn update_sleep_state(&mut self, has_audio_activity: bool) -> bool {
            self.sleep.check_activity(has_audio_activity)
        }
    }

    #[test]
    fn a_note_reaches_every_device_but_wakes_only_the_relevant_ones() {
        let mut channel = Channel::new(2, "test".to_string(), 512, SR);
        channel.devices.push(Box::new(Sleepy::new(true)));
        channel.devices.push(Box::new(Sleepy::new(false)));
        let mut wrapped: Box<dyn AudioDevice> =
            Box::new(ModulatedDevice::new(Box::new(Sleepy::new(false)), SR));
        wrapped
            .as_modulated_mut()
            .unwrap()
            .add_modulator(0, ModulatorKind::Adsr)
            .unwrap();
        channel.devices.push(wrapped);
        for device in channel.devices.iter_mut() {
            device.update_sleep_state(false);
        }

        channel.send_midi_event_to_devices(60, 100, true, 0);

        // The plain devices got the note straight away.
        for i in 0..2 {
            let sleepy = channel.devices[i]
                .as_any_mut()
                .downcast_mut::<Sleepy>()
                .expect("sleepy");
            assert_eq!(sleepy.notes, 1, "device {i} missed the note");
        }
        // A device with MIDI input woke; an effect with no modulators stayed asleep.
        assert!(
            !channel.devices[0].is_sleeping(),
            "the MIDI device stayed asleep"
        );
        assert!(channel.devices[1].is_sleeping(), "the plain effect woke up");

        // The wrapper hands its queued note to the inner device at the next block, and its
        // note-driven modulator woke that device (reached through `as_any_mut`, which forwards
        // to the inner device).
        let input = vec![0.0f32; 64 * 2];
        let mut output = vec![0.0f32; 64 * 2];
        channel.devices[2].process_block(&input, &mut output, 64);
        let inner = channel.devices[2]
            .as_any_mut()
            .downcast_mut::<Sleepy>()
            .expect("inner sleepy");
        assert_eq!(
            inner.notes, 1,
            "the wrapper did not forward its queued note"
        );
        assert!(
            !inner.is_sleeping(),
            "a note-driven modulator did not wake its device"
        );
    }

    #[test]
    fn unwrapping_resets_the_offsets_it_applied() {
        let mut devices: Vec<Box<dyn AudioDevice>> = vec![Box::new(Sleepy::new(false))];
        wrap(&mut devices);
        devices[0]
            .as_modulated_mut()
            .unwrap()
            .add_modulator(0, ModulatorKind::Adsr)
            .unwrap();
        devices[0]
            .as_modulated_mut()
            .unwrap()
            .set_modulator_route(0, "param/0", 0.5)
            .unwrap();
        // The envelope has to be gated for it to produce a value.
        devices[0].send_midi_event(60, 100, true, 0);
        let input = vec![0.0f32; 64 * 2];
        let mut output = vec![0.0f32; 64 * 2];
        devices[0].process_block(&input, &mut output, 64);
        let inner = devices[0]
            .as_any_mut()
            .downcast_mut::<Sleepy>()
            .expect("inner");
        assert!(
            inner.last_mod.unwrap_or(0.0) != 0.0,
            "the route applied no offset"
        );

        unwrap_at_path(&mut devices, &DevicePath::root(0)).unwrap();
        let inner = devices[0]
            .as_any_mut()
            .downcast_mut::<Sleepy>()
            .expect("inner");
        assert_eq!(inner.last_mod, Some(0.0), "the offset was not reset");
    }
}
