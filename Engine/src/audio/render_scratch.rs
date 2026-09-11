//! Preallocated scratch storage for the audio callback, so rendering and mixing don't allocate.

use super::types::{ChannelId, MidiNote, MidiVelocity, Tick, TrackId};

/// Most tick boundaries one buffer can cross at 8192 frames (one per frame, plus the start tick).
const MAX_TICK_EVENTS: usize = 8193;

/// Clip note events expected at a single tick before the list has to grow.
const MAX_NOTE_EVENTS: usize = 1024;

/// Channels expected before the per-buffer channel lists have to grow.
const MAX_CHANNELS: usize = 1024;

/// A clip note event collected for one tick: (track, note, velocity, is_note_on).
pub type NoteEvent = (TrackId, MidiNote, MidiVelocity, bool);

/// Engine-wide scratch lists reused by `process_audio` and `mix_and_output` every buffer.
pub struct RenderScratch {
    /// (tick, frame_offset) boundaries crossed in the current buffer.
    pub tick_events: Vec<(Tick, usize)>,
    /// Clip note events collected for the current tick.
    pub note_events: Vec<NoteEvent>,
    /// Channel IDs for the current buffer, so mixing passes can look channels up by ID.
    pub channel_ids: Vec<ChannelId>,
    /// (source, destination) routes collected in the current routing pass.
    pub mix_ops: Vec<(ChannelId, ChannelId)>,
}

impl Default for RenderScratch {
    fn default() -> Self {
        Self {
            tick_events: Vec::with_capacity(MAX_TICK_EVENTS),
            note_events: Vec::with_capacity(MAX_NOTE_EVENTS),
            channel_ids: Vec::with_capacity(MAX_CHANNELS),
            mix_ops: Vec::with_capacity(MAX_CHANNELS),
        }
    }
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
    /// Left channel sum of sends arriving at this channel.
    pub send_left: Vec<f32>,
    /// Right channel sum of sends arriving at this channel.
    pub send_right: Vec<f32>,
    /// `send_*` hold this buffer's sends.
    pub has_send_input: bool,
    /// Left channel snapshot taken when this channel is routed in a pass.
    pub route_left: Vec<f32>,
    /// Right channel snapshot taken when this channel is routed in a pass.
    pub route_right: Vec<f32>,
    /// Another channel routes or sends here, so this channel's devices run after routing.
    pub is_route_target: bool,
    /// Received sends and must run its devices before routing onward.
    pub pending_bus: bool,
    /// Received routed audio in the current routing pass.
    pub bus_destination: bool,
    /// Already routed onward (master is always marked).
    pub routed: bool,
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
        for buffer in [
            &mut self.pre_fader_left,
            &mut self.pre_fader_right,
            &mut self.send_left,
            &mut self.send_right,
            &mut self.route_left,
            &mut self.route_right,
        ] {
            buffer.resize(buffer_size, 0.0);
        }
    }
}
