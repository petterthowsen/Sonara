/// MIDI event types and structures for sample-accurate MIDI processing.
use crossbeam::queue::SegQueue;
use std::sync::Arc;
use std::time::Instant;

/// MIDI message type constants (match Godot)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MidiMessageType {
    NoteOff = 8,
    NoteOn = 9,
    Aftertouch = 10,
    ControlChange = 11,
    ProgramChange = 12,
    ChannelPressure = 13,
    PitchBend = 14,
}

impl MidiMessageType {
    /// Convert from u8 value (from OSC message)
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            8 => Some(MidiMessageType::NoteOff),
            9 => Some(MidiMessageType::NoteOn),
            10 => Some(MidiMessageType::Aftertouch),
            11 => Some(MidiMessageType::ControlChange),
            12 => Some(MidiMessageType::ProgramChange),
            13 => Some(MidiMessageType::ChannelPressure),
            14 => Some(MidiMessageType::PitchBend),
            _ => None,
        }
    }
}

/// Live MIDI event, placed within an audio buffer by its arrival time
#[derive(Debug, Clone)]
pub struct MidiEvent {
    pub message_type: MidiMessageType,
    pub midi_channel: u8,     // 0-15
    pub note: u8,             // 0-127 (or data1)
    pub velocity: u8,         // 0-127 (or data2)
    pub received_at: Instant, // When the engine received the event
    pub frame_offset: usize,  // Sample offset within current buffer
}

impl MidiEvent {
    /// Create a note-on event
    pub fn note_on(midi_channel: u8, note: u8, velocity: u8, received_at: Instant) -> Self {
        Self {
            message_type: MidiMessageType::NoteOn,
            midi_channel,
            note,
            velocity,
            received_at,
            frame_offset: 0,
        }
    }

    /// Create a note-off event
    pub fn note_off(midi_channel: u8, note: u8, received_at: Instant) -> Self {
        Self {
            message_type: MidiMessageType::NoteOff,
            midi_channel,
            note,
            velocity: 0,
            received_at,
            frame_offset: 0,
        }
    }

    /// Create a control change event
    pub fn control_change(
        midi_channel: u8,
        controller: u8,
        value: u8,
        received_at: Instant,
    ) -> Self {
        Self {
            message_type: MidiMessageType::ControlChange,
            midi_channel,
            note: controller, // CC number stored in note field
            velocity: value,  // CC value stored in velocity field
            received_at,
            frame_offset: 0,
        }
    }
}

/// Release velocity used when a note-off has none (a note-on with velocity 0, the virtual
/// keyboard, a note-off with no release of its own).
pub const DEFAULT_RELEASE: f32 = 0.5;

/// A normalized 0–1 value as a 7-bit MIDI value (the sfizz binding, the device shim).
pub fn to_u7(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * 127.0).round() as u8
}

/// Engine-issued id of one sounding note: unique per channel while it sounds, never 0, and
/// wrapping below 2^31 so it fits a CLAP `note_id`.
pub type SoundingNoteId = u32;

/// Id for notes played outside a channel's sounding-note table (a Layer slot audition).
/// The table never issues 0, so these can't collide with a sounding note.
pub const AUDITION_NOTE_ID: SoundingNoteId = 0;

/// Per-note expression types, in CLAP's natural units: pitch in semitones, gain as linear
/// amplitude, pan centred at 0.5, timbre and pressure 0–1. Nothing sends these yet.
#[allow(dead_code)] // Reserved for the expression-curves spec.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoteExpression {
    Pitch,
    Gain,
    Pan,
    Timbre,
    Pressure,
}

/// A note event delivered to a device. Velocity and release are normalized 0–1. Containers
/// forward it with the same `note_id`; only `key` may change (Layer remapping).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum NoteEvent {
    On {
        note_id: SoundingNoteId,
        key: u8,
        velocity: f32,
    },
    Off {
        note_id: SoundingNoteId,
        key: u8,
        release: f32,
    },
    /// Reserved for the expression-curves spec: nothing sends one yet.
    #[allow(dead_code)]
    Expression {
        note_id: SoundingNoteId,
        key: u8,
        kind: NoteExpression,
        value: f32,
    },
}

impl NoteEvent {
    pub fn key(&self) -> u8 {
        match *self {
            NoteEvent::On { key, .. }
            | NoteEvent::Off { key, .. }
            | NoteEvent::Expression { key, .. } => key,
        }
    }

    pub fn note_id(&self) -> SoundingNoteId {
        match *self {
            NoteEvent::On { note_id, .. }
            | NoteEvent::Off { note_id, .. }
            | NoteEvent::Expression { note_id, .. } => note_id,
        }
    }

    /// Tests: a note-on from a 7-bit velocity, with an id derived from the key so
    /// [`test_off`](Self::test_off) on the same key pairs with it.
    #[cfg(test)]
    pub fn test_on(key: u8, velocity: u8) -> NoteEvent {
        NoteEvent::On {
            note_id: key as SoundingNoteId + 1,
            key,
            velocity: velocity as f32 / 127.0,
        }
    }

    /// Tests: the note-off for [`test_on`](Self::test_on) on `key`, with the default release.
    #[cfg(test)]
    pub fn test_off(key: u8) -> NoteEvent {
        NoteEvent::Off {
            note_id: key as SoundingNoteId + 1,
            key,
            release: DEFAULT_RELEASE,
        }
    }

    /// The same event on another key (Layer's key mapping). Everything else is kept.
    pub fn with_key(&self, new_key: u8) -> NoteEvent {
        let mut event = *self;
        match &mut event {
            NoteEvent::On { key, .. }
            | NoteEvent::Off { key, .. }
            | NoteEvent::Expression { key, .. } => *key = new_key,
        }
        event
    }
}

/// Lock-free MIDI event queue for audio thread communication
pub type MidiEventQueue = Arc<SegQueue<MidiEvent>>;

/// Create a new MIDI event queue
pub fn create_midi_queue() -> MidiEventQueue {
    Arc::new(SegQueue::new())
}

/// MIDI routing configuration for a channel
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MidiRouting {
    /// MIDI input device routing:
    /// -3 = no MIDI (ignore all input)
    /// -2 = all devices (accept from any enabled device)
    /// -1 = virtual keyboard only
    /// 0+ = specific physical device ID
    pub device_id: i32,

    /// Whether channel is armed for MIDI recording
    pub record_armed: bool,
}

impl Default for MidiRouting {
    fn default() -> Self {
        Self {
            device_id: -2, // All devices by default
            record_armed: false,
        }
    }
}

impl MidiRouting {
    /// Check if this routing accepts MIDI from the given device
    pub fn accepts_device(&self, device_id: i32) -> bool {
        if !self.record_armed {
            return false;
        }

        match self.device_id {
            -3 => false,           // No MIDI
            -2 => true,            // All devices
            id => id == device_id, // Specific device
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_midi_routing_no_input() {
        let routing = MidiRouting {
            device_id: -3,
            record_armed: true,
        };
        assert!(!routing.accepts_device(0));
        assert!(!routing.accepts_device(-1));
    }

    #[test]
    fn test_midi_routing_all_devices() {
        let routing = MidiRouting {
            device_id: -2,
            record_armed: true,
        };
        assert!(routing.accepts_device(0));
        assert!(routing.accepts_device(-1));
        assert!(routing.accepts_device(5));
    }

    #[test]
    fn test_midi_routing_specific_device() {
        let routing = MidiRouting {
            device_id: 0,
            record_armed: true,
        };
        assert!(routing.accepts_device(0));
        assert!(!routing.accepts_device(-1));
        assert!(!routing.accepts_device(1));
    }

    #[test]
    fn test_midi_routing_not_armed() {
        let routing = MidiRouting {
            device_id: -2,
            record_armed: false,
        };
        assert!(!routing.accepts_device(0));
        assert!(!routing.accepts_device(-1));
    }

    #[test]
    fn test_message_type_conversion() {
        assert_eq!(MidiMessageType::from_u8(8), Some(MidiMessageType::NoteOff));
        assert_eq!(MidiMessageType::from_u8(9), Some(MidiMessageType::NoteOn));
        assert_eq!(
            MidiMessageType::from_u8(11),
            Some(MidiMessageType::ControlChange)
        );
        assert_eq!(MidiMessageType::from_u8(255), None);
    }

    #[test]
    fn note_event_helpers() {
        assert!(std::mem::size_of::<NoteEvent>() <= 16);

        let on = NoteEvent::On {
            note_id: 7,
            key: 60,
            velocity: 0.5,
        };
        assert_eq!(on.key(), 60);
        assert_eq!(on.note_id(), 7);
        assert_eq!(
            on.with_key(36),
            NoteEvent::On {
                note_id: 7,
                key: 36,
                velocity: 0.5
            }
        );

        let off = NoteEvent::Off {
            note_id: 8,
            key: 61,
            release: 0.25,
        };
        assert_eq!(
            off.with_key(40),
            NoteEvent::Off {
                note_id: 8,
                key: 40,
                release: 0.25
            }
        );

        let expr = NoteEvent::Expression {
            note_id: 9,
            key: 62,
            kind: NoteExpression::Timbre,
            value: 0.75,
        };
        assert_eq!(expr.key(), 62);
        assert_eq!(expr.note_id(), 9);
        assert_eq!(
            expr.with_key(10),
            NoteEvent::Expression {
                note_id: 9,
                key: 10,
                kind: NoteExpression::Timbre,
                value: 0.75
            }
        );
    }
}
