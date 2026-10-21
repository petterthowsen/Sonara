//! MIDI Send (spec 049): a note device that forwards the note events reaching it to other
//! channels.
//!
//! It is an [`AudioDevice`] of its own rather than a [`NoteFxHost`](super::NoteFxHost): it has
//! two outputs. `process_notes` returns what continues down the sender's own chain (the
//! original events with Thru on, nothing with Consume), and the **outbox** holds the events
//! for the targets. The mixer's MIDI pre-pass (`mixing::midi_send`) copies the outbox to every
//! effective target in the same block, at the same frames.
//!
//! - Each forwarded note-on gets a fresh generated id (`next_generated_id`, keeping the clip or
//!   live origin), kept in the **sounding** table next to the input id. Note-offs and
//!   expressions map through it, so a target hears several sources of one key as independent
//!   notes (REQ-012) and clip-origin entries can be released on stop (REQ-011).
//! - The **thru** table remembers which input notes went down the chain, so switching to
//!   Consume (or bypassing) mid-note still ends them.
//! - CC isn't stopped by note effects, so `send_cc` queues it for the targets too.
//!
//! Real-time: every table and buffer is allocated in `new` and never grows. A note-on that
//! doesn't fit is dropped (logged at most once a second); a note-off never is. The buffers are
//! sized so that cannot happen for a note-off: the outbox holds every input event plus a
//! release of every sounding entry.

use tracing::warn;

use super::ids::next_generated_id;
use super::{NoteBuffer, TimedNote};
use crate::audio::devices::param_table::{
    slot_table, spec, Kind, ParamSpec, ParamTable, ParamValues,
};
use crate::audio::devices::{
    AudioDevice, DeviceCategory, DeviceVariant, MidiPort, ParamId, ParamInfo, ParamValue, PortFlow,
};
use crate::audio::midi_types::{is_clip_note, NoteEvent, SoundingNoteId, DEFAULT_RELEASE};
use crate::audio::types::ChannelId;

pub const DEVICE_ID: &str = "sonara.builtin.midi_send";

/// Parameter 0: events also continue down the sender's own chain (default on).
pub const THRU: ParamId = 0;

/// Targets one send can hold, requested and effective alike.
pub const MAX_TARGETS: usize = 64;
/// Input events queued between note phases.
const INPUT_CAPACITY: usize = 512;
/// Input slots kept free for note-offs, so a flood of note-ons can't crowd them out.
const INPUT_OFF_RESERVE: usize = 64;
/// Forwarded notes sounding on the targets, and input notes sounding down the chain.
const SOUNDING_CAPACITY: usize = 256;
/// Offs carried over from a command-thread release to the next block.
const CARRY_CAPACITY: usize = SOUNDING_CAPACITY;
/// Outbox: every input event, a release of every sounding entry and the carried offs.
pub const OUTBOX_CAPACITY: usize = INPUT_CAPACITY + SOUNDING_CAPACITY + CARRY_CAPACITY;
/// Downstream: every input event plus a release of every thru entry.
const DOWNSTREAM_CAPACITY: usize = INPUT_CAPACITY + SOUNDING_CAPACITY;
/// CC events queued for the targets between pre-passes.
pub const CC_CAPACITY: usize = 256;

const SPECS: [ParamSpec; 1] = [spec(THRU, "Thru", "Main", "", Kind::Bool, 1.0)];
const SLOTS: [u8; 1] = slot_table(&SPECS);
static TABLE: ParamTable = ParamTable::new(&SPECS, &SLOTS);

/// A controller value for the targets, at a frame of the current block.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TimedCc {
    pub frame: usize,
    pub cc: u8,
    pub value14: u16,
}

/// A fixed-capacity list of channel ids.
#[derive(Clone, Copy)]
pub struct TargetList {
    ids: [ChannelId; MAX_TARGETS],
    len: usize,
}

impl TargetList {
    pub const fn new() -> Self {
        Self {
            ids: [0; MAX_TARGETS],
            len: 0,
        }
    }

    /// Replace the contents with `ids` (extras past `MAX_TARGETS` are dropped).
    pub fn set(&mut self, ids: &[ChannelId]) {
        let n = ids.len().min(MAX_TARGETS);
        self.ids[..n].copy_from_slice(&ids[..n]);
        self.len = n;
    }

    pub fn as_slice(&self) -> &[ChannelId] {
        &self.ids[..self.len]
    }

    pub fn push(&mut self, id: ChannelId) {
        if self.len < MAX_TARGETS {
            self.ids[self.len] = id;
            self.len += 1;
        }
    }

    pub fn clear(&mut self) {
        self.len = 0;
    }
}

impl Default for TargetList {
    fn default() -> Self {
        Self::new()
    }
}

/// A note forwarded to the targets: the input note it follows and the id it carries there.
#[derive(Debug, Clone, Copy)]
struct Sounding {
    input: SoundingNoteId,
    output: SoundingNoteId,
    key: u8,
}

/// An input note that went down the sender's own chain (Thru).
#[derive(Debug, Clone, Copy)]
struct Held {
    id: SoundingNoteId,
    key: u8,
}

pub struct MidiSend {
    params: ParamValues<1>,
    sample_rate: f32,
    enabled: bool,
    /// Dormant (deactivated) devices bypass like a disabled one.
    is_active: bool,
    /// Bypass toggled: release everything at the next note phase.
    release_pending: bool,
    /// Transport stopped or jumped: release clip-origin entries at the next note phase.
    discontinuity_pending: bool,
    /// Absolute sample of the next block's first frame (for the once-a-second warning).
    now: u64,

    input: NoteBuffer,
    downstream: NoteBuffer,
    outbox: NoteBuffer,
    carry: NoteBuffer,
    cc_outbox: Vec<TimedCc>,
    sounding: Vec<Sounding>,
    thru: Vec<Held>,

    /// Targets Godot asked for, as sent.
    requested: TargetList,
    /// Targets actually forwarded to: valid and not closing a loop. Written by the command
    /// thread under the state lock, read by the pre-pass.
    effective: TargetList,
    /// Requested targets left out because they would close a loop.
    blocked: TargetList,

    dropped: u32,
    last_warning: Option<u64>,
}

impl MidiSend {
    pub fn new(sample_rate: f32) -> Self {
        Self {
            params: ParamValues::new(&TABLE),
            sample_rate,
            enabled: true,
            is_active: true,
            release_pending: false,
            discontinuity_pending: false,
            now: 0,
            input: NoteBuffer::new(INPUT_CAPACITY),
            downstream: NoteBuffer::new(DOWNSTREAM_CAPACITY),
            outbox: NoteBuffer::new(OUTBOX_CAPACITY),
            carry: NoteBuffer::new(CARRY_CAPACITY),
            cc_outbox: Vec::with_capacity(CC_CAPACITY),
            sounding: Vec::with_capacity(SOUNDING_CAPACITY),
            thru: Vec::with_capacity(SOUNDING_CAPACITY),
            requested: TargetList::new(),
            effective: TargetList::new(),
            blocked: TargetList::new(),
            dropped: 0,
            last_warning: None,
        }
    }

    fn thru_on(&self) -> bool {
        self.params.real(THRU).unwrap_or(1.0) >= 0.5
    }

    fn passes_notes(&self) -> bool {
        self.enabled && self.is_active
    }

    // === Targets (command thread writes, pre-pass reads) ===

    pub fn requested(&self) -> &[ChannelId] {
        self.requested.as_slice()
    }

    pub fn set_requested(&mut self, ids: &[ChannelId]) {
        self.requested.set(ids);
    }

    pub fn effective(&self) -> &[ChannelId] {
        self.effective.as_slice()
    }

    /// A copy of the effective targets, for delivering while the channel map is borrowed.
    pub fn effective_list(&self) -> TargetList {
        self.effective
    }

    pub fn set_effective(&mut self, ids: &[ChannelId]) {
        self.effective.set(ids);
    }

    pub fn blocked(&self) -> &[ChannelId] {
        self.blocked.as_slice()
    }

    pub fn set_blocked(&mut self, ids: &[ChannelId]) {
        self.blocked.set(ids);
    }

    // === Outbox (audio thread, pre-pass) ===

    /// This block's events for the targets, sorted by frame. Valid after `process_notes`.
    pub fn outbox(&self) -> &[TimedNote] {
        self.outbox.as_slice()
    }

    /// Controller values for the targets since the last pre-pass.
    pub fn cc_outbox(&self) -> &[TimedCc] {
        &self.cc_outbox
    }

    pub fn clear_cc_outbox(&mut self) {
        self.cc_outbox.clear();
    }

    // === Release (command thread) ===

    /// Command thread, before the targets change or the send goes away: note-offs at frame 0
    /// for every note forwarded to the targets, appended to `out`; the sounding table is
    /// emptied. Allocates only if `out` has to grow, which is at most one entry per note.
    pub fn take_target_releases(&mut self, out: &mut Vec<TimedNote>) {
        for s in self.sounding.drain(..) {
            out.push(TimedNote {
                frame: 0,
                event: NoteEvent::Off {
                    note_id: s.output,
                    key: s.key,
                    release: DEFAULT_RELEASE,
                },
            });
        }
        self.carry.clear();
    }

    /// Like [`take_target_releases`](Self::take_target_releases), but the table stays: the
    /// notes keep sounding on the targets that remain, and their note-offs still map.
    pub fn target_releases(&self, out: &mut Vec<TimedNote>) {
        for s in &self.sounding {
            out.push(TimedNote {
                frame: 0,
                event: NoteEvent::Off {
                    note_id: s.output,
                    key: s.key,
                    release: DEFAULT_RELEASE,
                },
            });
        }
    }

    /// Number of notes currently forwarded to the targets.
    #[cfg(test)]
    pub fn sounding_count(&self) -> usize {
        self.sounding.len()
    }

    // === Internals ===

    /// Note-offs into the outbox for forwarded notes matching `filter`.
    fn release_sounding(&mut self, filter: impl Fn(SoundingNoteId) -> bool) {
        let mut i = 0;
        while i < self.sounding.len() {
            let s = self.sounding[i];
            if filter(s.input) {
                self.outbox.push(TimedNote {
                    frame: 0,
                    event: NoteEvent::Off {
                        note_id: s.output,
                        key: s.key,
                        release: DEFAULT_RELEASE,
                    },
                });
                self.sounding.remove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Note-offs downstream for input notes matching `filter` that went down the chain.
    fn release_thru(&mut self, filter: impl Fn(SoundingNoteId) -> bool) {
        let mut i = 0;
        while i < self.thru.len() {
            let h = self.thru[i];
            if filter(h.id) {
                self.downstream.push(TimedNote {
                    frame: 0,
                    event: NoteEvent::Off {
                        note_id: h.id,
                        key: h.key,
                        release: DEFAULT_RELEASE,
                    },
                });
                self.thru.remove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Log dropped note-ons, at most once a second.
    fn warn_dropped(&mut self) {
        if self.dropped == 0 {
            return;
        }
        let due = match self.last_warning {
            None => true,
            Some(last) => self.now.saturating_sub(last) >= self.sample_rate as u64,
        };
        if due {
            warn!("MIDI Send dropped {} notes (tables full)", self.dropped);
            self.dropped = 0;
            self.last_warning = Some(self.now);
        }
    }

    /// Start a fresh output: last release's carried offs lead the outbox.
    fn begin_output(&mut self) {
        self.downstream.clear();
        self.outbox.clear();
        for i in 0..self.carry.len() {
            let note = self.carry.as_slice()[i];
            self.outbox.push(note);
        }
        self.carry.clear();
    }

    fn handle(&mut self, note: TimedNote, thru: bool) {
        let frame = note.frame;
        match note.event {
            NoteEvent::On {
                note_id,
                key,
                velocity,
            } => {
                if self.sounding.len() < self.sounding.capacity() {
                    let output = next_generated_id(is_clip_note(note_id));
                    self.sounding.push(Sounding {
                        input: note_id,
                        output,
                        key,
                    });
                    self.outbox.push(TimedNote {
                        frame,
                        event: NoteEvent::On {
                            note_id: output,
                            key,
                            velocity,
                        },
                    });
                } else {
                    self.dropped += 1;
                }
                if thru {
                    self.downstream.push(note);
                    if self.thru.len() < self.thru.capacity() {
                        self.thru.push(Held { id: note_id, key });
                    }
                }
            }
            NoteEvent::Off {
                note_id,
                key,
                release,
            } => {
                let forwarded = self.sounding.iter().position(|s| s.input == note_id);
                if let Some(i) = forwarded {
                    let s = self.sounding.remove(i);
                    self.outbox.push(TimedNote {
                        frame,
                        event: NoteEvent::Off {
                            note_id: s.output,
                            key: s.key,
                            release,
                        },
                    });
                }
                match self.thru.iter().position(|h| h.id == note_id) {
                    Some(j) => {
                        self.thru.remove(j);
                        self.downstream.push(note);
                    }
                    // A note-off for a note this send never saw start passes on, like every
                    // note effect does.
                    None if forwarded.is_none() => {
                        self.downstream.push(TimedNote {
                            frame,
                            event: NoteEvent::Off {
                                note_id,
                                key,
                                release,
                            },
                        });
                    }
                    None => {}
                }
            }
            NoteEvent::Expression {
                note_id,
                key,
                kind,
                value,
            } => {
                if let Some(s) = self.sounding.iter().find(|s| s.input == note_id) {
                    self.outbox.push(TimedNote {
                        frame,
                        event: NoteEvent::Expression {
                            note_id: s.output,
                            key,
                            kind,
                            value,
                        },
                    });
                }
                if thru || self.thru.iter().any(|h| h.id == note_id) {
                    self.downstream.push(note);
                }
            }
        }
    }
}

impl AudioDevice for MidiSend {
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

    fn send_cc(&mut self, cc: u8, value14: u16, frame_offset: usize) {
        if self.passes_notes() && self.cc_outbox.len() < self.cc_outbox.capacity() {
            self.cc_outbox.push(TimedCc {
                frame: frame_offset,
                cc,
                value14,
            });
        }
    }

    fn is_note_effect(&self) -> bool {
        true
    }

    fn process_notes(&mut self, sample_count: usize) -> &[TimedNote] {
        self.begin_output();

        if self.release_pending {
            self.release_pending = false;
            self.release_sounding(|_| true);
            self.release_thru(|_| true);
        }
        // Stop releases the clip notes just before the discontinuity, so their note-offs are
        // in this block's input too: the entries are gone by then, and each of those offs is
        // an unknown one that only passes down the chain.
        let discontinuity = self.discontinuity_pending;
        if discontinuity {
            self.discontinuity_pending = false;
            self.release_sounding(is_clip_note);
            self.release_thru(is_clip_note);
        }

        self.input.sort();
        if !self.passes_notes() {
            // Bypassed: input passes down the chain unchanged, nothing is forwarded.
            for i in 0..self.input.len() {
                let note = self.input.as_slice()[i];
                self.downstream.push(note);
            }
        } else {
            let thru = self.thru_on();
            for i in 0..self.input.len() {
                let note = self.input.as_slice()[i];
                self.handle(note, thru);
            }
        }

        self.input.clear();
        self.outbox.sort();
        self.downstream.sort();
        self.now += sample_count as u64;
        self.warn_dropped();
        self.downstream.as_slice()
    }

    fn release_notes_now(&mut self) -> &[TimedNote] {
        self.downstream.clear();
        // What the targets hold goes out with the next block's outbox (a command that also
        // changes the targets drains the table first, `take_target_releases`).
        let mut i = 0;
        while i < self.sounding.len() {
            let s = self.sounding[i];
            self.carry.push(TimedNote {
                frame: 0,
                event: NoteEvent::Off {
                    note_id: s.output,
                    key: s.key,
                    release: DEFAULT_RELEASE,
                },
            });
            i += 1;
        }
        self.sounding.clear();
        self.release_thru(|_| true);
        self.downstream.as_slice()
    }

    fn note_discontinuity(&mut self) {
        self.discontinuity_pending = true;
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.params.set(param_id, value);
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.params.get(param_id)
    }

    fn device_id(&self) -> &str {
        DEVICE_ID
    }

    fn device_name(&self) -> &str {
        "MIDI Send"
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
        TABLE.infos()
    }

    fn reset(&mut self) {
        // A device reset silences everything downstream too; drop the bookkeeping.
        self.input.clear();
        self.downstream.clear();
        self.outbox.clear();
        self.carry.clear();
        self.cc_outbox.clear();
        self.sounding.clear();
        self.thru.clear();
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
    }

    fn is_active(&self) -> bool {
        self.is_active
    }

    fn activate(&mut self) -> Result<(), String> {
        if !self.is_active {
            self.release_pending = true;
        }
        self.is_active = true;
        Ok(())
    }

    fn deactivate(&mut self) -> Result<(), String> {
        if self.is_active {
            self.release_pending = true;
        }
        self.is_active = false;
        Ok(())
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

    fn as_midi_send_mut(&mut self) -> Option<&mut MidiSend> {
        Some(self)
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::midi_types::CLIP_ID_START;

    const BLOCK: usize = 64;

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

    fn send() -> MidiSend {
        MidiSend::new(48_000.0)
    }

    fn set_thru(device: &mut MidiSend, thru: bool) {
        device.set_parameter(THRU, if thru { 1.0 } else { 0.0 });
    }

    /// Run a block and return (downstream, outbox).
    fn run(device: &mut MidiSend) -> (Vec<TimedNote>, Vec<TimedNote>) {
        let down = device.process_notes(BLOCK).to_vec();
        (down, device.outbox().to_vec())
    }

    #[test]
    fn forwards_with_new_ids_and_paired_offs() {
        let mut d = send();
        d.send_note_event(&on(5, 60), 7);
        d.send_note_event(&off(5, 60), 20);
        let (_, out) = run(&mut d);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].frame, 7);
        assert_eq!(out[1].frame, 20);
        let (a, b) = (out[0].event, out[1].event);
        assert!(matches!(a, NoteEvent::On { key: 60, velocity, .. } if velocity == 0.8));
        assert!(matches!(b, NoteEvent::Off { key: 60, release, .. } if release == 0.5));
        assert_ne!(a.note_id(), 5, "the target sees a new id");
        assert_eq!(a.note_id(), b.note_id(), "the off pairs with the on");
        assert_eq!(d.sounding_count(), 0);
    }

    #[test]
    fn forwarded_ids_keep_the_clip_origin() {
        let mut d = send();
        d.send_note_event(&on(CLIP_ID_START + 3, 60), 0);
        d.send_note_event(&on(3, 62), 0);
        let (_, out) = run(&mut d);
        assert!(is_clip_note(out[0].event.note_id()) != is_clip_note(out[1].event.note_id()));
        let clip = out
            .iter()
            .find(|n| n.event.key() == 60)
            .map(|n| n.event.note_id())
            .unwrap();
        assert!(is_clip_note(clip));
    }

    #[test]
    fn thru_passes_original_downstream() {
        let mut d = send();
        d.send_note_event(&on(5, 60), 3);
        d.send_note_event(&off(5, 60), 9);
        let (down, out) = run(&mut d);
        assert_eq!(
            down,
            vec![
                TimedNote {
                    frame: 3,
                    event: on(5, 60)
                },
                TimedNote {
                    frame: 9,
                    event: off(5, 60)
                }
            ]
        );
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn consume_passes_nothing_downstream() {
        let mut d = send();
        set_thru(&mut d, false);
        d.send_note_event(&on(5, 60), 3);
        d.send_note_event(&off(5, 60), 9);
        let (down, out) = run(&mut d);
        assert!(down.is_empty(), "{down:?}");
        assert_eq!(out.len(), 2, "the targets still get both");
    }

    #[test]
    fn switching_to_consume_mid_note_still_ends_the_downstream_note() {
        let mut d = send();
        d.send_note_event(&on(5, 60), 0);
        let (down, _) = run(&mut d);
        assert_eq!(down.len(), 1);
        set_thru(&mut d, false);
        d.send_note_event(&off(5, 60), 0);
        let (down, out) = run(&mut d);
        assert_eq!(down.len(), 1, "the off follows its on downstream");
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn cc_goes_to_outbox() {
        let mut d = send();
        d.send_cc(1, 8256, 5);
        assert_eq!(
            d.cc_outbox(),
            &[TimedCc {
                frame: 5,
                cc: 1,
                value14: 8256
            }]
        );
        d.clear_cc_outbox();
        assert!(d.cc_outbox().is_empty());

        // Bypassed, CC is not forwarded.
        d.set_enabled(false);
        d.send_cc(1, 100, 0);
        assert!(d.cc_outbox().is_empty());
    }

    #[test]
    fn expressions_follow_the_forwarded_note() {
        let mut d = send();
        d.send_note_event(&on(5, 60), 0);
        d.send_note_event(
            &NoteEvent::Expression {
                note_id: 5,
                key: 60,
                kind: crate::audio::midi_types::NoteExpression::Pressure,
                value: 0.4,
            },
            10,
        );
        // An expression for a note the send never saw is not forwarded.
        d.send_note_event(
            &NoteEvent::Expression {
                note_id: 99,
                key: 61,
                kind: crate::audio::midi_types::NoteExpression::Pressure,
                value: 0.4,
            },
            11,
        );
        let (_, out) = run(&mut d);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].event.note_id(), out[1].event.note_id());
    }

    #[test]
    fn bypass_releases_sounding_into_outbox() {
        let mut d = send();
        d.send_note_event(&on(1, 60), 0);
        d.send_note_event(&on(2, 64), 0);
        let (_, out) = run(&mut d);
        let ids: Vec<u32> = out.iter().map(|n| n.event.note_id()).collect();

        d.set_enabled(false);
        let (down, out) = run(&mut d);
        assert_eq!(out.len(), 2);
        assert!(out
            .iter()
            .all(|n| n.frame == 0 && matches!(n.event, NoteEvent::Off { .. })));
        assert!(out.iter().all(|n| ids.contains(&n.event.note_id())));
        assert_eq!(down.len(), 2, "the chain's own copies end too");

        // Bypassed, input passes down unchanged and nothing is forwarded.
        d.send_note_event(&on(3, 67), 4);
        let (down, out) = run(&mut d);
        assert_eq!(
            down,
            vec![TimedNote {
                frame: 4,
                event: on(3, 67)
            }]
        );
        assert!(out.is_empty());
    }

    #[test]
    fn release_now_carries_target_offs_to_the_next_block() {
        let mut d = send();
        d.send_note_event(&on(1, 60), 0);
        run(&mut d);
        let down = d.release_notes_now().to_vec();
        assert_eq!(down.len(), 1);
        let (_, out) = run(&mut d);
        assert_eq!(out.len(), 1);
        assert!(matches!(out[0].event, NoteEvent::Off { key: 60, .. }));
        assert_eq!(d.sounding_count(), 0);
    }

    #[test]
    fn take_target_releases_drains_the_table() {
        let mut d = send();
        d.send_note_event(&on(1, 60), 0);
        d.send_note_event(&on(2, 64), 0);
        run(&mut d);
        let mut offs = Vec::new();
        d.take_target_releases(&mut offs);
        assert_eq!(offs.len(), 2);
        assert_eq!(d.sounding_count(), 0);
        let (_, out) = run(&mut d);
        assert!(out.is_empty(), "nothing left to release twice");
    }

    #[test]
    fn discontinuity_releases_clip_origin_only() {
        let mut d = send();
        let clip = CLIP_ID_START + 11;
        d.send_note_event(&on(1, 48), 0);
        d.send_note_event(&on(clip, 60), 0);
        run(&mut d);
        assert_eq!(d.sounding_count(), 2);

        d.note_discontinuity();
        let (down, out) = run(&mut d);
        assert_eq!(out.len(), 1, "{out:?}");
        assert!(matches!(out[0].event, NoteEvent::Off { key: 60, .. }));
        assert_eq!(down.len(), 1);
        assert_eq!(down[0].event.note_id(), clip);
        assert_eq!(d.sounding_count(), 1, "the live note keeps sounding");
    }

    #[test]
    fn discontinuity_after_the_clip_notes_own_off_releases_nothing_twice() {
        let mut d = send();
        let clip = CLIP_ID_START + 11;
        d.send_note_event(&on(clip, 60), 0);
        run(&mut d);
        // A stop: the note's own off arrives with the discontinuity.
        d.send_note_event(&off(clip, 60), 0);
        d.note_discontinuity();
        let (_, out) = run(&mut d);
        let offs = out
            .iter()
            .filter(|n| matches!(n.event, NoteEvent::Off { .. }))
            .count();
        assert_eq!(offs, 1, "exactly one off reaches the targets: {out:?}");
    }

    #[test]
    fn full_tables_drop_ons_never_offs() {
        let mut d = send();
        // Fill the sounding table with distinct notes, a block at a time.
        for i in 0..SOUNDING_CAPACITY as u32 {
            d.send_note_event(&on(1000 + i, (i % 100) as u8), 0);
            if i % 100 == 99 {
                run(&mut d);
            }
        }
        run(&mut d);
        assert_eq!(d.sounding_count(), SOUNDING_CAPACITY);

        // One more note-on is dropped, with its pair.
        d.send_note_event(&on(5000, 70), 0);
        let (_, out) = run(&mut d);
        assert!(out.is_empty(), "{out:?}");
        assert_eq!(d.sounding_count(), SOUNDING_CAPACITY);

        // Its note-off is unknown and goes down the chain, forwarding nothing.
        d.send_note_event(&off(5000, 70), 0);
        let (down, out) = run(&mut d);
        assert!(out.is_empty());
        assert_eq!(down.len(), 1);

        // Every held note's off still reaches the targets.
        for i in 0..SOUNDING_CAPACITY as u32 {
            d.send_note_event(&off(1000 + i, (i % 100) as u8), 1);
        }
        let mut offs = 0;
        for _ in 0..3 {
            let (_, out) = run(&mut d);
            offs += out
                .iter()
                .filter(|n| matches!(n.event, NoteEvent::Off { .. }))
                .count();
        }
        assert_eq!(offs, SOUNDING_CAPACITY);
        assert_eq!(d.sounding_count(), 0);
    }

    #[test]
    fn unknown_note_off_passes_down_but_is_not_forwarded() {
        let mut d = send();
        d.send_note_event(&off(99, 70), 9);
        let (down, out) = run(&mut d);
        assert_eq!(down.len(), 1);
        assert!(out.is_empty());
    }
}
