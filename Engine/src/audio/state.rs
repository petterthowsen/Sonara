//! `EngineState`: the project and transport state shared by the audio callback and the command
//! thread.

use crate::audio::block_clock::BlockClock;
use crate::audio::channel::Channel;
use crate::audio::clip::Clip;
use crate::audio::project::ProjectSettings;
use crate::audio::render_scratch::RenderScratch;
use crate::audio::tempo_map::TempoMap;
use crate::audio::time_signature_map::TimeSignatureMap;
use crate::audio::track::Track;
use crate::audio::types::{ChannelId, ClipId, Tick, TrackId};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;
use tracing::info;

/// Shared state between audio thread and command thread
pub struct EngineState {
    pub settings: ProjectSettings,
    /// Rate of the running output stream. Changed only by the command thread while the stream
    /// is stopped (Phase 7).
    pub device_sample_rate: f32,
    pub channels: HashMap<ChannelId, Channel>,
    pub tracks: HashMap<TrackId, Track>,
    pub clips: HashMap<ClipId, Clip>, // Global clip pool
    /// Preallocated scratch lists so the audio callback doesn't allocate
    pub render_scratch: RenderScratch,
    /// Tempo automation; empty means the static `settings.tempo` applies.
    pub tempo_map: TempoMap,
    pub time_signature_map: TimeSignatureMap,
    pub is_playing: AtomicBool,
    pub current_tick: AtomicI64,
    /// Fractional tick accumulator carried across buffers for sample-accurate scheduling (stored as fixed-point * 1e9)
    pub fractional_tick_accumulator: AtomicI64,
    /// When true, the next playing callback dispatches MIDI at the playhead tick (play/seek).
    pub dispatch_playhead_tick: AtomicBool,
    /// Active loop region `[start, end)` in ticks; `None` while loop is off or the region is empty.
    pub loop_region: Option<(Tick, Tick)>,
    /// One absolute plugin deadline per callback, shared with subprocess plugin adapters.
    pub block_clock: Arc<BlockClock>,
    /// An offline render owns the devices and the transport (`audio/render`). The live
    /// callback holds a clone and outputs silence while it is set; transport commands are
    /// ignored.
    pub rendering: Arc<AtomicBool>,
}

impl EngineState {
    /// Get the current tick (lock-free)
    pub fn get_current_tick(&self) -> Tick {
        self.current_tick.load(Ordering::Acquire) as Tick
    }

    /// Set the current tick (lock-free)
    pub fn set_current_tick(&self, tick: Tick) {
        self.current_tick.store(tick as i64, Ordering::Release);
    }

    /// Get the fractional tick accumulator (lock-free)
    pub fn get_fractional_tick_accumulator(&self) -> f64 {
        self.fractional_tick_accumulator.load(Ordering::Acquire) as f64 / 1_000_000_000.0
    }

    /// Set the fractional tick accumulator (lock-free)
    pub fn set_fractional_tick_accumulator(&self, value: f64) {
        self.fractional_tick_accumulator
            .store((value * 1_000_000_000.0) as i64, Ordering::Release);
    }

    /// Get playing state (lock-free)
    pub fn get_is_playing(&self) -> bool {
        self.is_playing.load(Ordering::Acquire)
    }

    /// Set playing state (lock-free)
    pub fn set_is_playing(&self, playing: bool) {
        self.is_playing.store(playing, Ordering::Release);
    }

    /// True while an offline render runs.
    pub fn is_rendering(&self) -> bool {
        self.rendering.load(Ordering::Acquire)
    }

    /// Ask the next playing callback to fire clip MIDI at the current playhead tick.
    pub fn request_playhead_midi_dispatch(&self) {
        self.dispatch_playhead_tick.store(true, Ordering::Release);
    }

    /// Consume the playhead MIDI dispatch flag. True only for the first buffer after play/seek.
    pub fn take_playhead_midi_dispatch(&self) -> bool {
        self.dispatch_playhead_tick.swap(false, Ordering::AcqRel)
    }

    /// Create master (ID 1) routed to the default hardware output if it is missing.
    ///
    /// Without this, a Godot session that outlives an engine restart still routes tracks to
    /// channel 1, but that channel does not exist: meters stay at zero and the CPAL buffer
    /// stays silent.
    pub fn ensure_master_channel(&mut self, buffer_size: usize) {
        if self.channels.contains_key(&1) {
            return;
        }
        let mut master = Channel::new(
            1,
            "Master".to_string(),
            buffer_size,
            self.device_sample_rate,
        );
        master.output_channel_id = Some(1000);
        self.channels.insert(1, master);
        info!("Master channel created (hardware output 1000)");
    }
}

impl Default for EngineState {
    fn default() -> Self {
        Self {
            settings: ProjectSettings::default(),
            device_sample_rate: 48000.0, // Default, will be overridden
            channels: HashMap::new(),
            tracks: HashMap::new(),
            clips: HashMap::new(),
            render_scratch: RenderScratch::default(),
            tempo_map: TempoMap::default(),
            time_signature_map: TimeSignatureMap::default(),
            is_playing: AtomicBool::new(false),
            current_tick: AtomicI64::new(0),
            fractional_tick_accumulator: AtomicI64::new(0),
            dispatch_playhead_tick: AtomicBool::new(false),
            loop_region: None,
            block_clock: Arc::new(BlockClock::new()),
            rendering: Arc::new(AtomicBool::new(false)),
        }
    }
}
