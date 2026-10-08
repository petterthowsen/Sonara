//! Note effects (spec 027): built-in devices that take notes in and send notes on to the
//! devices after them in their chain. Audio passes through them untouched.
//!
//! - [`routing`]: how notes move through a chain. Routing delivers an event in chain order and
//!   stops at the first note effect, which queues it. The chain's **note phase**
//!   ([`routing::run_note_phase`]), run before any audio renders, asks each note effect in turn
//!   for this block's output and routes it on to the devices after it (ADR-0019).
//! - [`host`]: [`NoteFxHost`], the shared machinery (input queue, schedule, sounding table,
//!   bypass, release) around a small [`NoteProcessor`] per device.
//! - [`ids`]: engine-wide ids for generated notes, in the ranges `midi_types` documents.

pub mod arpeggiator;
pub mod chance;
pub mod chord;
pub mod clock;
#[cfg(test)]
mod conformance;
pub mod host;
pub mod ids;
pub mod latch;
pub mod note_echo;
pub mod note_filter;
pub mod note_length;
pub mod routing;
pub mod scale;
pub mod step_sequencer;
pub mod transpose;
pub mod velocity;

pub use host::NoteFxHost;

use crate::audio::midi_types::NoteEvent;

/// A note event at a frame offset in the current block.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TimedNote {
    pub frame: usize,
    pub event: NoteEvent,
}

/// Order rank at one frame: note-offs first, so a retrigger on the same frame ends the old
/// note before the new one starts.
fn rank(event: &NoteEvent) -> u8 {
    match event {
        NoteEvent::Off { .. } => 0,
        NoteEvent::Expression { .. } => 1,
        NoteEvent::On { .. } => 2,
    }
}

/// A fixed-capacity list of [`TimedNote`]s. Allocates once in `new`; `push` refuses when full,
/// so it never grows on the audio thread.
pub struct NoteBuffer {
    notes: Vec<TimedNote>,
}

impl NoteBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            notes: Vec::with_capacity(capacity),
        }
    }

    /// Append a note; false (and nothing stored) when the buffer is full.
    pub fn push(&mut self, note: TimedNote) -> bool {
        if self.notes.len() == self.notes.capacity() {
            return false;
        }
        self.notes.push(note);
        true
    }

    pub fn clear(&mut self) {
        self.notes.clear();
    }

    pub fn len(&self) -> usize {
        self.notes.len()
    }

    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.notes.is_empty()
    }

    pub fn is_full(&self) -> bool {
        self.notes.len() == self.notes.capacity()
    }

    /// Free slots left.
    pub fn room(&self) -> usize {
        self.notes.capacity() - self.notes.len()
    }

    pub fn as_slice(&self) -> &[TimedNote] {
        &self.notes
    }

    /// Stable sort by frame, note-offs before other events on the same frame. Insertion sort:
    /// no allocation, and the input is short and nearly sorted.
    pub fn sort(&mut self) {
        let notes = &mut self.notes;
        for i in 1..notes.len() {
            let mut j = i;
            let key = (notes[j].frame, rank(&notes[j].event));
            while j > 0 && (notes[j - 1].frame, rank(&notes[j - 1].event)) > key {
                notes.swap(j - 1, j);
                j -= 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buffer_refuses_when_full_and_sorts_stably_offs_first() {
        let mut buffer = NoteBuffer::new(4);
        let on = |id, frame| TimedNote {
            frame,
            event: NoteEvent::On {
                note_id: id,
                key: 60,
                velocity: 1.0,
            },
        };
        let off = |id, frame| TimedNote {
            frame,
            event: NoteEvent::Off {
                note_id: id,
                key: 60,
                release: 0.5,
            },
        };
        assert!(buffer.push(on(1, 5)));
        assert!(buffer.push(on(2, 2)));
        assert!(buffer.push(off(3, 5)));
        assert!(buffer.push(on(4, 2)));
        assert!(!buffer.push(on(5, 0)));
        buffer.sort();
        let ids: Vec<u32> = buffer
            .as_slice()
            .iter()
            .map(|n| n.event.note_id())
            .collect();
        assert_eq!(ids, vec![2, 4, 3, 1]);
    }
}
