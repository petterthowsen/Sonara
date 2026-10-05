//! Per-channel table of sounding notes. It issues each note-on a sounding-note id and pairs the
//! note-off with it, so devices (and CLAP plugins) can tell overlapping notes on one key apart.
//!
//! Audio thread: a fixed inline array, no allocation. Entries stay in note-on order, so the
//! first entry is always the oldest.

use super::midi_types::{NoteEvent, SoundingNoteId};

/// Most notes a channel tracks at once. When the table is full, the oldest note is released.
pub const MAX_ACTIVE_NOTES: usize = 256;

/// Ids wrap before this so they fit a CLAP `note_id` (an `i32` that must not be negative).
const ID_LIMIT: SoundingNoteId = 1 << 31;

/// Where a sounding note came from, which decides how its note-off finds it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoteSource {
    /// Clip playback. Paired by clip-note id, so a note whose pitch or instance transpose
    /// changes while it's held still gets its note-off.
    Clip { clip_note_id: u64 },
    /// Live MIDI. Paired by (MIDI channel, key).
    Live { midi_channel: u8 },
}

#[derive(Debug, Clone, Copy)]
struct ActiveNote {
    source: NoteSource,
    key: u8,
    note_id: SoundingNoteId,
    /// Release used when the note is ended without one of its own (stop, seek, eviction).
    release: f32,
}

const EMPTY: ActiveNote = ActiveNote {
    source: NoteSource::Live { midi_channel: 0 },
    key: 0,
    note_id: 0,
    release: 0.0,
};

pub struct ActiveNotes {
    entries: [ActiveNote; MAX_ACTIVE_NOTES],
    len: usize,
    next_id: SoundingNoteId,
}

impl Default for ActiveNotes {
    fn default() -> Self {
        Self::new()
    }
}

impl ActiveNotes {
    pub fn new() -> Self {
        Self {
            entries: [EMPTY; MAX_ACTIVE_NOTES],
            len: 0,
            next_id: 1,
        }
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.len
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    fn issue_id(&mut self) -> SoundingNoteId {
        let id = self.next_id;
        self.next_id += 1;
        if self.next_id >= ID_LIMIT {
            self.next_id = 1;
        }
        id
    }

    fn remove(&mut self, index: usize) -> ActiveNote {
        let entry = self.entries[index];
        self.entries.copy_within(index + 1..self.len, index);
        self.len -= 1;
        entry
    }

    /// Start a note. `release` is stored for when the note ends without one (stop, seek,
    /// eviction). Returns the eviction note-off (when the table was full) and the note-on.
    pub fn note_on(
        &mut self,
        source: NoteSource,
        key: u8,
        velocity: f32,
        release: f32,
    ) -> (Option<NoteEvent>, NoteEvent) {
        let evicted = if self.len == MAX_ACTIVE_NOTES {
            let oldest = self.remove(0);
            Some(NoteEvent::Off {
                note_id: oldest.note_id,
                key: oldest.key,
                release: oldest.release,
            })
        } else {
            None
        };

        let note_id = self.issue_id();
        self.entries[self.len] = ActiveNote {
            source,
            key,
            note_id,
            release,
        };
        self.len += 1;
        (
            evicted,
            NoteEvent::On {
                note_id,
                key,
                velocity,
            },
        )
    }

    /// End the oldest matching note. A clip note matches by clip-note id (`key` is ignored), a
    /// live note by (MIDI channel, key). The note-off carries the key the note started on, and
    /// the stored release when `release` is `None`. Returns `None` when nothing matches (the
    /// note was already released by stop, seek or eviction).
    pub fn note_off(
        &mut self,
        source: NoteSource,
        key: u8,
        release: Option<f32>,
    ) -> Option<NoteEvent> {
        let index = self.entries[..self.len]
            .iter()
            .position(|entry| match source {
                NoteSource::Clip { .. } => entry.source == source,
                NoteSource::Live { .. } => entry.source == source && entry.key == key,
            })?;
        let entry = self.remove(index);
        Some(NoteEvent::Off {
            note_id: entry.note_id,
            key: entry.key,
            release: release.unwrap_or(entry.release),
        })
    }

    /// End every clip-sourced note with its stored release, oldest first. Live notes keep
    /// sounding, so keys held on a controller survive stop and seek.
    pub fn release_clip(&mut self, mut out: impl FnMut(NoteEvent)) {
        let mut kept = 0;
        for i in 0..self.len {
            let entry = self.entries[i];
            if matches!(entry.source, NoteSource::Clip { .. }) {
                out(NoteEvent::Off {
                    note_id: entry.note_id,
                    key: entry.key,
                    release: entry.release,
                });
            } else {
                self.entries[kept] = entry;
                kept += 1;
            }
        }
        self.len = kept;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clip(id: u64) -> NoteSource {
        NoteSource::Clip { clip_note_id: id }
    }

    fn live(channel: u8) -> NoteSource {
        NoteSource::Live {
            midi_channel: channel,
        }
    }

    #[test]
    fn active_notes_pair_clip_notes_by_id_after_key_change() {
        let mut notes = ActiveNotes::new();
        let (_, on) = notes.note_on(clip(5), 60, 0.8, 0.5);
        // The note was transposed while held: the off arrives on another key.
        let off = notes.note_off(clip(5), 62, Some(0.25)).unwrap();
        assert_eq!(
            off,
            NoteEvent::Off {
                note_id: on.note_id(),
                key: 60,
                release: 0.25
            }
        );
        assert!(notes.is_empty());
    }

    #[test]
    fn active_notes_pair_live_notes_by_channel_and_key() {
        let mut notes = ActiveNotes::new();
        let (_, on_a) = notes.note_on(live(0), 60, 1.0, 0.5);
        let (_, on_b) = notes.note_on(live(1), 60, 1.0, 0.5);
        let (_, on_c) = notes.note_on(live(0), 64, 1.0, 0.5);

        assert!(notes.note_off(live(2), 60, None).is_none());
        assert_eq!(
            notes.note_off(live(1), 60, None).unwrap().note_id(),
            on_b.note_id()
        );
        assert_eq!(
            notes.note_off(live(0), 64, None).unwrap().note_id(),
            on_c.note_id()
        );
        assert_eq!(
            notes.note_off(live(0), 60, None).unwrap().note_id(),
            on_a.note_id()
        );
        assert!(notes.is_empty());
    }

    #[test]
    fn active_notes_overlapping_plays_get_distinct_ids() {
        let mut notes = ActiveNotes::new();
        let (_, first) = notes.note_on(clip(1), 60, 0.5, 0.5);
        let (_, second) = notes.note_on(clip(1), 60, 0.5, 0.5);
        assert_ne!(first.note_id(), second.note_id());

        // Each off ends the oldest play still sounding.
        let off_1 = notes.note_off(clip(1), 60, None).unwrap();
        let off_2 = notes.note_off(clip(1), 60, None).unwrap();
        assert_eq!(off_1.note_id(), first.note_id());
        assert_eq!(off_2.note_id(), second.note_id());
        assert!(notes.note_off(clip(1), 60, None).is_none());
    }

    #[test]
    fn active_notes_evict_oldest_when_full() {
        let mut notes = ActiveNotes::new();
        let (_, first) = notes.note_on(clip(0), 10, 1.0, 0.3);
        for i in 1..MAX_ACTIVE_NOTES as u64 {
            let (evicted, _) = notes.note_on(clip(i), 20, 1.0, 0.5);
            assert!(evicted.is_none());
        }
        assert_eq!(notes.len(), MAX_ACTIVE_NOTES);

        let (evicted, _) = notes.note_on(clip(999), 30, 1.0, 0.5);
        assert_eq!(
            evicted,
            Some(NoteEvent::Off {
                note_id: first.note_id(),
                key: 10,
                release: 0.3
            })
        );
        assert_eq!(notes.len(), MAX_ACTIVE_NOTES);
        assert!(notes.note_off(clip(0), 10, None).is_none());
    }

    #[test]
    fn active_notes_ids_wrap_below_2_pow_31_and_skip_0() {
        let mut notes = ActiveNotes::new();
        notes.next_id = ID_LIMIT - 1;
        let (_, last) = notes.note_on(live(0), 1, 1.0, 0.5);
        let (_, wrapped) = notes.note_on(live(0), 2, 1.0, 0.5);
        assert_eq!(last.note_id(), ID_LIMIT - 1);
        assert_eq!(wrapped.note_id(), 1);
    }

    #[test]
    fn active_notes_release_clip_uses_stored_release_and_keeps_live() {
        let mut notes = ActiveNotes::new();
        let (_, a) = notes.note_on(clip(1), 60, 1.0, 0.9);
        let (_, held) = notes.note_on(live(0), 48, 1.0, 0.5);
        let (_, b) = notes.note_on(clip(2), 64, 1.0, 0.2);

        let mut released = Vec::new();
        notes.release_clip(|event| released.push(event));
        assert_eq!(
            released,
            vec![
                NoteEvent::Off {
                    note_id: a.note_id(),
                    key: 60,
                    release: 0.9
                },
                NoteEvent::Off {
                    note_id: b.note_id(),
                    key: 64,
                    release: 0.2
                },
            ]
        );
        assert_eq!(notes.len(), 1);
        assert_eq!(
            notes.note_off(live(0), 48, Some(0.4)),
            Some(NoteEvent::Off {
                note_id: held.note_id(),
                key: 48,
                release: 0.4
            })
        );
    }
}
