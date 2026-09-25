//! The host process's audio thread.
//!
//! It owns every instance's [`PluginAudioProcessor`](clack_host::process::PluginAudioProcessor)
//! and shared block, waits on the host's doorbell and processes exactly the blocks the engine
//! published. The main thread keeps each [`PluginInstance`](clack_host::prelude::PluginInstance)
//! for commands, GUI, timers and `params.flush`, so a slow GUI frame never delays audio.
//!
//! A host process can hold several instances (hosting modes, Phase 5). They share this one
//! thread and the one doorbell; each has its own block and sequence numbers, so the thread
//! processes whichever instances have a request pending.

use std::sync::atomic::Ordering;
use std::sync::mpsc::{self, RecvTimeoutError, Sender, SyncSender, TryRecvError};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use clack_host::events::event_types::{NoteOffEvent, NoteOnEvent, ParamValueEvent};
use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};
use clack_host::events::{Pckn, UnknownEvent};
use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use clack_host::process::StoppedPluginAudioProcessor;
use clack_host::utils::Cookie;
use tracing::{info, warn};

use crate::audio::ipc::{
    futex, BlockEvent, HostSharedMemory, InstanceId, SharedMemory, EVENT_NOTE_OFF, EVENT_NOTE_ON,
    EVENT_PARAM,
};
use crate::plugin_host::host::SubprocessHost;
use crate::plugin_host::state::ParamMap;

/// How long the audio thread blocks on the doorbell while idle. Commands ring the doorbell too,
/// so this is only a safety net.
const IDLE_WAIT: Duration = Duration::from_millis(2);

/// Preallocated events per direction before extra ones are dropped.
const INPUT_EVENT_CAPACITY: usize = 256;

/// How long `set_processor` / `take_processor` wait for the audio thread to answer.
const HANDOFF_TIMEOUT: Duration = Duration::from_secs(2);

/// Commands from the host's main thread to its audio thread, each for one instance.
pub enum HostAudioCommand {
    /// Hand over a freshly activated processor and the instance's shared block.
    SetProcessor {
        instance_id: InstanceId,
        processor: PluginAudioProcessorEnum<SubprocessHost>,
        memory: Arc<SharedMemory>,
        param_map: Option<Arc<ParamMap>>,
        /// The instance's log span, entered when the audio thread logs about it.
        span: tracing::Span,
        reply: SyncSender<Result<(), String>>,
    },
    /// Take the processor back so the main thread can deactivate the plugin.
    TakeProcessor {
        instance_id: InstanceId,
        reply: SyncSender<Option<StoppedPluginAudioProcessor<SubprocessHost>>>,
    },
    /// Publish a rebuilt parameter map (after `GetParameterInfo` or a rescan).
    SetParamMap {
        instance_id: InstanceId,
        param_map: Arc<ParamMap>,
    },
    /// A parameter change from the engine: applied at offset 0 of the next block.
    SetParameter {
        instance_id: InstanceId,
        clap_id: ClapId,
        value: f64,
    },
    /// Clear the plugin's processing state and any queued events.
    Reset {
        instance_id: InstanceId,
    },
    /// Forget an instance that was unloaded. Its processor must have been taken back first.
    RemoveInstance {
        instance_id: InstanceId,
    },
    Shutdown,
}

/// Main-thread handle to the audio thread.
#[derive(Clone)]
pub struct AudioThreadHandle {
    tx: Sender<HostAudioCommand>,
    doorbell: Arc<HostSharedMemory>,
}

impl AudioThreadHandle {
    /// Send a command and wake the audio thread.
    pub fn send(&self, command: HostAudioCommand) {
        if self.tx.send(command).is_err() {
            warn!("Plugin host audio thread has exited");
            return;
        }
        self.doorbell.ring();
    }

    /// Hand over an instance's processor and wait until the audio thread holds it.
    pub fn set_processor(
        &self,
        instance_id: InstanceId,
        processor: PluginAudioProcessorEnum<SubprocessHost>,
        memory: Arc<SharedMemory>,
        param_map: Option<Arc<ParamMap>>,
        span: tracing::Span,
    ) -> Result<(), String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.send(HostAudioCommand::SetProcessor {
            instance_id,
            processor,
            memory,
            param_map,
            span,
            reply: reply_tx,
        });
        reply_rx
            .recv_timeout(HANDOFF_TIMEOUT)
            .map_err(|e| format!("Audio thread didn't take the processor: {}", e))?
    }

    /// Take an instance's processor back, blocking until the audio thread has released it.
    pub fn take_processor(
        &self,
        instance_id: InstanceId,
    ) -> Option<StoppedPluginAudioProcessor<SubprocessHost>> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.send(HostAudioCommand::TakeProcessor {
            instance_id,
            reply: reply_tx,
        });
        match reply_rx.recv_timeout(HANDOFF_TIMEOUT) {
            Ok(processor) => processor,
            Err(e) => {
                warn!("Audio thread didn't return the processor: {}", e);
                None
            }
        }
    }

    pub fn set_param_map(&self, instance_id: InstanceId, param_map: Arc<ParamMap>) {
        self.send(HostAudioCommand::SetParamMap {
            instance_id,
            param_map,
        });
    }

    pub fn set_parameter(&self, instance_id: InstanceId, clap_id: ClapId, value: f64) {
        self.send(HostAudioCommand::SetParameter {
            instance_id,
            clap_id,
            value,
        });
    }

    pub fn reset(&self, instance_id: InstanceId) {
        self.send(HostAudioCommand::Reset { instance_id });
    }

    pub fn remove_instance(&self, instance_id: InstanceId) {
        self.send(HostAudioCommand::RemoveInstance { instance_id });
    }

    pub fn shutdown(&self) {
        self.send(HostAudioCommand::Shutdown);
    }
}

/// One CLAP event parsed from the shared block, so the events can be sorted by sample offset
/// before they are handed to the plugin (CLAP requires a time-ordered event stream).
enum OwnedEvent {
    NoteOn(u32, NoteOnEvent),
    NoteOff(u32, NoteOffEvent),
    Param(u32, ParamValueEvent),
}

impl OwnedEvent {
    fn time(&self) -> u32 {
        match self {
            OwnedEvent::NoteOn(time, _)
            | OwnedEvent::NoteOff(time, _)
            | OwnedEvent::Param(time, _) => *time,
        }
    }

    fn as_unknown(&self) -> &UnknownEvent {
        match self {
            OwnedEvent::NoteOn(_, event) => event.as_unknown(),
            OwnedEvent::NoteOff(_, event) => event.as_unknown(),
            OwnedEvent::Param(_, event) => event.as_unknown(),
        }
    }
}

/// One instance's state on the audio thread.
struct InstanceSlot {
    instance_id: InstanceId,
    processor: Option<PluginAudioProcessorEnum<SubprocessHost>>,
    memory: Option<Arc<SharedMemory>>,
    param_map: Arc<ParamMap>,
    /// Parameter changes queued by the main thread, applied at offset 0 of the next block.
    queued_params: Vec<(ClapId, f64)>,
    reset_requested: bool,
    steady: u64,
    /// Log span naming the instance; entered only on the (rare) paths that log.
    span: tracing::Span,
}

impl InstanceSlot {
    fn new(instance_id: InstanceId) -> Self {
        Self {
            instance_id,
            processor: None,
            memory: None,
            param_map: Arc::new(ParamMap::default()),
            queued_params: Vec::with_capacity(64),
            reset_requested: false,
            steady: 0,
            span: tracing::Span::none(),
        }
    }

    /// True when the engine published a block this slot hasn't finished.
    fn has_request(&self) -> bool {
        self.memory.as_ref().is_some_and(|memory| {
            let control = memory.control();
            control.request_seq.load(Ordering::Acquire) != control.done_seq.load(Ordering::Acquire)
        })
    }
}

/// Buffers shared by every instance's `process()` call. Preallocated once per thread.
struct Scratch {
    /// Parsed input events for the current block, sorted before use.
    events: Vec<OwnedEvent>,
    input_events: EventBuffer,
    output_events: EventBuffer,
}

/// State owned by the audio thread.
struct AudioWorker {
    doorbell: Arc<HostSharedMemory>,
    slots: Vec<InstanceSlot>,
    scratch: Scratch,
}

impl AudioWorker {
    fn new(doorbell: Arc<HostSharedMemory>) -> Self {
        Self {
            doorbell,
            slots: Vec::new(),
            scratch: Scratch {
                events: Vec::with_capacity(INPUT_EVENT_CAPACITY),
                input_events: EventBuffer::with_capacity(INPUT_EVENT_CAPACITY),
                output_events: EventBuffer::with_capacity(64),
            },
        }
    }

    /// Index of the slot for `instance_id`, created on first use (a parameter map can arrive
    /// before the processor does).
    fn slot_index(&mut self, instance_id: InstanceId) -> usize {
        match self
            .slots
            .iter()
            .position(|slot| slot.instance_id == instance_id)
        {
            Some(index) => index,
            None => {
                self.slots.push(InstanceSlot::new(instance_id));
                self.slots.len() - 1
            }
        }
    }

    fn slot(&mut self, instance_id: InstanceId) -> &mut InstanceSlot {
        let index = self.slot_index(instance_id);
        &mut self.slots[index]
    }

    /// Apply one command. Returns false when the thread should exit.
    fn apply(&mut self, command: HostAudioCommand) -> bool {
        match command {
            HostAudioCommand::SetProcessor {
                instance_id,
                processor,
                memory,
                param_map,
                span,
                reply,
            } => {
                let index = self.slot_index(instance_id);
                let slot = &mut self.slots[index];
                finish_pending(slot, &mut self.scratch, &self.doorbell);
                if slot.processor.is_some() {
                    let _ = reply.send(Err(format!(
                        "The audio thread already holds a processor for instance {}",
                        instance_id
                    )));
                    return true;
                }
                if let Some(param_map) = param_map {
                    slot.param_map = param_map;
                }
                slot.processor = Some(processor);
                slot.memory = Some(memory);
                slot.span = span;
                slot.steady = 0;
                let _ = reply.send(Ok(()));
            }
            HostAudioCommand::TakeProcessor { instance_id, reply } => {
                let Some(slot) = self
                    .slots
                    .iter_mut()
                    .find(|slot| slot.instance_id == instance_id)
                else {
                    let _ = reply.send(None);
                    return true;
                };
                finish_pending(slot, &mut self.scratch, &self.doorbell);
                let stopped = slot.processor.take().map(|processor| match processor {
                    PluginAudioProcessorEnum::Started(started) => started.stop_processing(),
                    PluginAudioProcessorEnum::Stopped(stopped) => stopped,
                });
                slot.memory = None;
                let _ = reply.send(stopped);
            }
            HostAudioCommand::SetParamMap {
                instance_id,
                param_map,
            } => self.slot(instance_id).param_map = param_map,
            HostAudioCommand::SetParameter {
                instance_id,
                clap_id,
                value,
            } => {
                let slot = self.slot(instance_id);
                if slot.queued_params.len() < INPUT_EVENT_CAPACITY {
                    slot.queued_params.push((clap_id, value));
                }
            }
            HostAudioCommand::Reset { instance_id } => {
                let slot = self.slot(instance_id);
                slot.reset_requested = true;
                slot.queued_params.clear();
            }
            HostAudioCommand::RemoveInstance { instance_id } => {
                if let Some(index) = self
                    .slots
                    .iter()
                    .position(|slot| slot.instance_id == instance_id)
                {
                    finish_pending(&mut self.slots[index], &mut self.scratch, &self.doorbell);
                    self.slots.swap_remove(index);
                }
            }
            HostAudioCommand::Shutdown => return false,
        }
        true
    }

    /// Wait for requests and process them. Returns when the thread should exit.
    fn run(&mut self, rx: &mpsc::Receiver<HostAudioCommand>) {
        loop {
            // Read the doorbell before looking for work: a request published after the checks
            // below bumps it, so the wait at the end returns at once instead of sleeping.
            let word = self.doorbell.doorbell().load(Ordering::Acquire);

            // Drain commands first: they are cheap and may change the processors.
            loop {
                match rx.try_recv() {
                    Ok(command) => {
                        if !self.apply(command) {
                            return;
                        }
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => return,
                }
            }

            let mut processed = false;
            for slot in &mut self.slots {
                if slot.has_request() {
                    process_request(slot, &mut self.scratch, &self.doorbell);
                    processed = true;
                }
            }
            if processed {
                continue;
            }

            if self.slots.iter().all(|slot| slot.memory.is_none()) {
                // No processor yet: block on commands.
                match rx.recv_timeout(IDLE_WAIT) {
                    Ok(command) => {
                        if !self.apply(command) {
                            return;
                        }
                    }
                    Err(RecvTimeoutError::Timeout) => {}
                    Err(RecvTimeoutError::Disconnected) => return,
                }
                continue;
            }

            // Idle: wait for the doorbell (engine request or a main-thread command).
            futex::wait(self.doorbell.doorbell(), word, Some(IDLE_WAIT));
        }
    }
}

/// Answer a request the engine may still be waiting on, so taking the processor or replacing
/// it never leaves the engine spinning until its deadline.
fn finish_pending(slot: &mut InstanceSlot, scratch: &mut Scratch, doorbell: &HostSharedMemory) {
    if slot.processor.is_some() && slot.has_request() {
        process_request(slot, scratch, doorbell);
    }
}

/// Process the block the engine published in `slot`'s shared memory.
fn process_request(slot: &mut InstanceSlot, scratch: &mut Scratch, doorbell: &HostSharedMemory) {
    let Some(memory) = slot.memory.clone() else {
        return;
    };
    let layout = *memory.layout();
    let control = memory.control();
    let seq = control.request_seq.load(Ordering::Acquire);
    if seq == control.done_seq.load(Ordering::Acquire) {
        return;
    }

    let frames = (control.input_frames.load(Ordering::Acquire) as usize).min(layout.max_frames);

    let Some(PluginAudioProcessorEnum::Started(started)) = slot.processor.as_mut() else {
        control.output_frames.store(0, Ordering::Relaxed);
        control.output_event_count.store(0, Ordering::Relaxed);
        control.process_ns.store(0, Ordering::Relaxed);
        control.done_seq.store(seq, Ordering::Release);
        doorbell.ring();
        return;
    };

    if slot.reset_requested {
        slot.reset_requested = false;
        started.reset();
        scratch.events.clear();
        slot.queued_params.clear();
    }

    // Parse the engine's input events, then the main thread's queued parameter changes.
    scratch.events.clear();
    let count = (control.input_event_count.load(Ordering::Acquire) as usize).min(layout.max_events);
    {
        let events = memory.input_events();
        for event in &events[..count] {
            let pckn = Pckn::new(0u16, 0u16, event.note as u16, event.note as u32);
            match event.kind {
                EVENT_NOTE_ON => scratch.events.push(OwnedEvent::NoteOn(
                    event.sample_offset,
                    NoteOnEvent::new(event.sample_offset, pckn, event.value as f64),
                )),
                EVENT_NOTE_OFF => scratch.events.push(OwnedEvent::NoteOff(
                    event.sample_offset,
                    NoteOffEvent::new(event.sample_offset, pckn, event.value as f64),
                )),
                EVENT_PARAM => {
                    if let Some(entry) = slot.param_map.get(event.id) {
                        scratch.events.push(OwnedEvent::Param(
                            event.sample_offset,
                            ParamValueEvent::new(
                                event.sample_offset,
                                entry.clap_id,
                                pckn,
                                entry.denormalize(event.value),
                                Cookie::empty(),
                            ),
                        ));
                    }
                }
                _ => {}
            }
        }
    }
    for (clap_id, value) in slot.queued_params.drain(..) {
        scratch.events.push(OwnedEvent::Param(
            0,
            ParamValueEvent::new(
                0,
                clap_id,
                Pckn::new(0u16, 0u16, 0u16, 0u32),
                value,
                Cookie::empty(),
            ),
        ));
    }
    // CLAP requires a time-ordered event stream.
    scratch.events.sort_unstable_by_key(OwnedEvent::time);
    scratch.input_events.clear();
    for event in &scratch.events {
        scratch.input_events.push(event.as_unknown());
    }

    // Planar input planes; the engine wrote them before publishing the request.
    let mut input_ports = AudioPorts::with_capacity(layout.max_channels, 1);
    let input_plane = memory.input();
    let (left, rest) = input_plane.split_at_mut(layout.max_frames);
    let right = if layout.max_channels >= 2 {
        &mut rest[..layout.max_frames]
    } else {
        &mut rest[..0]
    };
    let mut input_channels = Vec::with_capacity(layout.max_channels);
    input_channels.push(InputChannel::constant(&mut left[..frames]));
    if layout.max_channels >= 2 {
        input_channels.push(InputChannel::constant(&mut right[..frames]));
    }
    let input_audio = input_ports.with_input_buffers([AudioPortBuffer {
        latency: 0,
        channels: AudioPortBufferType::f32_input_only(input_channels.into_iter()),
    }]);

    // Planar output planes; the plugin writes straight into shared memory.
    let mut output_ports = AudioPorts::with_capacity(layout.max_channels, 1);
    let output_plane = memory.output();
    let (out_left, out_rest) = output_plane.split_at_mut(layout.max_frames);
    let out_right = if layout.max_channels >= 2 {
        &mut out_rest[..layout.max_frames]
    } else {
        &mut out_rest[..0]
    };
    let mut output_channels: Vec<&mut [f32]> = Vec::with_capacity(layout.max_channels);
    output_channels.push(&mut out_left[..frames]);
    if layout.max_channels >= 2 {
        output_channels.push(&mut out_right[..frames]);
    }
    let mut output_audio = output_ports.with_output_buffers([AudioPortBuffer {
        latency: 0,
        channels: AudioPortBufferType::f32_output_only(output_channels.into_iter()),
    }]);

    scratch.output_events.clear();
    let started_at = Instant::now();
    let result = {
        let mut output_events = OutputEvents::from_buffer(&mut scratch.output_events);
        started.process(
            &input_audio,
            &mut output_audio,
            &InputEvents::from_buffer(&scratch.input_events),
            &mut output_events,
            Some(slot.steady),
            None,
        )
    };
    let process_ns = started_at.elapsed().as_nanos().min(u32::MAX as u128) as u32;
    slot.steady = slot.steady.wrapping_add(frames as u64);

    match result {
        Ok(_) => control.status.store(0, Ordering::Relaxed),
        Err(e) => {
            let _entered = slot.span.enter();
            warn!(
                "Plugin instance {} processing error: {:?}",
                slot.instance_id, e
            );
            control.status.store(1, Ordering::Relaxed);
        }
    }

    // Report the plugin's own parameter changes back through the block.
    let mut written = 0usize;
    {
        let out_events = memory.output_events();
        for event in scratch.output_events.iter() {
            if written >= out_events.len() {
                break;
            }
            let Some(param_event) = event.as_event::<ParamValueEvent>() else {
                continue;
            };
            let Some(clap_id) = param_event.param_id() else {
                continue;
            };
            let Some((index, entry)) = slot.param_map.find(clap_id) else {
                continue;
            };
            out_events[written] = BlockEvent::param(
                param_event.time(),
                index,
                entry.normalize(param_event.value()),
            );
            written += 1;
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
    doorbell.ring();
}

/// Spawn the audio thread for one host process.
pub fn spawn(doorbell: Arc<HostSharedMemory>) -> std::io::Result<AudioThreadHandle> {
    let (tx, rx) = mpsc::channel::<HostAudioCommand>();
    let handle = AudioThreadHandle {
        tx,
        doorbell: Arc::clone(&doorbell),
    };
    thread::Builder::new()
        .name("plugin-audio".to_string())
        .spawn(move || {
            let mut worker = AudioWorker::new(doorbell);
            info!("Plugin audio thread ready");
            worker.run(&rx);
            info!("Plugin audio thread exiting");
        })?;
    Ok(handle)
}
