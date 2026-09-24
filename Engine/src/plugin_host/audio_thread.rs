//! The host process's audio thread.
//!
//! It owns the plugin's [`PluginAudioProcessor`](clack_host::process::PluginAudioProcessor) and
//! the instance's shared block, waits on the engine's doorbell and processes exactly the block the
//! engine published. The main thread keeps the [`PluginInstance`](clack_host::prelude::PluginInstance)
//! for commands, GUI, timers and `params.flush`, so a slow GUI frame never delays audio.

use std::sync::atomic::Ordering;
use std::sync::mpsc::{self, RecvTimeoutError, Sender, SyncSender, TryRecvError};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use clack_host::events::event_types::{NoteOffEvent, NoteOnEvent, ParamValueEvent};
use clack_host::events::io::{EventBuffer, InputEvents, OutputEvents};
use clack_host::events::{Pckn, UnknownEvent};
use clack_host::prelude::*;
use clack_host::process::PluginAudioProcessor as PluginAudioProcessorEnum;
use clack_host::process::StoppedPluginAudioProcessor;
use clack_host::utils::Cookie;
use tracing::{info, warn};

use crate::audio::ipc::{
    futex, BlockEvent, HostSharedMemory, SharedMemory, EVENT_NOTE_OFF, EVENT_NOTE_ON, EVENT_PARAM,
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

/// Commands from the host's main thread to its audio thread.
pub enum HostAudioCommand {
    /// Hand over a freshly activated processor and the instance's shared block.
    SetProcessor {
        processor: PluginAudioProcessorEnum<SubprocessHost>,
        memory: Arc<SharedMemory>,
        param_map: Option<Arc<ParamMap>>,
        reply: SyncSender<Result<(), String>>,
    },
    /// Take the processor back so the main thread can deactivate the plugin.
    TakeProcessor {
        reply: SyncSender<Option<StoppedPluginAudioProcessor<SubprocessHost>>>,
    },
    /// Publish a rebuilt parameter map (after `GetParameterInfo` or a rescan).
    SetParamMap(Arc<ParamMap>),
    /// A parameter change from the engine: applied at offset 0 of the next block.
    SetParameter {
        clap_id: ClapId,
        value: f64,
    },
    /// Clear the plugin's processing state and any queued events.
    Reset,
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
        futex::wake(self.doorbell.doorbell(), i32::MAX);
    }

    /// Hand over a processor and wait until the audio thread holds it.
    pub fn set_processor(
        &self,
        processor: PluginAudioProcessorEnum<SubprocessHost>,
        memory: Arc<SharedMemory>,
        param_map: Option<Arc<ParamMap>>,
    ) -> Result<(), String> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.send(HostAudioCommand::SetProcessor {
            processor,
            memory,
            param_map,
            reply: reply_tx,
        });
        reply_rx
            .recv_timeout(HANDOFF_TIMEOUT)
            .map_err(|e| format!("Audio thread didn't take the processor: {}", e))?
    }

    /// Take the processor back, blocking until the audio thread has released it.
    pub fn take_processor(&self) -> Option<StoppedPluginAudioProcessor<SubprocessHost>> {
        let (reply_tx, reply_rx) = mpsc::sync_channel(1);
        self.send(HostAudioCommand::TakeProcessor { reply: reply_tx });
        match reply_rx.recv_timeout(HANDOFF_TIMEOUT) {
            Ok(processor) => processor,
            Err(e) => {
                warn!("Audio thread didn't return the processor: {}", e);
                None
            }
        }
    }

    pub fn set_param_map(&self, param_map: Arc<ParamMap>) {
        self.send(HostAudioCommand::SetParamMap(param_map));
    }

    pub fn set_parameter(&self, clap_id: ClapId, value: f64) {
        self.send(HostAudioCommand::SetParameter { clap_id, value });
    }

    pub fn reset(&self) {
        self.send(HostAudioCommand::Reset);
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

/// State owned by the audio thread.
struct AudioWorker {
    doorbell: Arc<HostSharedMemory>,
    processor: Option<PluginAudioProcessorEnum<SubprocessHost>>,
    memory: Option<Arc<SharedMemory>>,
    param_map: Arc<ParamMap>,
    /// Parsed input events for the current block, sorted before use.
    events: Vec<OwnedEvent>,
    input_events: EventBuffer,
    output_events: EventBuffer,
    /// Parameter changes queued by the main thread, applied at offset 0 of the next block.
    queued_params: Vec<(ClapId, f64)>,
    reset_requested: bool,
    steady: u64,
}

impl AudioWorker {
    fn new(doorbell: Arc<HostSharedMemory>) -> Self {
        Self {
            doorbell,
            processor: None,
            memory: None,
            param_map: Arc::new(ParamMap::default()),
            events: Vec::with_capacity(INPUT_EVENT_CAPACITY),
            input_events: EventBuffer::with_capacity(INPUT_EVENT_CAPACITY),
            output_events: EventBuffer::with_capacity(64),
            queued_params: Vec::with_capacity(64),
            reset_requested: false,
            steady: 0,
        }
    }

    /// Apply one command. Returns false when the thread should exit.
    fn apply(&mut self, command: HostAudioCommand) -> bool {
        match command {
            HostAudioCommand::SetProcessor {
                processor,
                memory,
                param_map,
                reply,
            } => {
                self.finish_pending();
                if self.processor.is_some() {
                    let _ =
                        reply.send(Err("The audio thread already holds a processor".to_string()));
                    return true;
                }
                if let Some(param_map) = param_map {
                    self.param_map = param_map;
                }
                self.processor = Some(processor);
                self.memory = Some(memory);
                self.steady = 0;
                let _ = reply.send(Ok(()));
            }
            HostAudioCommand::TakeProcessor { reply } => {
                self.finish_pending();
                let stopped = self.processor.take().map(|processor| match processor {
                    PluginAudioProcessorEnum::Started(started) => started.stop_processing(),
                    PluginAudioProcessorEnum::Stopped(stopped) => stopped,
                });
                self.memory = None;
                let _ = reply.send(stopped);
            }
            HostAudioCommand::SetParamMap(param_map) => self.param_map = param_map,
            HostAudioCommand::SetParameter { clap_id, value } => {
                if self.queued_params.len() < INPUT_EVENT_CAPACITY {
                    self.queued_params.push((clap_id, value));
                }
            }
            HostAudioCommand::Reset => {
                self.reset_requested = true;
                self.queued_params.clear();
            }
            HostAudioCommand::Shutdown => return false,
        }
        true
    }

    /// Answer a request the engine may still be waiting on, so taking the processor or replacing
    /// it never leaves the engine spinning until its deadline.
    fn finish_pending(&mut self) {
        if self.processor.is_none() {
            return;
        }
        if let Some(memory) = self.memory.clone() {
            self.process_request(&memory);
        }
    }

    /// Wait for the next request and process it. Returns when the thread should exit.
    fn run(&mut self, rx: &mpsc::Receiver<HostAudioCommand>) {
        loop {
            // Drain commands first: they are cheap and may change the processor.
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

            let Some(memory) = self.memory.clone() else {
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
            };

            let control = memory.control();
            if control.request_seq.load(Ordering::Acquire)
                != control.done_seq.load(Ordering::Acquire)
            {
                self.process_request(&memory);
                continue;
            }

            // Idle: wait for the doorbell (engine request or a main-thread command).
            let word = self.doorbell.doorbell().load(Ordering::Acquire);
            futex::wait(self.doorbell.doorbell(), word, Some(IDLE_WAIT));
        }
    }

    /// Process the block the engine published in `memory`.
    fn process_request(&mut self, memory: &SharedMemory) {
        let layout = *memory.layout();
        let control = memory.control();
        let seq = control.request_seq.load(Ordering::Acquire);
        if seq == control.done_seq.load(Ordering::Acquire) {
            return;
        }

        let frames = (control.input_frames.load(Ordering::Acquire) as usize).min(layout.max_frames);
        let usable = matches!(self.processor, Some(PluginAudioProcessorEnum::Started(_)));

        if !usable {
            control.output_frames.store(0, Ordering::Relaxed);
            control.output_event_count.store(0, Ordering::Relaxed);
            control.done_seq.store(seq, Ordering::Release);
            self.doorbell.ring();
            return;
        }

        let Some(PluginAudioProcessorEnum::Started(started)) = self.processor.as_mut() else {
            unreachable!("checked above");
        };

        if self.reset_requested {
            self.reset_requested = false;
            started.reset();
            self.events.clear();
            self.queued_params.clear();
        }

        // Parse the engine's input events, then the main thread's queued parameter changes.
        self.events.clear();
        let count =
            (control.input_event_count.load(Ordering::Acquire) as usize).min(layout.max_events);
        {
            let events = memory.input_events();
            for event in &events[..count] {
                let pckn = Pckn::new(0u16, 0u16, event.note as u16, event.note as u32);
                match event.kind {
                    EVENT_NOTE_ON => self.events.push(OwnedEvent::NoteOn(
                        event.sample_offset,
                        NoteOnEvent::new(event.sample_offset, pckn, event.value as f64),
                    )),
                    EVENT_NOTE_OFF => self.events.push(OwnedEvent::NoteOff(
                        event.sample_offset,
                        NoteOffEvent::new(event.sample_offset, pckn, event.value as f64),
                    )),
                    EVENT_PARAM => {
                        if let Some(entry) = self.param_map.get(event.id) {
                            self.events.push(OwnedEvent::Param(
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
        for (clap_id, value) in self.queued_params.drain(..) {
            self.events.push(OwnedEvent::Param(
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
        self.events.sort_unstable_by_key(OwnedEvent::time);
        self.input_events.clear();
        for event in &self.events {
            self.input_events.push(event.as_unknown());
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

        self.output_events.clear();
        let result = {
            let mut output_events = OutputEvents::from_buffer(&mut self.output_events);
            started.process(
                &input_audio,
                &mut output_audio,
                &InputEvents::from_buffer(&self.input_events),
                &mut output_events,
                Some(self.steady),
                None,
            )
        };
        self.steady = self.steady.wrapping_add(frames as u64);

        match result {
            Ok(_) => control.status.store(0, Ordering::Relaxed),
            Err(e) => {
                warn!("Plugin processing error: {:?}", e);
                control.status.store(1, Ordering::Relaxed);
            }
        }

        // Report the plugin's own parameter changes back through the block.
        let mut written = 0usize;
        {
            let out_events = memory.output_events();
            for event in self.output_events.iter() {
                if written >= out_events.len() {
                    break;
                }
                let Some(param_event) = event.as_event::<ParamValueEvent>() else {
                    continue;
                };
                let Some(clap_id) = param_event.param_id() else {
                    continue;
                };
                let Some((index, entry)) = self.param_map.find(clap_id) else {
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

        control.done_seq.store(seq, Ordering::Release);
        self.doorbell.ring();
    }
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
