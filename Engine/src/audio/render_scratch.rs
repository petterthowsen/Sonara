//! Preallocated scratch storage for the audio callback, so rendering and mixing don't allocate.

use std::collections::VecDeque;

use super::devices::container::ChainCursor;
use super::types::{ChannelId, MidiNote, NoteId, Tick, TrackId};

/// Most tick boundaries one buffer can cross at 8192 frames (one per frame, plus the start tick).
const MAX_TICK_EVENTS: usize = 8193;

/// Frames of per-frame tick rates preallocated for one buffer.
pub const MAX_RATE_FRAMES: usize = 8192;

/// Clip note events expected at a single tick before the list has to grow.
const MAX_NOTE_EVENTS: usize = 1024;

/// Channels expected before the per-buffer channel lists have to grow.
const MAX_CHANNELS: usize = 1024;

/// A clip note event collected for one tick. `key` includes the instance transpose.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClipNoteEvent {
    pub track_id: TrackId,
    pub clip_note_id: NoteId,
    pub key: MidiNote,
    pub velocity: f32,
    pub release: f32,
    pub is_on: bool,
}

/// Engine-wide scratch lists reused by `process_audio` and `mix_and_output` every buffer.
pub struct RenderScratch {
    /// (tick, frame_offset) boundaries crossed in the current buffer.
    pub tick_events: Vec<(Tick, usize)>,
    /// Ticks advanced per frame in the current buffer, from the tempo map.
    pub frame_tick_rates: Vec<f64>,
    /// Clip note events collected for the current tick.
    pub note_events: Vec<ClipNoteEvent>,
    /// Channel IDs for the current buffer, so mixing passes can look channels up by ID.
    pub channel_ids: Vec<ChannelId>,
    /// Channels whose device chain is waiting on a plugin that began a block, in park order.
    /// A channel is in it at most once, so it never grows past the channel count.
    pub parked: VecDeque<ChannelId>,
    /// Route targets ready in the current routing sweep.
    pub ready: Vec<ChannelId>,
}

impl Default for RenderScratch {
    fn default() -> Self {
        Self {
            tick_events: Vec::with_capacity(MAX_TICK_EVENTS),
            frame_tick_rates: Vec::with_capacity(MAX_RATE_FRAMES),
            note_events: Vec::with_capacity(MAX_NOTE_EVENTS),
            channel_ids: Vec::with_capacity(MAX_CHANNELS),
            parked: VecDeque::with_capacity(MAX_CHANNELS),
            ready: Vec::with_capacity(MAX_CHANNELS),
        }
    }
}

/// How this channel participates in the mix when any channel is soloed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SoloRole {
    /// Main output and every send stay in the mix.
    #[default]
    Full,
    /// Only the output and sends that lead to a soloed channel stay in the mix.
    SendOnly,
    /// This channel contributes no audio this buffer.
    Silent,
}

/// Per-channel mixing buffers and flags, reset by `mix_and_output` every buffer.
#[derive(Debug, Default)]
pub struct MixBuffers {
    /// Left channel audio before the fader, for pre-fader sends.
    pub pre_fader_left: Vec<f32>,
    /// Right channel audio before the fader, for pre-fader sends.
    pub pre_fader_right: Vec<f32>,
    /// `pre_fader_*` hold this buffer's audio.
    pub has_pre_fader_copy: bool,
    /// Routes and sends into this channel that have not mixed in yet this buffer.
    pub pending_inputs: usize,
    /// Another channel routes or sends here (or this is master), so this channel's devices run
    /// after its inputs have mixed in.
    pub is_route_target: bool,
    /// Processed and routed onward this buffer.
    pub done: bool,
    /// Solo participation for this buffer (`Full` when nothing is soloed).
    pub solo_role: SoloRole,
    /// Soloed audio flows through this channel: it is soloed, routes into a soloed channel
    /// (group solo), or is fed by such a channel. Everything it outputs stays in the mix.
    pub solo_up: bool,
    /// This channel leads to a soloed channel by routes or sends, so what feeds it stays.
    pub solo_down: bool,
    /// First device writes extra buses into child channels this buffer.
    pub has_aux_source: bool,
    /// Where this channel's device chain stopped when it parked at a plugin.
    pub cursor: ChainCursor,
    /// First device index of the chain the cursor runs on.
    pub chain_start: usize,
}

impl MixBuffers {
    /// Allocate buffers for up to `buffer_size` frames.
    pub fn new(buffer_size: usize) -> Self {
        let mut buffers = Self::default();
        buffers.resize(buffer_size);
        buffers
    }

    /// Resize every buffer to `buffer_size` frames.
    pub fn resize(&mut self, buffer_size: usize) {
        self.pre_fader_left.resize(buffer_size, 0.0);
        self.pre_fader_right.resize(buffer_size, 0.0);
    }
}
