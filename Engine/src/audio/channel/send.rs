use super::fader_gain;
use crate::audio::types::ChannelId;

/// Send routing configuration
#[derive(Debug, Clone)]
pub struct Send {
    pub target_channel_id: ChannelId, // Must be a BUS channel
    pub amount_db: f32,               // Send level in dB (-60.0 to +12.0)
    pub pre_fader: bool, // If true, send before channel fader; if false, send after fader
    pub muted: bool,     // Mute this send
}

impl Send {
    /// False at the bottom of the range (-60 dB, shown as -inf): the send carries nothing, so the
    /// mixer's ordering and the latency plan leave it out, and a route may close a loop through it
    /// (Godot then won't let it be turned back up).
    pub fn is_live(&self) -> bool {
        fader_gain(self.amount_db) > 0.0
    }
}
