//! Generic host for one note effect (spec 027).
//!
//! [`NoteFxHost<P>`] runs a small [`NoteProcessor`] as an [`AudioDevice`], in the same way
//! `DrumHost` runs a drum voice. The host owns everything the note effects share:
//!
//! - audio pass-through;
//! - the input queue, sorted by frame when the note phase runs (clip and live notes arrive
//!   unsorted);
//! - the **held** table of input notes, so an input note-off the effect never saw a note-on for
//!   (it started while bypassed or before the effect was inserted) passes through unchanged;
//! - the **sounding** table (output id, key, parent input id), which gives note-offs that follow
//!   their note-ons (REQ-004) and lets bypass, removal and transport stop release everything
//!   (REQ-006, REQ-007);
//! - the **schedule** of output events dated past the current block (REQ-003);
//! - the parameter values (base plus modulation offset).
//!
//! The processor only says what to emit and when, through [`NoteCx`]. Times are absolute
//! sample counts: the host counts the samples of every block it sees.
//!
//! Real-time: every table is allocated in `new` with a fixed capacity and never grows. When one
//! is full, new generated notes are dropped and a warning is logged at most once a second, but
//! a note-off is never dropped: one that doesn't fit the output goes out at frame 0 of the next
//! block.

use tracing::warn;

use super::ids::next_generated_id;
use super::{NoteBuffer, TimedNote};
use crate::audio::devices::param_table::ParamTable;
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use crate::audio::midi_types::{is_clip_note, NoteEvent, SoundingNoteId, DEFAULT_RELEASE};
use crate::audio::transport::Transport;

/// Input notes queued between note phases.
pub const INPUT_CAPACITY: usize = 512;
/// Output notes per block.
pub const OUTPUT_CAPACITY: usize = 512;
/// Output events dated past the current block.
pub const SCHEDULE_CAPACITY: usize = 256;
/// Output notes sounding downstream.
pub const SOUNDING_CAPACITY: usize = 256;
/// Input notes held.
pub const HELD_CAPACITY: usize = 128;
/// Input slots kept free for note-offs, so a flood of note-ons can't crowd them out.
const INPUT_OFF_RESERVE: usize = 64;

/// One effect's note logic. The host calls it from the note phase on the audio thread, so
/// every method must be real-time safe.
pub trait NoteProcessor: Send + 'static {
    fn new(sample_rate: f32) -> Self
    where
        Self: Sized;

    /// Unique device identifier, e.g. `"sonara.builtin.transpose"`.
    fn device_id() -> &'static str
    where
        Self: Sized;

    /// Human-readable device name.
    fn device_name() -> &'static str
    where
        Self: Sized;

    fn table() -> &'static ParamTable
    where
        Self: Sized;

    /// A parameter's effective real value (base plus modulation; a choice index for enums,
    /// 0 or 1 for bools). Called for every parameter at creation.
    fn apply(&mut self, id: ParamId, real: f32);

    /// An input event at absolute sample `at`. A note-off arrives only for a note-on this
    /// processor saw; expressions pass through without reaching it.
    fn note(&mut self, cx: &mut NoteCx, event: &NoteEvent, at: u64);

    /// Advance the processor's own clock up to (not including) `until`, emitting what falls
    /// due. Called before each input event and once at the end of the block.
    fn run_until(&mut self, _cx: &mut NoteCx, _until: u64) {}

    /// Everything was released (bypass, removal): forget held and pending state.
    fn reset(&mut self) {}

    /// The transport stopped or jumped: the host already released clip-origin outputs and
    /// dropped their schedule; forget clip-origin held state (`is_clip_note`).
    fn discontinuity(&mut self, _cx: &mut NoteCx) {}

    fn set_transport(&mut self, _transport: &Transport) {}

    fn set_sample_rate(&mut self, _sample_rate: f32) {}

    /// Whether the effect feeds the `note_state` data stream (Arpeggiator, Step Sequencer).
    const HAS_STATE: bool = false;

    /// Fill the `note_state` view: current step, last sounding key and held keys. Only called
    /// while subscribed, at the polling rate.
    fn state(&self, _out: &mut NoteState) {}
}

/// What the `note_state` stream shows (design: Data and protocol changes). `0xFF` means none.
pub struct NoteState {
    pub step: u8,
    pub key: u8,
    pub branch: u8,
    /// Held keys, in any order; the host sorts them.
    pub held: Vec<u8>,
}

impl NoteState {
    fn new() -> Self {
        Self {
            step: 0xFF,
            key: 0xFF,
            branch: 0xFF,
            held: Vec::with_capacity(HELD_CAPACITY),
        }
    }

    fn clear(&mut self) {
        self.step = 0xFF;
        self.key = 0xFF;
        self.branch = 0xFF;
        self.held.clear();
    }
}

#[derive(Debug, Clone, Copy)]
struct Sounding {
    id: SoundingNoteId,
    key: u8,
    parent: SoundingNoteId,
}

#[derive(Debug, Clone, Copy)]
struct Scheduled {
    at: u64,
    event: NoteEvent,
    parent: SoundingNoteId,
}

/// What a processor emits through, for one block. Times are absolute samples; an event before
/// the block start goes out at frame 0, one at or after the block end is scheduled.
pub struct NoteCx<'a> {
    now: u64,
    end: u64,
    sample_rate: f32,
    output: &'a mut NoteBuffer,
    /// Note-offs that didn't fit `output`; they go out at frame 0 of the next block.
    overflow: &'a mut NoteBuffer,
    schedule: &'a mut Vec<Scheduled>,
    sounding: &'a mut Vec<Sounding>,
    dropped: &'a mut u32,
}

// Generated notes (`emit_on`) and the clock queries are for the generating effects (Chord,
// Arpeggiator, Note Echo, …) in the later waves; wave 1 only changes notes.
#[allow(dead_code)]
impl NoteCx<'_> {
    /// Absolute sample of the block's first frame.
    pub fn now(&self) -> u64 {
        self.now
    }

    /// Absolute sample just past the block.
    pub fn block_end(&self) -> u64 {
        self.end
    }

    pub fn sample_rate(&self) -> f32 {
        self.sample_rate
    }

    /// Put `event` in this block's output, with the sounding bookkeeping. False when a
    /// note-on was dropped for lack of room.
    fn emit_now(&mut self, at: u64, event: NoteEvent, parent: SoundingNoteId) -> bool {
        let note = TimedNote {
            frame: at.saturating_sub(self.now) as usize,
            event,
        };
        match event {
            NoteEvent::On { note_id, key, .. } => {
                if self.sounding.len() == self.sounding.capacity() || self.output.is_full() {
                    *self.dropped += 1;
                    return false;
                }
                self.sounding.push(Sounding {
                    id: note_id,
                    key,
                    parent,
                });
                self.output.push(note);
            }
            NoteEvent::Off { note_id, .. } => {
                if let Some(i) = self.sounding.iter().position(|s| s.id == note_id) {
                    self.sounding.remove(i);
                }
                if !self.output.push(note) {
                    self.overflow.push(TimedNote { frame: 0, event });
                }
            }
            NoteEvent::Expression { .. } => {
                if !self.output.push(note) {
                    *self.dropped += 1;
                }
            }
        }
        true
    }

    /// Emit now or schedule, by `at`.
    fn emit_at(&mut self, at: u64, event: NoteEvent, parent: SoundingNoteId) -> bool {
        if at < self.end {
            return self.emit_now(at, event, parent);
        }
        if self.schedule.len() < self.schedule.capacity() {
            self.schedule.push(Scheduled { at, event, parent });
            return true;
        }
        match event {
            // Never lose a note-off: end the note early instead.
            NoteEvent::Off { .. } => self.emit_now(self.end - 1, event, parent),
            _ => {
                *self.dropped += 1;
                false
            }
        }
    }

    /// Start a note with id `id` (a changed input note keeps its id, REQ-005) at `at`. A key
    /// outside 0..=127 is dropped (REQ-009). False when nothing was emitted.
    pub fn emit_on_with(
        &mut self,
        id: SoundingNoteId,
        key: i32,
        velocity: f32,
        at: u64,
        parent: SoundingNoteId,
    ) -> bool {
        if !(0..=127).contains(&key) {
            return false;
        }
        let event = NoteEvent::On {
            note_id: id,
            key: key as u8,
            velocity,
        };
        self.emit_at(at, event, parent)
    }

    /// Start a generated note at `at`, produced by input note `parent`. Returns its new id,
    /// which keeps the clip/live origin of `parent`, or None when the key is out of range or
    /// there was no room.
    pub fn emit_on(
        &mut self,
        key: i32,
        velocity: f32,
        at: u64,
        parent: SoundingNoteId,
    ) -> Option<SoundingNoteId> {
        let id = next_generated_id(is_clip_note(parent));
        self.emit_on_with(id, key, velocity, at, parent)
            .then_some(id)
    }

    /// End output note `id` at `at`. A note-on for it still waiting in the schedule is
    /// cancelled together with anything else scheduled for it (strum, REQ-019).
    pub fn emit_off(&mut self, id: SoundingNoteId, at: u64, release: f32) {
        let scheduled_on = self
            .schedule
            .iter()
            .any(|s| matches!(s.event, NoteEvent::On { note_id, .. } if note_id == id));
        if scheduled_on {
            self.schedule.retain(|s| s.event.note_id() != id);
            return;
        }
        let Some(sounding) = self.sounding.iter().find(|s| s.id == id).copied() else {
            return;
        };
        // A note-off already scheduled for it is replaced by this one.
        self.schedule
            .retain(|s| !(s.event.note_id() == id && matches!(s.event, NoteEvent::Off { .. })));
        let off = NoteEvent::Off {
            note_id: id,
            key: sounding.key,
            release,
        };
        self.emit_at(at, off, sounding.parent);
    }

    /// Schedule the note-off of generated note `id` (sounding key `key`) at `at`, even when its
    /// note-on is itself still scheduled. Unlike [`Self::emit_off`], this never cancels the
    /// note-on.
    pub fn end_note_at(
        &mut self,
        id: SoundingNoteId,
        key: u8,
        at: u64,
        release: f32,
        parent: SoundingNoteId,
    ) {
        let off = NoteEvent::Off {
            note_id: id,
            key,
            release,
        };
        self.emit_at(at, off, parent);
    }

    /// Pass an input event on unchanged. A note-on is tracked as its own parent, so
    /// `release_children` with its id ends it.
    pub fn pass(&mut self, event: &NoteEvent, at: u64) {
        match *event {
            NoteEvent::On {
                note_id,
                key,
                velocity,
            } => {
                self.emit_on_with(note_id, key as i32, velocity, at, note_id);
            }
            NoteEvent::Off {
                note_id, release, ..
            } => {
                if self.sounding.iter().any(|s| s.id == note_id) {
                    self.emit_off(note_id, at, release);
                } else {
                    self.emit_at(at, *event, note_id);
                }
            }
            NoteEvent::Expression { note_id, .. } => {
                self.emit_at(at, *event, note_id);
            }
        }
    }

    /// End every output of input note `parent` at `at`: sounding notes get a note-off, and
    /// scheduled ones are cancelled (REQ-004).
    pub fn release_children(&mut self, parent: SoundingNoteId, at: u64, release: f32) {
        // Cancel scheduled note-ons (and whatever is scheduled for those notes).
        while let Some(id) = self.schedule.iter().find_map(|s| match s.event {
            NoteEvent::On { note_id, .. } if s.parent == parent => Some(note_id),
            _ => None,
        }) {
            self.schedule.retain(|s| s.event.note_id() != id);
        }
        let mut i = 0;
        while i < self.sounding.len() {
            let s = self.sounding[i];
            if s.parent != parent {
                i += 1;
                continue;
            }
            self.schedule.retain(|e| e.event.note_id() != s.id);
            let off = NoteEvent::Off {
                note_id: s.id,
                key: s.key,
                release,
            };
            if at < self.end {
                // `emit_now` removes entry `i`; don't advance.
                self.emit_now(at, off, parent);
            } else {
                self.emit_at(at, off, parent);
                i += 1;
            }
        }
    }

    /// True while output note `id` is sounding downstream.
    pub fn is_sounding(&self, id: SoundingNoteId) -> bool {
        self.sounding.iter().any(|s| s.id == id)
    }

    /// Note-offs now for every sounding output matching `filter`, and drop the schedule
    /// entries matching it.
    fn release_where(&mut self, filter: impl Fn(SoundingNoteId) -> bool) {
        self.schedule.retain(|s| !filter(s.event.note_id()));
        let mut i = 0;
        while i < self.sounding.len() {
            let s = self.sounding[i];
            if filter(s.id) {
                let off = NoteEvent::Off {
                    note_id: s.id,
                    key: s.key,
                    release: DEFAULT_RELEASE,
                };
                self.emit_now(self.now, off, s.parent);
            } else {
                i += 1;
            }
        }
    }
}

/// A [`NoteProcessor`] plus the shared note-effect machinery, as an [`AudioDevice`].
pub struct NoteFxHost<P: NoteProcessor> {
    processor: P,
    table: &'static ParamTable,
    /// Base normalized value per slot.
    norm: Vec<f32>,
    /// Modulation offset per slot (ADR-0014: the base is never written).
    offset: Vec<f32>,
    sample_rate: f32,
    enabled: bool,
    /// Bypass toggled: release everything at the next note phase.
    release_pending: bool,
    /// Transport stopped or jumped: release clip-origin outputs at the next note phase.
    discontinuity_pending: bool,
    /// Absolute sample of the next block's first frame.
    now: u64,

    input: NoteBuffer,
    output: NoteBuffer,
    overflow: NoteBuffer,
    schedule: Vec<Scheduled>,
    sounding: Vec<Sounding>,
    held: Vec<SoundingNoteId>,

    dropped: u32,
    last_warning: Option<u64>,

    state_subscribed: bool,
    state: NoteState,
}

impl<P: NoteProcessor> NoteFxHost<P> {
    pub fn new(sample_rate: f32) -> Self {
        let table = P::table();
        let norm: Vec<f32> = table.specs.iter().map(|s| s.default_norm()).collect();
        let mut host = Self {
            processor: P::new(sample_rate),
            table,
            offset: vec![0.0; norm.len()],
            norm,
            sample_rate,
            enabled: true,
            release_pending: false,
            discontinuity_pending: false,
            now: 0,
            input: NoteBuffer::new(INPUT_CAPACITY),
            output: NoteBuffer::new(OUTPUT_CAPACITY),
            overflow: NoteBuffer::new(SOUNDING_CAPACITY),
            schedule: Vec::with_capacity(SCHEDULE_CAPACITY),
            sounding: Vec::with_capacity(SOUNDING_CAPACITY),
            held: Vec::with_capacity(HELD_CAPACITY),
            dropped: 0,
            last_warning: None,
            state_subscribed: false,
            state: NoteState::new(),
        };
        for slot in 0..host.norm.len() {
            host.apply_slot(slot);
        }
        host
    }

    /// The processor, for tests and device-specific queries.
    #[cfg(test)]
    pub fn processor(&self) -> &P {
        &self.processor
    }

    fn apply_slot(&mut self, slot: usize) {
        let spec = &self.table.specs[slot];
        let effective = (self.norm[slot] + self.offset[slot]).clamp(0.0, 1.0);
        self.processor.apply(spec.id, spec.to_real(effective));
    }

    /// The emit context for the block `[now, now + sample_count)`, plus the processor.
    fn split(&mut self, sample_count: usize) -> (&mut P, NoteCx<'_>) {
        let cx = NoteCx {
            now: self.now,
            end: self.now + sample_count.max(1) as u64,
            sample_rate: self.sample_rate,
            output: &mut self.output,
            overflow: &mut self.overflow,
            schedule: &mut self.schedule,
            sounding: &mut self.sounding,
            dropped: &mut self.dropped,
        };
        (&mut self.processor, cx)
    }

    /// Start a fresh output: last block's overflowed note-offs go first, at frame 0.
    fn begin_output(&mut self) {
        self.output.clear();
        for i in 0..self.overflow.len() {
            let note = self.overflow.as_slice()[i];
            self.output.push(note);
        }
        self.overflow.clear();
    }

    /// Release every sounding output and forget all state (bypass, removal).
    fn release_all(&mut self, sample_count: usize) {
        let (processor, mut cx) = self.split(sample_count);
        cx.release_where(|_| true);
        cx.schedule.clear();
        processor.reset();
        self.held.clear();
    }

    /// Log dropped notes, at most once a second.
    fn warn_dropped(&mut self) {
        if self.dropped == 0 {
            return;
        }
        let due = match self.last_warning {
            None => true,
            Some(last) => self.now.saturating_sub(last) >= self.sample_rate as u64,
        };
        if due {
            warn!(
                "note effect '{}' dropped {} notes (tables full)",
                P::device_name(),
                self.dropped
            );
            self.dropped = 0;
            self.last_warning = Some(self.now);
        }
    }
}

impl<P: NoteProcessor> AudioDevice for NoteFxHost<P> {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        crate::audio::devices::container::copy_interleaved(inputs, outputs, sample_count);
    }

    fn send_note_event(&mut self, event: &NoteEvent, frame_offset: usize) {
        let is_off = matches!(event, NoteEvent::Off { .. });
        if !is_off && self.input.room() <= INPUT_OFF_RESERVE {
            self.dropped += 1;
            return;
        }
        if !self.input.push(TimedNote {
            frame: frame_offset,
            event: *event,
        }) {
            self.dropped += 1;
        }
    }

    fn is_note_effect(&self) -> bool {
        true
    }

    fn process_notes(&mut self, sample_count: usize) -> &[TimedNote] {
        self.begin_output();

        if self.release_pending {
            self.release_pending = false;
            self.release_all(sample_count);
        }
        // The clip notes' own note-offs arrive in this block's input (stop releases them just
        // before the discontinuity), so their held entries stay until the input ran: each
        // note-off is then recognised and finds nothing left to release.
        let discontinuity = self.discontinuity_pending;
        if discontinuity {
            self.discontinuity_pending = false;
            let (processor, mut cx) = self.split(sample_count);
            cx.release_where(is_clip_note);
            processor.discontinuity(&mut cx);
        }

        self.input.sort();
        if !self.enabled {
            // Bypassed: input passes through unchanged (REQ-008).
            for i in 0..self.input.len() {
                let note = self.input.as_slice()[i];
                if !self.output.push(note) && matches!(note.event, NoteEvent::Off { .. }) {
                    self.overflow.push(TimedNote {
                        frame: 0,
                        event: note.event,
                    });
                }
            }
        } else {
            let now = self.now;
            let end = now + sample_count.max(1) as u64;
            let Self {
                processor,
                input,
                held,
                output,
                overflow,
                schedule,
                sounding,
                dropped,
                sample_rate,
                ..
            } = self;
            let mut cx = NoteCx {
                now,
                end,
                sample_rate: *sample_rate,
                output,
                overflow,
                schedule,
                sounding,
                dropped,
            };
            for note in input.as_slice() {
                let at = now + note.frame as u64;
                let id = note.event.note_id();
                let known = held.contains(&id);
                match note.event {
                    NoteEvent::On { .. } if !known && held.len() == held.capacity() => {
                        // No room to remember it: pass the pair through untouched instead.
                        *cx.dropped += 1;
                        cx.emit_at(at, note.event, id);
                        continue;
                    }
                    NoteEvent::On { .. } => {
                        if !known {
                            held.push(id);
                        }
                    }
                    NoteEvent::Off { .. } if known => {
                        held.retain(|&h| h != id);
                    }
                    // A note-off for a note-on this effect never saw, or an expression.
                    _ => {
                        cx.emit_at(at, note.event, id);
                        continue;
                    }
                }
                processor.run_until(&mut cx, at);
                processor.note(&mut cx, &note.event, at);
            }
            processor.run_until(&mut cx, end);

            // Scheduled events that fall in this block, in schedule order.
            let mut i = 0;
            while i < cx.schedule.len() {
                if cx.schedule[i].at < end {
                    let entry = cx.schedule.remove(i);
                    cx.emit_now(entry.at, entry.event, entry.parent);
                } else {
                    i += 1;
                }
            }
        }

        if discontinuity {
            self.held.retain(|&id| !is_clip_note(id));
        }
        self.input.clear();
        self.output.sort();
        self.now += sample_count as u64;
        self.warn_dropped();
        self.output.as_slice()
    }

    fn release_notes_now(&mut self) -> &[TimedNote] {
        self.begin_output();
        self.release_all(1);
        self.output.as_slice()
    }

    fn note_discontinuity(&mut self) {
        self.discontinuity_pending = true;
    }

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        if P::HAS_STATE && data_type == "note_state" {
            self.state_subscribed = true;
            return Ok(());
        }
        Err(format!(
            "Device '{}' does not support '{}' data stream",
            P::device_name(),
            data_type
        ))
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        if data_type == "note_state" {
            self.state_subscribed = false;
        }
    }

    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        if !P::HAS_STATE || !self.state_subscribed {
            return None;
        }
        self.state.clear();
        self.processor.state(&mut self.state);
        self.state.held.sort_unstable();
        self.state.held.dedup();
        let mut bytes = Vec::with_capacity(4 + self.state.held.len());
        bytes.push(self.state.step);
        bytes.push(self.state.key);
        bytes.push(self.state.branch);
        bytes.push(self.state.held.len().min(255) as u8);
        bytes.extend_from_slice(&self.state.held);
        Some(("note_state".to_string(), bytes))
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        if let Some(slot) = self.table.slot(param_id) {
            self.norm[slot] = self.table.specs[slot].canonical(value);
            self.apply_slot(slot);
        }
    }

    fn set_param_mod(&mut self, param_id: ParamId, offset: f32) {
        if let Some(slot) = self.table.slot(param_id) {
            if self.table.specs[slot].is_modulatable() {
                self.offset[slot] = offset;
                self.apply_slot(slot);
            }
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.table.slot(param_id).map(|slot| self.norm[slot])
    }

    fn device_id(&self) -> &str {
        P::device_id()
    }

    fn device_name(&self) -> &str {
        P::device_name()
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::NoteEffect
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn midi_ports(&self) -> Vec<MidiPort> {
        vec![
            MidiPort {
                id: 0,
                name: "Notes In".to_string(),
                flow: PortFlow::Input,
            },
            MidiPort {
                id: 1,
                name: "Notes Out".to_string(),
                flow: PortFlow::Output,
            },
        ]
    }

    fn accepts_note_input(&self) -> bool {
        true
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        self.table.infos()
    }

    fn reset(&mut self) {
        // A device reset silences everything downstream too; drop the bookkeeping.
        self.input.clear();
        self.output.clear();
        self.overflow.clear();
        self.schedule.clear();
        self.sounding.clear();
        self.held.clear();
        self.processor.reset();
    }

    fn set_transport(&mut self, transport: &Transport) {
        self.processor.set_transport(transport);
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        self.processor.set_sample_rate(sample_rate);
    }

    fn is_enabled(&self) -> bool {
        self.enabled
    }

    fn set_enabled(&mut self, enabled: bool) {
        if enabled != self.enabled {
            self.enabled = enabled;
            self.release_pending = true;
        }
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::audio::devices::param_table::{linear, slot_table, spec, ParamSpec};
    use crate::audio::midi_types::{is_generated, CLIP_ID_START};

    const SHIFT: ParamId = 0;
    const DELAY: ParamId = 1;
    const COPIES: ParamId = 2;
    const SPECS: [ParamSpec; 3] = [
        spec(SHIFT, "Shift", "Main", "st", linear(-48.0, 48.0), 0.0),
        spec(DELAY, "Delay", "Main", "frames", linear(0.0, 1000.0), 0.0),
        spec(COPIES, "Copies", "Main", "", linear(0.0, 4.0), 0.0),
    ];
    const SLOTS: [u8; 3] = slot_table(&SPECS);
    static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

    /// Passes each note shifted (keeping its id), plus `copies` generated notes, copy k at
    /// `+12 k` semitones and `k × delay` frames later. A note-off releases them all.
    pub struct TestProc {
        shift: i32,
        delay: u64,
        copies: u32,
    }

    impl NoteProcessor for TestProc {
        fn new(_sample_rate: f32) -> Self {
            Self {
                shift: 0,
                delay: 0,
                copies: 0,
            }
        }
        fn device_id() -> &'static str {
            "test.note_proc"
        }
        fn device_name() -> &'static str {
            "Test"
        }
        fn table() -> &'static ParamTable {
            &TABLE
        }
        fn apply(&mut self, id: ParamId, real: f32) {
            match id {
                SHIFT => self.shift = real.round() as i32,
                DELAY => self.delay = real.round() as u64,
                COPIES => self.copies = real.round() as u32,
                _ => {}
            }
        }
        fn note(&mut self, cx: &mut NoteCx, event: &NoteEvent, at: u64) {
            match *event {
                NoteEvent::On {
                    note_id,
                    key,
                    velocity,
                } => {
                    let key = key as i32 + self.shift;
                    cx.emit_on_with(note_id, key, velocity, at, note_id);
                    for k in 1..=self.copies {
                        cx.emit_on(
                            key + 12 * k as i32,
                            velocity,
                            at + self.delay * k as u64,
                            note_id,
                        );
                    }
                }
                NoteEvent::Off {
                    note_id, release, ..
                } => cx.release_children(note_id, at, release),
                NoteEvent::Expression { .. } => {}
            }
        }
    }

    fn host() -> NoteFxHost<TestProc> {
        NoteFxHost::new(48_000.0)
    }

    /// A test note effect with the given Shift (semitones), Delay (frames) and Copies.
    pub fn test_host(shift: f32, delay: f32, copies: f32) -> NoteFxHost<TestProc> {
        let mut h = host();
        set(&mut h, SHIFT, shift);
        set(&mut h, DELAY, delay);
        set(&mut h, COPIES, copies);
        h
    }

    fn set(host: &mut NoteFxHost<TestProc>, id: ParamId, real: f32) {
        let norm = TABLE.spec(id).unwrap().to_norm(real);
        host.set_parameter(id, norm);
    }

    fn on(id: u32, key: u8) -> NoteEvent {
        NoteEvent::On {
            note_id: id,
            key,
            velocity: 0.8,
        }
    }

    fn off(id: u32, key: u8) -> NoteEvent {
        NoteEvent::Off {
            note_id: id,
            key,
            release: 0.5,
        }
    }

    fn run(host: &mut impl AudioDevice, frames: usize) -> Vec<TimedNote> {
        host.process_notes(frames).to_vec()
    }

    /// `(frame, key, is_on)` per output note.
    fn summary(notes: &[TimedNote]) -> Vec<(usize, u8, bool)> {
        notes
            .iter()
            .map(|n| {
                (
                    n.frame,
                    n.event.key(),
                    matches!(n.event, NoteEvent::On { .. }),
                )
            })
            .collect()
    }

    #[test]
    fn changed_note_keeps_frame_and_id() {
        let mut h = host();
        set(&mut h, SHIFT, 12.0);
        h.send_note_event(&on(5, 60), 37);
        let out = run(&mut h, 64);
        assert_eq!(
            out,
            vec![TimedNote {
                frame: 37,
                event: on(5, 72)
            }]
        );
    }

    #[test]
    fn future_events_cross_blocks_at_the_right_offset() {
        let mut h = host();
        set(&mut h, DELAY, 96.0);
        set(&mut h, COPIES, 2.0);
        h.send_note_event(&on(1, 60), 10);
        // Copy 1 at 106 (block 2, frame 42), copy 2 at 202 (block 4, frame 10).
        assert_eq!(summary(&run(&mut h, 64)), vec![(10, 60, true)]);
        assert_eq!(summary(&run(&mut h, 64)), vec![(42, 72, true)]);
        assert_eq!(summary(&run(&mut h, 64)), vec![]);
        assert_eq!(summary(&run(&mut h, 64)), vec![(10, 84, true)]);
    }

    #[test]
    fn note_offs_follow_note_ons_after_a_parameter_change() {
        let mut h = host();
        set(&mut h, SHIFT, 12.0);
        h.send_note_event(&on(1, 60), 0);
        run(&mut h, 64);
        set(&mut h, SHIFT, 7.0);
        h.send_note_event(&off(1, 60), 3);
        let out = run(&mut h, 64);
        assert_eq!(
            out,
            vec![TimedNote {
                frame: 3,
                event: off(1, 72)
            }]
        );
    }

    #[test]
    fn generated_ids_are_distinct_and_paired() {
        let mut h = host();
        set(&mut h, COPIES, 2.0);
        h.send_note_event(&on(1, 60), 0);
        let ons = run(&mut h, 64);
        let ids: Vec<u32> = ons.iter().map(|n| n.event.note_id()).collect();
        assert_eq!(ids.len(), 3);
        assert_eq!(ids[0], 1, "the changed input keeps its id");
        assert!(is_generated(ids[1]) && is_generated(ids[2]) && ids[1] != ids[2]);

        h.send_note_event(&off(1, 60), 5);
        let offs = run(&mut h, 64);
        let mut off_ids: Vec<u32> = offs.iter().map(|n| n.event.note_id()).collect();
        off_ids.sort();
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(off_ids, sorted);
        assert!(offs
            .iter()
            .all(|n| matches!(n.event, NoteEvent::Off { .. })));
    }

    #[test]
    fn bypass_releases_and_then_passes_through() {
        let mut h = host();
        set(&mut h, SHIFT, 12.0);
        set(&mut h, DELAY, 500.0);
        set(&mut h, COPIES, 1.0);
        h.send_note_event(&on(1, 60), 0);
        assert_eq!(summary(&run(&mut h, 64)), vec![(0, 72, true)]);

        h.set_enabled(false);
        h.send_note_event(&on(2, 50), 4);
        // The sounding 72 is released, the scheduled copy is dropped, and the new note passes
        // unchanged.
        assert_eq!(
            summary(&run(&mut h, 64)),
            vec![(0, 72, false), (4, 50, true)]
        );
        for _ in 0..20 {
            assert!(run(&mut h, 64).is_empty(), "no scheduled copy arrives");
        }
    }

    #[test]
    fn stop_releases_clip_notes_and_keeps_live_ones() {
        let mut h = host();
        set(&mut h, DELAY, 100.0);
        set(&mut h, COPIES, 2.0);
        let clip_id = CLIP_ID_START + 3;
        h.send_note_event(&on(1, 48), 0);
        h.send_note_event(&on(clip_id, 60), 0);
        run(&mut h, 64);
        run(&mut h, 64); // first copies (frame 100) are out

        h.note_discontinuity();
        let out = run(&mut h, 64);
        // 60 and its first copy (72) are released; the live 48 and its copy keep sounding.
        let released: Vec<u8> = out
            .iter()
            .filter(|n| matches!(n.event, NoteEvent::Off { .. }))
            .map(|n| n.event.key())
            .collect();
        assert_eq!(released, vec![60, 72]);
        // The live note's second copy (frame 200) still arrives; the clip one never does.
        let mut later = Vec::new();
        for _ in 0..4 {
            later.extend(summary(&run(&mut h, 64)));
        }
        assert_eq!(later, vec![(8, 72, true)]);
    }

    #[test]
    fn out_of_range_keys_are_dropped() {
        let mut h = host();
        set(&mut h, SHIFT, 12.0);
        h.send_note_event(&on(1, 120), 0);
        h.send_note_event(&on(2, 100), 0);
        assert_eq!(summary(&run(&mut h, 64)), vec![(0, 112, true)]);
        h.send_note_event(&off(1, 120), 0);
        assert!(run(&mut h, 64).is_empty(), "nothing sounded for 120");
    }

    #[test]
    fn unknown_note_off_passes_through() {
        let mut h = host();
        set(&mut h, SHIFT, 12.0);
        h.send_note_event(&off(9, 64), 2);
        assert_eq!(
            run(&mut h, 64),
            vec![TimedNote {
                frame: 2,
                event: off(9, 64)
            }]
        );
    }

    #[test]
    fn unsorted_input_comes_out_sorted() {
        let mut h = host();
        h.send_note_event(&on(1, 60), 30);
        h.send_note_event(&on(2, 61), 5);
        h.send_note_event(&on(3, 62), 17);
        let frames: Vec<usize> = run(&mut h, 64).iter().map(|n| n.frame).collect();
        assert_eq!(frames, vec![5, 17, 30]);
    }

    #[test]
    fn overflow_keeps_note_offs() {
        let mut h = host();
        set(&mut h, COPIES, 4.0);
        // 60 inputs × 5 outputs = 300 notes, past the sounding table.
        for i in 0..60u32 {
            h.send_note_event(&on(i + 1, (i % 60) as u8), 0);
        }
        let ons = run(&mut h, 64);
        assert_eq!(
            ons.len(),
            SOUNDING_CAPACITY,
            "excess generated notes dropped"
        );
        for i in 0..60u32 {
            h.send_note_event(&off(i + 1, (i % 60) as u8), 0);
        }
        let mut offs = run(&mut h, 64);
        offs.extend(run(&mut h, 64));
        assert_eq!(
            offs.len(),
            SOUNDING_CAPACITY,
            "every sounding note gets its note-off"
        );
        assert!(offs
            .iter()
            .all(|n| matches!(n.event, NoteEvent::Off { .. })));
    }

    #[test]
    fn release_now_ends_everything() {
        let mut h = host();
        set(&mut h, COPIES, 1.0);
        set(&mut h, DELAY, 300.0);
        h.send_note_event(&on(1, 60), 0);
        run(&mut h, 64);
        let released = h.release_notes_now().to_vec();
        assert_eq!(summary(&released), vec![(0, 60, false)]);
        for _ in 0..10 {
            assert!(run(&mut h, 64).is_empty());
        }
    }
}
