//! Project-wide commands on the command thread: removing channels, tempo and time signature maps,
//! clearing the project.

use tracing::{info, warn};

use super::CommandWorker;
use crate::audio::tempo_map::TempoMap;
use crate::audio::time_signature_map::TimeSignatureMap;
use crate::audio::types::{ChannelId, Tick};

impl CommandWorker {
    /// Detach a channel under the lock and drop it, with its devices, afterwards.
    pub(super) fn remove_channel(&self, id: ChannelId) {
        let (removed, remaining) = {
            let mut state = self.lock_state();
            let removed = state.channels.remove(&id);
            (removed, state.channels.len())
        };
        match removed {
            Some(channel) => {
                drop(channel);
                info!("Channel {} removed [total channels: {}]", id, remaining);
            }
            None => warn!("Cannot remove channel {}: not found", id),
        }
    }

    /// Build a tempo map off the lock, swap it in, and drop the old one after unlocking.
    pub(super) fn set_tempo_map(&self, points: Vec<(Tick, f32)>) {
        let map = TempoMap::from_points(points);
        let count = map.points().len();
        let old = std::mem::replace(&mut self.lock_state().tempo_map, map);
        drop(old);
        info!("Tempo map set: {} points", count);
    }

    /// Build a time signature map off the lock, swap it in, and drop the old one after unlocking.
    pub(super) fn set_time_signature_map(&self, changes: Vec<(u32, u16, u16)>) {
        let map = TimeSignatureMap::from_changes(changes);
        let count = map.changes().len();
        let old = std::mem::replace(&mut self.lock_state().time_signature_map, map);
        drop(old);
        info!("Time signature map set: {} changes", count);
    }

    /// Swap out all channels, tracks and clips under the lock and drop them afterwards.
    pub(super) fn clear_project(&self) {
        let removed = {
            let mut state = self.lock_state();
            state.set_current_tick(0);
            state.set_fractional_tick_accumulator(0.0);
            let _ = state.take_playhead_midi_dispatch();
            state.loop_region = None;
            (
                std::mem::take(&mut state.channels),
                std::mem::take(&mut state.tracks),
                std::mem::take(&mut state.clips),
                std::mem::take(&mut state.tempo_map),
                std::mem::take(&mut state.time_signature_map),
            )
        };
        drop(removed);
        {
            let mut state = self.lock_state();
            state.ensure_master_channel(self.max_buffer_size);
        }
        info!("Project cleared");
    }
}
