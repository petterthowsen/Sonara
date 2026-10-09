use crate::audio::types::ChannelId;

/// Send routing configuration
#[derive(Debug, Clone)]
pub struct Send {
    pub target_channel_id: ChannelId, // Must be a BUS channel
    pub amount_db: f32,               // Send level in dB (-60.0 to +12.0)
    pub pre_fader: bool, // If true, send before channel fader; if false, send after fader
    pub muted: bool,     // Mute this send
}
