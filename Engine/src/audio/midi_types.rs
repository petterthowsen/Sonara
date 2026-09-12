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
}
