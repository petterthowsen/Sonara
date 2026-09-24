//! Plugin state and audio-thread hand-off
//!
//! The main thread owns the CLAP [`PluginInstance`] and everything that must run there (commands,
//! GUI, timers, `params.flush`). Audio processing runs on the host's own audio thread
//! (`audio_thread.rs`), which owns the plugin's [`PluginAudioProcessor`] and the instance's
//! shared block. The two threads communicate over a channel, never by sharing the instance.

use std::collections::HashMap;
use std::sync::Arc;

use clack_host::prelude::*;

use crate::audio::ipc::{InstanceId, SharedMemory};

use crate::plugin_host::host::{SubprocessHost, SubprocessHostShared};

/// A parameter's CLAP id and range, found by the engine's index for it.
#[derive(Debug, Clone, Copy)]
pub struct ParamEntry {
    pub clap_id: ClapId,
    pub min: f64,
    pub max: f64,
}

impl ParamEntry {
    /// Plugin value to the engine's 0.0-1.0.
    pub fn normalize(&self, value: f64) -> f32 {
        let range = self.max - self.min;
        if range.abs() > f64::EPSILON {
            ((value - self.min) / range).clamp(0.0, 1.0) as f32
        } else {
            0.5
        }
    }

    /// The engine's 0.0-1.0 to a plugin value.
    pub fn denormalize(&self, value: f32) -> f64 {
        self.min + value as f64 * (self.max - self.min)
    }
}

/// Maps between the engine's parameter indices and CLAP ids. Built once from the params
/// extension, and rebuilt after the plugin rescans its parameter list.
///
/// Shared with the audio thread through an `Arc`: rebuilt maps are published as new `Arc`s, so
/// the audio thread never sees a half-built map.
#[derive(Debug, Default)]
pub struct ParamMap {
    /// By CLAP parameter index, which is the engine's parameter id. None where the plugin
    /// reported no info for an index.
    entries: Vec<Option<ParamEntry>>,
    index_by_id: HashMap<ClapId, u32>,
}

impl ParamMap {
    pub fn build(instance: &mut PluginInstance<SubprocessHost>) -> Self {
        let mut handle = instance.plugin_handle();
        let Some(params) = handle.get_extension::<clack_extensions::params::PluginParams>() else {
            return Self::default();
        };
        let count = params.count(&mut handle);
        let mut map = Self {
            entries: Vec::with_capacity(count as usize),
            index_by_id: HashMap::with_capacity(count as usize),
        };
        for index in 0..count {
            let mut buffer = clack_extensions::params::ParamInfoBuffer::new();
            let entry = params
                .get_info(&mut handle, index, &mut buffer)
                .map(|info| ParamEntry {
                    clap_id: info.id,
                    min: info.min_value,
                    max: info.max_value,
                });
            if let Some(entry) = entry {
                map.index_by_id.insert(entry.clap_id, index);
            }
            map.entries.push(entry);
        }
        map
    }

    pub fn get(&self, index: u32) -> Option<ParamEntry> {
        self.entries.get(index as usize).copied().flatten()
    }

    /// The engine's index for a CLAP parameter id, with its entry.
    pub fn find(&self, clap_id: ClapId) -> Option<(u32, ParamEntry)> {
        let index = *self.index_by_id.get(&clap_id)?;
        Some((index, self.get(index)?))
    }
}

/// Main-thread plugin state: the instance, its load/activation state and the shared block.
pub struct PluginState {
    pub instance_id: InstanceId,
    pub bundle: PluginBundle,
    pub instance: PluginInstance<SubprocessHost>,
    pub shared: Arc<SubprocessHostShared>,
    pub gui_open: bool,
    pub activated: bool,
    pub processing: bool,
    pub sample_rate: f32,
    pub max_buffer_size: usize,
    /// The instance's shared block, also handed to the audio thread on activation.
    pub shared_memory: Arc<SharedMemory>,
    /// Frames the plugin reported at activation (for latency compensation, Phase 8).
    pub latency_frames: u32,
    /// None until first needed (or after a rescan invalidates it). Published to the audio thread
    /// whenever it is (re)built.
    pub param_map: Option<Arc<ParamMap>>,
}

impl PluginState {
    /// The parameter map, built on first use.
    pub fn param_map(&mut self) -> &Arc<ParamMap> {
        if self.param_map.is_none() {
            self.param_map = Some(Arc::new(ParamMap::build(&mut self.instance)));
        }
        self.param_map.as_ref().expect("built above")
    }

    /// Drop the cached map so the next use rebuilds it (the plugin rescanned its parameters).
    /// Returns true when a rebuild is needed.
    pub fn invalidate_param_map(&mut self) -> bool {
        self.param_map.take().is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_and_denormalize_round_trip() {
        let entry = ParamEntry {
            clap_id: ClapId::new(3),
            min: -12.0,
            max: 12.0,
        };
        let normalized = entry.normalize(0.0);
        assert!((normalized - 0.5).abs() < 1e-6);
        assert!((entry.denormalize(normalized) - 0.0).abs() < 1e-6);
    }

    #[test]
    fn normalize_handles_a_zero_range() {
        let entry = ParamEntry {
            clap_id: ClapId::new(1),
            min: 5.0,
            max: 5.0,
        };
        assert_eq!(entry.normalize(5.0), 0.5);
    }
}
