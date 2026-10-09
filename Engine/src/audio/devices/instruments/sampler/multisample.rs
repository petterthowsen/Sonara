//! Multisample mode: zones, groups, focus and their loading state (spec 023).

use super::regions::{SampleBuffer, Zone};
use super::voice::Voice;
use super::zones::{GroupPlayMode, ZoneGroup, ZoneSettings, MAX_GROUPS, MAX_ZONES, UNGROUPED};
use super::SamplerDevice;
use crate::audio::commands::EngineStatus;
use tracing::{info, warn};

impl SamplerDevice {
    /// Switch modes. Voices are killed either way. On reserves the zone, group and match
    /// capacity; off drops the zones and groups (and their PCM).
    pub fn set_multisample(&mut self, on: bool) {
        if on == self.multisample {
            return;
        }
        info!(
            "Sampler channel={} path={} multisample={}",
            self.channel_id, self.device_path, on
        );
        self.reset_voices();
        self.multisample = on;
        self.any_solo = false;
        if on {
            self.zones = Vec::with_capacity(MAX_ZONES);
            self.groups = Vec::with_capacity(MAX_GROUPS);
            self.groups.push(ZoneGroup::new(UNGROUPED));
            self.match_scratch = Vec::with_capacity(MAX_ZONES);
        } else {
            self.zones = Vec::new();
            self.groups = Vec::new();
            self.match_scratch = Vec::new();
        }
    }

    pub(super) fn zone_index(&self, id: u32) -> Option<usize> {
        self.zones.iter().position(|z| z.id == id)
    }

    pub(super) fn group_index_of(&self, id: u32) -> usize {
        self.groups.iter().position(|g| g.id == id).unwrap_or(0)
    }

    /// Point every zone at its group's index again after groups were added or removed.
    pub(super) fn relink_groups(&mut self) {
        for i in 0..self.zones.len() {
            self.zones[i].group_index = self.group_index_of(self.zones[i].group_id);
        }
    }

    /// Kill the voices playing zone `index` (before its PCM is replaced or it is removed).
    pub(super) fn kill_zone_voices(&mut self, index: u16) {
        let sample_rate = self.sample_rate;
        for voice in self
            .voices
            .iter_mut()
            .filter(|v| v.active && v.zone == index)
        {
            *voice = Voice::idle(sample_rate);
        }
    }

    /// Create or replace zone `id`'s settings. Its PCM, if any, is kept.
    pub fn set_zone(&mut self, id: u32, settings: &ZoneSettings) {
        if !self.multisample {
            warn!("Sampler zone {} set ignored: not in multisample mode", id);
            return;
        }
        let settings = settings.sanitized();
        let group_index = self.group_index_of(settings.group_id);
        let zone = match self.zone_index(id) {
            Some(index) => &mut self.zones[index],
            None if self.zones.len() >= MAX_ZONES => {
                warn!("Sampler zone {} dropped: already {} zones", id, MAX_ZONES);
                return;
            }
            None => {
                self.zones.push(Zone::empty(id));
                self.zones.last_mut().expect("just pushed")
            }
        };
        zone.apply_settings(&settings);
        zone.group_index = group_index;
        self.pitch_dirty = true;
    }

    /// Remove zone `id` and its voices. The last zone moves into its index.
    pub fn remove_zone(&mut self, id: u32) {
        let Some(index) = self.zone_index(id) else {
            warn!("Sampler zone {} remove ignored: no such zone", id);
            return;
        };
        let (removed, last) = (index as u16, (self.zones.len() - 1) as u16);
        self.kill_zone_voices(removed);
        for voice in self.voices.iter_mut().filter(|v| v.zone == last) {
            voice.zone = removed;
        }
        for group in &mut self.groups {
            group.remap_zone(removed, last);
        }
        self.zones.swap_remove(index);
    }

    /// Create or replace group `id`.
    pub fn set_zone_group(
        &mut self,
        id: u32,
        gain: f32,
        mute: bool,
        solo: bool,
        play_mode: GroupPlayMode,
    ) {
        if !self.multisample {
            warn!("Sampler group {} set ignored: not in multisample mode", id);
            return;
        }
        match self.groups.iter().position(|g| g.id == id) {
            Some(index) => self.groups[index].set(gain, mute, solo, play_mode),
            None if self.groups.len() >= MAX_GROUPS => {
                warn!(
                    "Sampler group {} dropped: already {} groups",
                    id, MAX_GROUPS
                );
                return;
            }
            None => {
                let mut group = ZoneGroup::new(id);
                group.set(gain, mute, solo, play_mode);
                self.groups.push(group);
                self.relink_groups();
            }
        }
        self.any_solo = self.groups.iter().any(|g| g.solo);
    }

    /// Remove group `id`. Its zones fall back to Ungrouped, which can't be removed.
    pub fn remove_zone_group(&mut self, id: u32) {
        if id == UNGROUPED {
            warn!("Sampler: Ungrouped can't be removed");
            return;
        }
        let Some(index) = self.groups.iter().position(|g| g.id == id) else {
            return;
        };
        self.groups.remove(index);
        for zone in self.zones.iter_mut().filter(|z| z.group_id == id) {
            zone.group_id = UNGROUPED;
        }
        self.relink_groups();
        self.any_solo = self.groups.iter().any(|g| g.solo);
    }

    /// Report only zone `id`'s voices on the `"playheads"` stream.
    pub fn set_focus(&mut self, id: u32) {
        self.focused_zone = id;
    }

    /// Mark zone `id` as loading `req_id`.
    pub fn begin_zone_load(&mut self, id: u32, req_id: String) {
        let Some(index) = self.zone_index(id) else {
            warn!("Sampler zone {} load ignored: no such zone", id);
            return;
        };
        info!(
            "Sampler begin zone load channel={} path={} zone={} req={}",
            self.channel_id, self.device_path, id, req_id
        );
        self.zones[index].req_id = req_id;
        self.emit_zone_loading(index, "loading".to_string());
    }

    /// Replace zone `id`'s PCM. Stale requests and unknown zones are ignored, and the old PCM
    /// is freed here, on the command thread.
    pub fn set_zone_sample(
        &mut self,
        id: u32,
        req_id: &str,
        samples: Vec<f32>,
        channels: usize,
        sample_rate: u32,
    ) {
        let Some(index) = self.zone_index(id) else {
            warn!("Ignoring sampler zone load for unknown zone {}", id);
            return;
        };
        let zone = &self.zones[index];
        if !zone.req_id.is_empty() && zone.req_id != req_id {
            warn!(
                "Ignoring stale sampler zone {} load (expected {}, got {})",
                id, zone.req_id, req_id
            );
            return;
        }
        self.kill_zone_voices(index as u16);
        let zone = &mut self.zones[index];
        zone.sample = Some(SampleBuffer::new(samples, channels, sample_rate));
        zone.resolve_regions();
        let bytes: usize = self
            .zones
            .iter()
            .filter_map(|z| z.sample.as_ref())
            .map(|s| s.samples.len() * std::mem::size_of::<f32>())
            .sum();
        info!(
            "Sampler zone {} ready: {} frames; {} zones hold {:.1} MB of PCM",
            id,
            self.zones[index].frames(),
            self.zones.len(),
            bytes as f64 / 1_000_000.0
        );
        self.sleep_state.mark_activity();
        self.emit_zone_loading(index, "ready".to_string());
    }

    /// Record a failed zone load. The zone stays (silent if it never loaded, REQ-028).
    pub fn fail_zone_load(&mut self, id: u32, req_id: &str, message: &str) {
        let Some(index) = self.zone_index(id) else {
            return;
        };
        let zone = &self.zones[index];
        if !zone.req_id.is_empty() && zone.req_id != req_id {
            return;
        }
        warn!("Sampler zone {} load failed: {}", id, message);
        self.emit_zone_loading(index, format!("failed:{}", message));
    }

    pub(super) fn emit_zone_loading(&mut self, index: usize, state: String) {
        let zone = &mut self.zones[index];
        zone.loading_state = state.clone();
        if let Some(tx) = &self.status_tx {
            let _ = tx.send(EngineStatus::SamplerZoneLoadingState {
                channel_id: self.channel_id,
                device_path: self.device_path.clone(),
                zone_id: zone.id,
                state,
            });
        }
    }

    /// Every zone's loading state, for Godot's `state/get`. Returned rather than sent so the
    /// caller can queue them in order with its other statuses.
    pub fn zone_state_statuses(&self) -> Vec<EngineStatus> {
        self.zones
            .iter()
            .map(|zone| EngineStatus::SamplerZoneLoadingState {
                channel_id: self.channel_id,
                device_path: self.device_path.clone(),
                zone_id: zone.id,
                state: zone.loading_state.clone(),
            })
            .collect()
    }
}
