/// Value kind for setting device parameters
#[derive(Debug, Clone, Copy)]
pub enum ParamSetValue {
    /// Normalized value 0.0..1.0
    Normalized(f32),
    /// Discrete index for bool/enum (0/1 for bool, 0..N-1 for enum)
    Index(i32),
}

/// MIDI note number (0-127)
pub type MidiNote = u8;

/// Position in ticks
pub type Tick = i64;

/// Channel ID
///
/// ID Allocation Scheme:
/// - 0: Null/no output (reserved, channels routing to 0 won't output anywhere)
/// - 1: Master channel (always present, created by Godot on project init, routes to ID 1000)
/// - 2-999: User mixer channels (created dynamically by user)
/// - 1000+: Stereo output pairs on the selected output device (`HARDWARE_OUTPUT_BASE`):
///   1000 = outputs 1/2, 1001 = 3/4, and so on. A pair the device doesn't have plays on 1/2.
pub type ChannelId = usize;

/// First hardware output ID: outputs 1/2 of the selected device.
pub const HARDWARE_OUTPUT_BASE: ChannelId = 1000;

/// Track ID
pub type TrackId = usize;

/// Unique identifier for scheduled notes
pub type NoteId = u64;

/// Unique identifier for clips (GUID from Godot)
pub type ClipId = String;

/// Unique identifier for clip instances (GUID from Godot)
pub type ClipInstanceId = String;
