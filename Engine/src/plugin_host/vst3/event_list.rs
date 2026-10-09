//! `EventList`: a fixed-capacity `IEventList` with the storage preallocated at construction.
//! Nothing allocates when the plugin calls `addEvent`, so it is safe to hand to a real-time
//! block (the audio thread contract in AGENTS.md).

use std::cell::{Cell, UnsafeCell};

use ::vst3::Class;
use ::vst3::Steinberg::Vst::{Event, IEventList, IEventListTrait};
use ::vst3::Steinberg::{int32, kInvalidArgument, kResultFalse, kResultOk, tresult};
/// Fixed-capacity event list. The capacity is decided once, at construction.
pub struct EventList {
    events: UnsafeCell<Vec<Event>>,
    len: Cell<usize>,
}

impl EventList {
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            // A zeroed Event is a valid (if meaningless) value: all fields are plain numbers
            // or pointers that are only read after the event type is set.
            events: UnsafeCell::new(vec![unsafe { std::mem::zeroed() }; capacity]),
            len: Cell::new(0),
        }
    }

    pub fn capacity(&self) -> usize {
        unsafe { (*self.events.get()).len() }
    }

    /// Number of live events.
    pub fn len(&self) -> usize {
        self.len.get()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Drop all events; capacity is kept. Called between blocks.
    pub fn clear(&self) {
        self.len.set(0);
    }

    /// Add an event. Returns false when the fixed capacity is exhausted (the caller decides
    /// whether that is worth an error; the audio thread drops the event).
    pub fn push(&self, event: &Event) -> bool {
        let events = unsafe { &mut *self.events.get() };
        let len = self.len.get();
        if len >= events.len() {
            return false;
        }
        events[len] = *event;
        self.len.set(len + 1);
        true
    }

    pub fn get(&self, index: usize) -> Option<Event> {
        if index >= self.len() {
            return None;
        }
        let events = unsafe { &*self.events.get() };
        Some(events[index])
    }
}

impl Class for EventList {
    type Interfaces = (IEventList,);
}

impl IEventListTrait for EventList {
    unsafe fn getEventCount(&self) -> int32 {
        self.len.get() as int32
    }

    unsafe fn getEvent(&self, index: int32, event: *mut Event) -> tresult {
        if event.is_null() || index < 0 {
            return kInvalidArgument;
        }
        match self.get(index as usize) {
            Some(e) => {
                *event = e;
                kResultOk
            }
            None => kInvalidArgument,
        }
    }

    unsafe fn addEvent(&self, event: *mut Event) -> tresult {
        if event.is_null() {
            return kInvalidArgument;
        }
        if self.push(&*event) {
            kResultOk
        } else {
            kResultFalse
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ::vst3::ComWrapper;
    use ::vst3::Steinberg::Vst::{Event__type0, NoteOnEvent};

    /// `EventTypes_` lives inside `Event_` in the generated bindings.
    const NOTE_ON: u16 = ::vst3::Steinberg::Vst::Event_::EventTypes_::kNoteOnEvent as u16;
    const NOTE_OFF: u16 = ::vst3::Steinberg::Vst::Event_::EventTypes_::kNoteOffEvent as u16;

    fn note_event(event_type: u16, pitch: i16) -> Event {
        let mut event: Event = unsafe { std::mem::zeroed() };
        event.busIndex = 0;
        event.sampleOffset = 7;
        event.r#type = event_type;
        event.__field0 = Event__type0 {
            noteOn: NoteOnEvent {
                channel: 0,
                pitch,
                tuning: 0.0,
                velocity: 0.5,
                length: 0,
                noteId: -1,
            },
        };
        event
    }

    #[test]
    fn add_get_and_clear() {
        let list = ComWrapper::new(EventList::with_capacity(2));
        let ptr = list.to_com_ptr::<IEventList>().unwrap();
        let mut event = note_event(NOTE_ON, 60);
        let mut other = note_event(NOTE_OFF, 60);
        let mut overflow = note_event(NOTE_ON, 61);
        unsafe {
            assert_eq!(ptr.getEventCount(), 0);
            assert_eq!(ptr.addEvent(&mut event), 0);
            assert_eq!(ptr.addEvent(&mut other), 0);
            assert_eq!(ptr.getEventCount(), 2);
            // Full: the fixed capacity refuses.
            assert_eq!(ptr.addEvent(&mut overflow), 1);

            let mut out: Event = std::mem::zeroed();
            assert_eq!(ptr.getEvent(1, &mut out), 0);
            assert_eq!(out.r#type, NOTE_OFF);
            assert_eq!(out.sampleOffset, 7);
            assert_eq!(out.__field0.noteOn.pitch, 60);
            // Out of range and negative indexes are errors.
            assert_eq!(ptr.getEvent(2, &mut out), kInvalidArgument);
            assert_eq!(ptr.getEvent(-1, &mut out), kInvalidArgument);
        }
        list.clear();
        assert_eq!(list.len(), 0);
        assert_eq!(list.capacity(), 2);
    }

    #[test]
    fn push_directly_reports_overflow() {
        let list = EventList::with_capacity(1);
        assert!(list.push(&note_event(NOTE_ON, 60)));
        assert!(!list.push(&note_event(NOTE_ON, 61)));
        assert_eq!(unsafe { list.get(0).unwrap().__field0.noteOn.pitch }, 60);
        assert!(list.get(1).is_none());
    }
}
