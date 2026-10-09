//! Clip data (MIDI notes or audio PCM), clip instances placed on the timeline, and the audio
//! clip time-stretch maths.

use super::types::*;

/// MIDI note stored in a Clip (relative to clip start)
#[derive(Debug, Clone)]
pub struct ClipNote {
    pub id: NoteId,
    pub note: MidiNote,
    /// Note-on velocity, normalized (0, 1].
    pub velocity: f32,
    /// Release velocity, normalized [0, 1]. Defaults to `DEFAULT_RELEASE`.
    pub release: f32,
    pub start_tick: Tick, // Relative to clip start (0-based)
    pub duration_ticks: Tick,
}

/// Clip type enumeration
#[derive(Debug, Clone, PartialEq)]
pub enum ClipType {
    Midi,
    Audio,
}

/// Runtime load state for audio clips
#[derive(Debug, Clone, PartialEq)]
pub enum ClipLoadState {
    Unloaded,
    Loading {
        req_id: String,
    },
    Ready {
        req_id: String,
    },
    Failed {
        req_id: Option<String>,
        message: String,
    },
}

/// Clip - Pure data (MIDI notes or audio), no timeline position
#[derive(Debug, Clone)]
pub struct Clip {
    pub id: ClipId,
    pub name: String,
    pub clip_type: ClipType,
    pub midi_notes: Vec<ClipNote>,  // For MIDI clips
    pub audio_samples: Vec<f32>,    // For audio clips (interleaved stereo)
    pub audio_channels: usize,      // 1 or 2
    pub audio_sample_rate: u32,     // Samples per second
    pub content_length_ticks: Tick, // Length of the content
    pub recorded_bpm: f32,          // BPM audio was recorded at (for time-stretching)
    pub audio_source_path: Option<String>,
    pub waveform_cache_key: Option<String>,
    pub load_state: ClipLoadState,
}

impl Clip {
    pub fn new(id: ClipId, name: String, clip_type: ClipType) -> Self {
        Self {
            id,
            name,
            clip_type,
            midi_notes: Vec::new(),
            audio_samples: Vec::new(),
            audio_channels: 2,
            audio_sample_rate: 48000,
            content_length_ticks: 0,
            recorded_bpm: 120.0,
            audio_source_path: None,
            waveform_cache_key: None,
            load_state: ClipLoadState::Unloaded,
        }
    }
}

/// ClipInstance - Reference to a Clip + timeline position + playback parameters
#[derive(Debug, Clone)]
pub struct ClipInstance {
    pub id: ClipInstanceId,
    pub clip_id: ClipId,
    pub start_tick: Tick,     // Position on timeline
    pub duration_ticks: Tick, // How long to play (may differ from clip content length)
    pub clip_offset: Tick,    // Offset into clip content (allows trimming from left edge)
    pub transpose: i8,        // Semitones (-12 to +12)
    pub gain_offset: f32,     // dB offset
    pub muted: bool,
    pub loop_enabled: bool,
    pub loop_start_ticks: Tick, // Loop region start, in clip content ticks (includes `clip_offset`)
    pub loop_length_ticks: Tick,
    /// Audio clips: read the source samples backwards (mirrored around the clip's centre).
    pub reverse: bool,
    /// Audio clips: fractional read position in the clip's samples while the playhead is inside
    /// this instance. None until playback enters it; reset on seek, stop and edits.
    pub playback_position: Option<f64>,
}

impl ClipInstance {
    pub fn new(
        id: ClipInstanceId,
        clip_id: ClipId,
        start_tick: Tick,
        duration_ticks: Tick,
    ) -> Self {
        Self {
            id,
            clip_id,
            start_tick,
            duration_ticks,
            clip_offset: 0,
            transpose: 0,
            gain_offset: 0.0,
            muted: false,
            loop_enabled: false,
            loop_start_ticks: 0,
            loop_length_ticks: 0,
            reverse: false,
            playback_position: None,
        }
    }

    pub fn end_tick(&self) -> Tick {
        self.start_tick + self.duration_ticks
    }

    /// Fold a content position past the loop end back into the loop region. Positions before
    /// the loop start, and all positions when looping is off, pass through.
    pub fn wrap_content_tick(&self, content_tick: Tick) -> Tick {
        if self.loop_enabled && self.loop_length_ticks > 0 && content_tick >= self.loop_start_ticks
        {
            self.loop_start_ticks + (content_tick - self.loop_start_ticks) % self.loop_length_ticks
        } else {
            content_tick
        }
    }
}

/// Namespace for the audio clip time-stretch maths (source frame and advance rate per device
/// frame). It holds no state; playback position lives in the clip instance render loop.
#[derive(Debug, Clone)]
pub struct AudioPlayback;

impl AudioPlayback {
    /// Source frame reached `offset_ticks` into an audio clip recorded at `recorded_bpm`. Depends
    /// only on the clip's own timeline, never on the project tempo.
    pub fn clip_source_frame(offset_ticks: Tick, recorded_bpm: f32, ppq: i32, clip_sr: f64) -> f64 {
        offset_ticks as f64 / ppq as f64 * 60.0 / recorded_bpm as f64 * clip_sr
    }

    /// Source frames to advance per device frame while the project plays at `frame_bpm`.
    pub fn clip_advance_per_frame(
        frame_bpm: f64,
        recorded_bpm: f32,
        clip_sr: f64,
        device_sr: f64,
    ) -> f64 {
        frame_bpm / recorded_bpm as f64 * clip_sr / device_sr
    }

    /// Source frame a reversed instance reads at `playback_pos`: the file mirrored around its
    /// centre, so position 0 reads the last frame. Positions past the end clamp to frame 0.
    pub fn reverse_source_frame(playback_pos: f64, sample_len: f64) -> f64 {
        ((sample_len - 1.0) - playback_pos).max(0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_content_tick_folds_into_loop_region() {
        let mut inst = ClipInstance::new("i".to_string(), "c".to_string(), 0, 10_000);
        assert_eq!(
            inst.wrap_content_tick(5_000),
            5_000,
            "no loop passes through"
        );

        inst.loop_enabled = true;
        inst.loop_start_ticks = 960;
        inst.loop_length_ticks = 1_920;
        assert_eq!(
            inst.wrap_content_tick(500),
            500,
            "before the loop start is untouched"
        );
        assert_eq!(
            inst.wrap_content_tick(2_879),
            2_879,
            "inside the first pass"
        );
        assert_eq!(
            inst.wrap_content_tick(2_880),
            960,
            "loop end wraps to loop start"
        );
        assert_eq!(inst.wrap_content_tick(3_000), 1_080);
    }
}
