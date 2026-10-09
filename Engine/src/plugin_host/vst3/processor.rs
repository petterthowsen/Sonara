//! `Vst3Processor`: the audio-thread half of a VST3 instance (spec 028, phase 2).
//!
//! The main thread keeps the `Vst3Instance` (controller, state, GUI); the host's audio thread
//! owns this processor and calls `IAudioProcessor::process` on the blocks the engine
//! publishes in shared memory. Everything the plugin is handed (event lists, parameter
//! queues) is preallocated here, so a block never allocates.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Instant;

use ::vst3::com_scrape_types::{ComPtr, ComWrapper};
use ::vst3::Steinberg as sb;
use ::vst3::Steinberg::Vst as v3;
use ::vst3::Steinberg::Vst::IAudioProcessorTrait;
use tracing::warn;

use super::event_list::EventList;
use super::host_context::Vst3Shared;
use super::param_changes::ParameterChanges;
use super::params::Vst3ParamMap;
use crate::audio::ipc::protocol::TRANSPORT_FLAG_PLAYING;
use crate::audio::ipc::{
    BlockEvent, BlockTransport, SharedMemory, EVENT_NOTE_OFF, EVENT_NOTE_ON, EVENT_PARAM,
    MAX_BLOCK_EVENTS,
};

/// Parameters that may change in one block, and points per parameter. More are dropped.
const PARAM_QUEUES: usize = 128;
const POINTS_PER_QUEUE: usize = 32;

/// What `translate_events` dropped, for rate-limited logging.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Dropped {
    /// `EVENT_PARAM_MOD` and `EVENT_NOTE_CHOKE`: no VST3 equivalent (out of scope for v1).
    pub unsupported: u32,
    /// Events or parameter points that did not fit the preallocated lists.
    pub overflow: u32,
}

/// Turn the block's events into VST3 note events and parameter points.
///
/// Notes become `kNoteOnEvent`/`kNoteOffEvent` at `sample_offset` (clamped into the block);
/// parameter events become points in that parameter's queue. The note list is sorted by
/// offset, and each queue keeps its points ordered.
pub fn translate_events(
    events: &[BlockEvent],
    frames: u32,
    param_map: &Vst3ParamMap,
    event_list: &EventList,
    changes: &ParameterChanges,
) -> Dropped {
    let mut dropped = Dropped::default();
    let last_frame = frames.saturating_sub(1) as i32;
    for event in events {
        let offset = (event.sample_offset as i32).min(last_frame);
        match event.kind {
            EVENT_NOTE_ON | EVENT_NOTE_OFF => {
                let mut vst_event: v3::Event = unsafe { std::mem::zeroed() };
                vst_event.busIndex = 0;
                vst_event.sampleOffset = offset;
                if event.kind == EVENT_NOTE_ON {
                    vst_event.r#type = v3::Event_::EventTypes_::kNoteOnEvent as u16;
                    vst_event.__field0 = v3::Event__type0 {
                        noteOn: v3::NoteOnEvent {
                            channel: 0,
                            pitch: event.note as i16,
                            tuning: 0.0,
                            velocity: event.value,
                            length: 0,
                            noteId: event.id as i32,
                        },
                    };
                } else {
                    vst_event.r#type = v3::Event_::EventTypes_::kNoteOffEvent as u16;
                    vst_event.__field0 = v3::Event__type0 {
                        noteOff: v3::NoteOffEvent {
                            channel: 0,
                            pitch: event.note as i16,
                            velocity: event.value,
                            noteId: event.id as i32,
                            tuning: 0.0,
                        },
                    };
                }
                if !event_list.push(&vst_event) {
                    dropped.overflow += 1;
                }
            }
            EVENT_PARAM => {
                let Some(id) = param_map.param_id(event.id) else {
                    continue;
                };
                if !push_point(changes, id, offset, event.value as f64) {
                    dropped.overflow += 1;
                }
            }
            _ => dropped.unsupported += 1,
        }
    }
    event_list.sort_by_sample_offset();
    dropped
}

fn push_point(changes: &ParameterChanges, id: v3::ParamID, offset: i32, value: f64) -> bool {
    match changes.queue_for(id) {
        Some((queue, _)) => queue.push(offset, value),
        None => false,
    }
}

/// Fill the process context from the block's transport. Tempo, time signature, project time
/// in samples and quarter notes, and the bar position are always valid.
pub fn fill_process_context(
    transport: &BlockTransport,
    sample_rate: f64,
    continuous_samples: i64,
    context: &mut v3::ProcessContext,
) {
    use v3::ProcessContext_::StatesAndFlags_ as flag;
    let mut state = flag::kTempoValid
        | flag::kTimeSigValid
        | flag::kProjectTimeMusicValid
        | flag::kBarPositionValid
        | flag::kContTimeValid;
    if transport.flags & TRANSPORT_FLAG_PLAYING != 0 {
        state |= flag::kPlaying;
    }
    context.state = state as u32;
    context.sampleRate = sample_rate;
    context.projectTimeSamples = (transport.song_pos_seconds * sample_rate).round() as i64;
    context.continousTimeSamples = continuous_samples;
    context.projectTimeMusic = transport.song_pos_beats;
    context.barPositionMusic = transport.bar_start_beats;
    context.tempo = transport.tempo;
    context.timeSigNumerator = transport.tsig_num as i32;
    context.timeSigDenominator = transport.tsig_den as i32;
}

/// The processor half of a VST3 instance, owned by the host's audio thread.
pub struct Vst3Processor {
    processor: ComPtr<v3::IAudioProcessor>,
    shared: Arc<Vst3Shared>,
    param_map: Arc<Vst3ParamMap>,
    sample_rate: f64,
    offline: bool,
    has_audio_input: bool,
    input_events: ComWrapper<EventList>,
    output_events: ComWrapper<EventList>,
    input_changes: ComWrapper<ParameterChanges>,
    output_changes: ComWrapper<ParameterChanges>,
    input_events_ptr: ComPtr<v3::IEventList>,
    output_events_ptr: ComPtr<v3::IEventList>,
    input_changes_ptr: ComPtr<v3::IParameterChanges>,
    output_changes_ptr: ComPtr<v3::IParameterChanges>,
    context: v3::ProcessContext,
    /// Frames processed so far, for `continousTimeSamples`.
    steady: i64,
    /// Unsupported events dropped, logged once.
    warned_unsupported: bool,
    warned_overflow: bool,
}

// SAFETY: the processor is created on the main thread and then used only by the audio thread,
// which is the VST3 threading contract (`process` and the processor's other calls never run
// concurrently with themselves). The COM objects inside are thread-agnostic and are touched
// only by that thread after the hand-off.
unsafe impl Send for Vst3Processor {}

impl Vst3Processor {
    pub fn new(
        processor: ComPtr<v3::IAudioProcessor>,
        shared: Arc<Vst3Shared>,
        param_map: Arc<Vst3ParamMap>,
        sample_rate: f64,
        offline: bool,
        has_audio_input: bool,
    ) -> Self {
        let input_events = ComWrapper::new(EventList::with_capacity(MAX_BLOCK_EVENTS));
        let output_events = ComWrapper::new(EventList::with_capacity(MAX_BLOCK_EVENTS));
        let input_changes = ComWrapper::new(ParameterChanges::new(PARAM_QUEUES, POINTS_PER_QUEUE));
        let output_changes = ComWrapper::new(ParameterChanges::new(PARAM_QUEUES, POINTS_PER_QUEUE));
        Self {
            processor,
            shared,
            param_map,
            sample_rate,
            offline,
            has_audio_input,
            input_events_ptr: input_events.to_com_ptr().unwrap(),
            output_events_ptr: output_events.to_com_ptr().unwrap(),
            input_changes_ptr: input_changes.to_com_ptr().unwrap(),
            output_changes_ptr: output_changes.to_com_ptr().unwrap(),
            input_events,
            output_events,
            input_changes,
            output_changes,
            context: unsafe { std::mem::zeroed() },
            steady: 0,
            warned_unsupported: false,
            warned_overflow: false,
        }
    }

    pub fn set_param_map(&mut self, map: Arc<Vst3ParamMap>) {
        self.param_map = map;
    }

    /// Process the block the engine published in `memory`, and answer it (`done_seq`).
    /// `ring` wakes the engine's wait.
    pub fn process_request(
        &mut self,
        instance_id: u32,
        span: &tracing::Span,
        memory: &SharedMemory,
        ring: impl FnOnce(),
    ) {
        let layout = *memory.layout();
        let control = memory.control();
        let seq = control.request_seq.load(Ordering::Acquire);
        let frames = (control.input_frames.load(Ordering::Acquire) as usize).min(layout.max_frames);

        // Input events: the engine's, then the main thread's queued edits at offset 0.
        self.input_events.clear();
        self.output_events.clear();
        self.input_changes.reset();
        self.output_changes.reset();
        let count =
            (control.input_event_count.load(Ordering::Acquire) as usize).min(layout.max_events);
        let dropped = translate_events(
            &memory.input_events()[..count],
            frames as u32,
            &self.param_map,
            &self.input_events,
            &self.input_changes,
        );
        {
            let changes = &self.input_changes;
            let mut overflow = 0;
            self.shared.drain_to_audio(|id, value| {
                if !push_point(changes, id, 0, value) {
                    overflow += 1;
                }
            });
            if overflow > 0 && !self.warned_overflow {
                self.warned_overflow = true;
                let _entered = span.enter();
                warn!("VST3 parameter changes overflowed the preallocated queues; dropping");
            }
        }
        if dropped.unsupported > 0 && !self.warned_unsupported {
            self.warned_unsupported = true;
            let _entered = span.enter();
            warn!("Dropping modulation and choke events: VST3 has no equivalent (logged once)");
        }
        if dropped.overflow > 0 && !self.warned_overflow {
            self.warned_overflow = true;
            let _entered = span.enter();
            warn!("VST3 events overflowed the preallocated lists; dropping");
        }

        // Planar stereo planes in shared memory; the plugin writes straight into the output.
        let (in_left, in_rest) = memory.input().split_at_mut(layout.max_frames);
        let (out_left, out_rest) = memory.output().split_at_mut(layout.max_frames);
        let stereo = layout.max_channels >= 2;
        let mut in_channels = [
            in_left.as_mut_ptr(),
            if stereo {
                in_rest.as_mut_ptr()
            } else {
                in_left.as_mut_ptr()
            },
        ];
        let mut out_channels = [
            out_left.as_mut_ptr(),
            if stereo {
                out_rest.as_mut_ptr()
            } else {
                out_left.as_mut_ptr()
            },
        ];
        let channel_count = if stereo { 2 } else { 1 };
        out_left[..frames].fill(0.0);
        if stereo {
            out_rest[..frames].fill(0.0);
        }
        let mut input_bus = v3::AudioBusBuffers {
            numChannels: channel_count,
            silenceFlags: 0,
            __field0: v3::AudioBusBuffers__type0 {
                channelBuffers32: in_channels.as_mut_ptr(),
            },
        };
        let mut output_bus = v3::AudioBusBuffers {
            numChannels: channel_count,
            silenceFlags: 0,
            __field0: v3::AudioBusBuffers__type0 {
                channelBuffers32: out_channels.as_mut_ptr(),
            },
        };

        fill_process_context(
            memory.transport(),
            self.sample_rate,
            self.steady,
            &mut self.context,
        );
        let mut data = v3::ProcessData {
            processMode: if self.offline {
                v3::ProcessModes_::kOffline
            } else {
                v3::ProcessModes_::kRealtime
            } as i32,
            symbolicSampleSize: v3::SymbolicSampleSizes_::kSample32 as i32,
            numSamples: frames as i32,
            numInputs: i32::from(self.has_audio_input),
            numOutputs: 1,
            inputs: if self.has_audio_input {
                &mut input_bus
            } else {
                std::ptr::null_mut()
            },
            outputs: &mut output_bus,
            inputParameterChanges: self.input_changes_ptr.as_ptr(),
            outputParameterChanges: self.output_changes_ptr.as_ptr(),
            inputEvents: self.input_events_ptr.as_ptr(),
            outputEvents: self.output_events_ptr.as_ptr(),
            processContext: &mut self.context,
        };

        let started_at = Instant::now();
        let result = unsafe { self.processor.process(&mut data) };
        let process_ns = started_at.elapsed().as_nanos().min(u32::MAX as u128) as u32;
        self.steady = self.steady.wrapping_add(frames as i64);

        if result == sb::kResultOk {
            control.status.store(0, Ordering::Relaxed);
        } else {
            let _entered = span.enter();
            warn!(
                "VST3 instance {} processing error: tresult {}",
                instance_id, result
            );
            control.status.store(1, Ordering::Relaxed);
        }

        // The processor's own parameter changes go back through the block (the last point of
        // each queue), and to the controller via the main thread.
        let mut written = 0usize;
        let out_events = memory.output_events();
        for queue_index in 0..self.output_changes.len() {
            let Some(queue) = self.output_changes.queue(queue_index) else {
                continue;
            };
            let Some((offset, value)) = queue.len().checked_sub(1).and_then(|i| queue.get(i))
            else {
                continue;
            };
            self.shared.push_from_audio(queue.id(), value);
            if written < out_events.len() {
                if let Some(index) = self.param_map.index_of(queue.id()) {
                    out_events[written] =
                        BlockEvent::param(offset.max(0) as u32, index, value as f32);
                    written += 1;
                }
            }
        }
        control
            .output_frames
            .store(frames as u32, Ordering::Relaxed);
        control
            .output_event_count
            .store(written as u32, Ordering::Relaxed);
        control.process_ns.store(process_ns, Ordering::Relaxed);
        control.done_seq.store(seq, Ordering::Release);
        ring();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::ipc::{EVENT_NOTE_CHOKE, EVENT_PARAM_MOD};

    fn lists() -> (EventList, ParameterChanges) {
        (EventList::with_capacity(8), ParameterChanges::new(4, 4))
    }

    fn map() -> Vst3ParamMap {
        Vst3ParamMap::from_ids(vec![Some(1000), None, Some(2000)])
    }

    fn queue_points(changes: &ParameterChanges, id: v3::ParamID) -> Vec<(i32, f64)> {
        (0..changes.len())
            .filter_map(|i| changes.queue(i))
            .find(|queue| queue.id() == id)
            .map(|queue| (0..queue.len()).map(|i| queue.get(i).unwrap()).collect())
            .unwrap_or_default()
    }

    #[test]
    fn notes_become_vst3_events_at_their_offsets() {
        let (list, changes) = lists();
        let events = [
            BlockEvent::note(40, 77, 64, 0.25, false),
            BlockEvent::note(12, 77, 64, 0.8, true),
        ];
        let dropped = translate_events(&events, 128, &map(), &list, &changes);
        assert_eq!(dropped, Dropped::default());
        assert_eq!(list.len(), 2);

        // Sorted by offset: the note-on at 12 comes first.
        let on = list.get(0).unwrap();
        assert_eq!(on.sampleOffset, 12);
        assert_eq!(on.r#type, v3::Event_::EventTypes_::kNoteOnEvent as u16);
        let note_on = unsafe { on.__field0.noteOn };
        assert_eq!(
            (note_on.pitch, note_on.noteId, note_on.channel),
            (64, 77, 0)
        );
        assert!((note_on.velocity - 0.8).abs() < 1e-6);

        let off = list.get(1).unwrap();
        assert_eq!(off.sampleOffset, 40);
        assert_eq!(off.r#type, v3::Event_::EventTypes_::kNoteOffEvent as u16);
        let note_off = unsafe { off.__field0.noteOff };
        assert_eq!((note_off.pitch, note_off.noteId), (64, 77));
        assert!((note_off.velocity - 0.25).abs() < 1e-6);
        assert!(changes.is_empty());
    }

    #[test]
    fn parameter_events_become_ordered_points_in_one_queue_per_parameter() {
        let (list, changes) = lists();
        let events = [
            BlockEvent::param(50, 0, 0.5),
            BlockEvent::param(10, 2, 0.25),
            BlockEvent::param(20, 0, 0.1),
            BlockEvent::param(5, 1, 0.9), // index 1 has no parameter: ignored
            BlockEvent::param(5, 99, 0.9), // unknown index: ignored
        ];
        translate_events(&events, 128, &map(), &list, &changes);
        assert_eq!(changes.len(), 2);
        assert_eq!(
            queue_points(&changes, 1000),
            vec![(20, 0.10000000149011612), (50, 0.5)]
        );
        assert_eq!(queue_points(&changes, 2000), vec![(10, 0.25)]);
        assert!(list.is_empty());
    }

    #[test]
    fn offsets_are_clamped_into_the_block() {
        let (list, changes) = lists();
        let events = [
            BlockEvent::note(500, 1, 60, 1.0, true),
            BlockEvent::param(900, 0, 0.5),
        ];
        translate_events(&events, 64, &map(), &list, &changes);
        assert_eq!(list.get(0).unwrap().sampleOffset, 63);
        assert_eq!(queue_points(&changes, 1000), vec![(63, 0.5)]);
    }

    #[test]
    fn modulation_and_choke_are_dropped_and_counted() {
        let (list, changes) = lists();
        let mut events = [
            BlockEvent::param_mod(0, 0, 0.5),
            BlockEvent::choke(3),
            BlockEvent::note(0, 1, 60, 1.0, true),
        ];
        events[0].kind = EVENT_PARAM_MOD;
        events[1].kind = EVENT_NOTE_CHOKE;
        let dropped = translate_events(&events, 64, &map(), &list, &changes);
        assert_eq!(
            dropped,
            Dropped {
                unsupported: 2,
                overflow: 0
            }
        );
        assert_eq!(list.len(), 1);
        assert!(changes.is_empty());
    }

    #[test]
    fn a_full_event_list_counts_overflow() {
        let list = EventList::with_capacity(1);
        let changes = ParameterChanges::new(1, 1);
        let events = [
            BlockEvent::note(0, 1, 60, 1.0, true),
            BlockEvent::note(1, 2, 61, 1.0, true),
            BlockEvent::param(0, 0, 0.1),
            BlockEvent::param(1, 2, 0.2), // second parameter: no queue slot left
        ];
        let dropped = translate_events(&events, 64, &map(), &list, &changes);
        assert_eq!(dropped.overflow, 2);
        assert_eq!(list.len(), 1);
    }

    #[test]
    fn process_context_follows_the_transport() {
        let transport = BlockTransport {
            tempo: 140.0,
            tempo_inc: 0.0,
            song_pos_beats: 6.5,
            song_pos_seconds: 2.0,
            bar_start_beats: 4.0,
            bar_number: 1,
            flags: TRANSPORT_FLAG_PLAYING,
            tsig_num: 3,
            tsig_den: 4,
            _reserved: [0; 20],
        };
        let mut context: v3::ProcessContext = unsafe { std::mem::zeroed() };
        fill_process_context(&transport, 48_000.0, 1234, &mut context);
        use v3::ProcessContext_::StatesAndFlags_ as flag;
        let state = context.state;
        for expected in [
            flag::kPlaying,
            flag::kTempoValid,
            flag::kTimeSigValid,
            flag::kProjectTimeMusicValid,
            flag::kBarPositionValid,
        ] {
            assert!(state & expected != 0, "flag {expected} missing");
        }
        assert_eq!(context.tempo, 140.0);
        assert_eq!(
            (context.timeSigNumerator, context.timeSigDenominator),
            (3, 4)
        );
        assert_eq!(context.projectTimeSamples, 96_000);
        assert_eq!(context.continousTimeSamples, 1234);
        assert_eq!(context.projectTimeMusic, 6.5);
        assert_eq!(context.barPositionMusic, 4.0);

        fill_process_context(&BlockTransport::default(), 48_000.0, 0, &mut context);
        assert_eq!(context.state & flag::kPlaying, 0);
    }
}
