//! Clip data (MIDI notes or audio PCM), clip instances placed on the timeline, and the audio
//! clip time-stretch maths.

use super::tempo_map::TempoMap;
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

/// How an audio clip's source is laid onto the timeline (spec 029).
///
/// `Raw` plays at native speed whatever the project tempo; `Repitch` is varispeed
/// (`bpm_at / clip_tempo`); `Stretch` will keep pitch (Phase 4) and plays like `Repitch` until then.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum StretchMode {
    Raw,
    #[default]
    Repitch,
    Stretch,
}

impl StretchMode {
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "raw" => Some(Self::Raw),
            "repitch" => Some(Self::Repitch),
            "stretch" => Some(Self::Stretch),
            _ => None,
        }
    }

    /// The mode the render actually uses: `Stretch` falls back to `Repitch` until Phase 4.
    pub fn effective(self) -> Self {
        match self {
            Self::Stretch => Self::Repitch,
            other => other,
        }
    }
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
    pub recorded_bpm: f32,          // Clip tempo: BPM of the material (Repitch/Stretch rate)
    pub stretch_mode: StretchMode,
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
            stretch_mode: StretchMode::default(),
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
    /// `gain_offset` as a linear factor, refreshed once per buffer by the audio clip render so
    /// the per-frame mix needs no `powf`.
    pub gain_linear: f32,
    pub muted: bool,
    pub loop_enabled: bool,
    pub loop_start_ticks: Tick, // Loop region start, in clip content ticks (includes `clip_offset`)
    pub loop_length_ticks: Tick,
    /// Audio clips: read the source samples backwards (mirrored around the clip's centre).
    pub reverse: bool,
    /// Audio clips: fractional read position in the clip's samples while the playhead is inside
    /// this instance. None until playback enters it; reset on seek, stop and edits.
    pub playback_position: Option<f64>,
    /// Raw mode: loop start and length in source frames, computed when the instance is seated
    /// so the audio callback needs no tempo-map search per frame.
    pub raw_loop_frames: (f64, f64),
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
            gain_linear: 1.0,
            muted: false,
            loop_enabled: false,
            loop_start_ticks: 0,
            loop_length_ticks: 0,
            reverse: false,
            playback_position: None,
            raw_loop_frames: (0.0, 0.0),
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

    /// Raw mode: source frame reached at content tick `content_tick` of an instance whose
    /// content tick 0 sits at timeline tick `origin` (`start_tick - clip_offset`). Content ticks
    /// become seconds through the tempo map, so the result depends on where the instance sits.
    pub fn raw_source_frame(
        content_tick: Tick,
        origin: Tick,
        tempo_map: &TempoMap,
        fallback_bpm: f64,
        ppq: i32,
        clip_sr: f64,
    ) -> f64 {
        let ppq = ppq as f64;
        let t0 = tempo_map.seconds_at(origin as f64, fallback_bpm, ppq);
        let t1 = tempo_map.seconds_at((origin + content_tick) as f64, fallback_bpm, ppq);
        (t1 - t0) * clip_sr
    }

    /// Raw mode: source frames to advance per device frame (tempo never matters).
    pub fn raw_advance_per_frame(clip_sr: f64, device_sr: f64) -> f64 {
        clip_sr / device_sr
    }

    /// Raw mode: loop start and length in source frames. `loop_start_ticks` is in content ticks
    /// (it includes `clip_offset`), the length is measured from the loop start.
    pub fn raw_loop_frames(
        loop_start_ticks: Tick,
        loop_length_ticks: Tick,
        origin: Tick,
        tempo_map: &TempoMap,
        fallback_bpm: f64,
        ppq: i32,
        clip_sr: f64,
    ) -> (f64, f64) {
        let start = Self::raw_source_frame(
            loop_start_ticks,
            origin,
            tempo_map,
            fallback_bpm,
            ppq,
            clip_sr,
        );
        let end = Self::raw_source_frame(
            loop_start_ticks + loop_length_ticks,
            origin,
            tempo_map,
            fallback_bpm,
            ppq,
            clip_sr,
        );
        (start, end - start)
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

    const SR: f64 = 48_000.0;

    #[test]
    fn raw_frame_constant_tempo() {
        let map = TempoMap::default();
        // One beat at 120 BPM is 0.5 s; at 60 BPM 1 s. Origin position is irrelevant.
        for origin in [0, 5_000, -960] {
            assert!(
                (AudioPlayback::raw_source_frame(960, origin, &map, 120.0, 960, SR) - 24_000.0)
                    .abs()
                    < 1e-6
            );
            assert!(
                (AudioPlayback::raw_source_frame(960, origin, &map, 60.0, 960, SR) - 48_000.0)
                    .abs()
                    < 1e-6
            );
        }
        assert_eq!(
            AudioPlayback::raw_advance_per_frame(44_100.0, 48_000.0),
            0.91875
        );
    }

    #[test]
    fn raw_frame_follows_tempo_ramp() {
        // 60 BPM for the first beat, ramping to 120 BPM at tick 1920 (linear in ticks).
        let map = TempoMap::from_points(vec![(0, 60.0), (960, 60.0), (1920, 120.0)]);
        let ppq = 960.0;
        // First beat: exactly 1 s
        let f = AudioPlayback::raw_source_frame(960, 0, &map, 120.0, 960, SR);
        assert!((f - SR).abs() < 1e-6);
        // Second beat ramps 60 -> 120: seconds = 60*len/(db) * ln(b1/b0) / ppq
        let ramp = 60.0 * 960.0 / 60.0 * 2f64.ln() / ppq;
        let f = AudioPlayback::raw_source_frame(1920, 0, &map, 120.0, 960, SR);
        assert!((f - (1.0 + ramp) * SR).abs() < 1e-3, "{f}");
        // Anchored at an origin inside the ramp: only the elapsed part counts
        let f = AudioPlayback::raw_source_frame(960, 960, &map, 120.0, 960, SR);
        assert!((f - ramp * SR).abs() < 1e-3);
        // Time before the first beat is not affected by the later ramp
        assert!(AudioPlayback::raw_source_frame(480, 0, &map, 120.0, 960, SR) < SR);
    }

    #[test]
    fn raw_seek_into_a_loop_folds_before_converting() {
        let map = TempoMap::default();
        let mut inst = ClipInstance::new("i".to_string(), "c".to_string(), 1_920, 10_000);
        inst.clip_offset = 960;
        inst.loop_enabled = true;
        inst.loop_start_ticks = 960; // includes clip_offset
        inst.loop_length_ticks = 960;
        let origin = inst.start_tick - inst.clip_offset;
        // 2.5 beats into the instance: content tick 960 + 2400 = 3360 folds to 960 + 480
        let c = inst.wrap_content_tick(inst.clip_offset + 2_400);
        assert_eq!(c, 1_440);
        let f = AudioPlayback::raw_source_frame(c, origin, &map, 120.0, 960, SR);
        assert!((f - 36_000.0).abs() < 1e-6, "{f}");
        // Loop region in frames: starts one beat (0.5 s) in, one beat (0.5 s) long
        let (start, len) = AudioPlayback::raw_loop_frames(960, 960, origin, &map, 120.0, 960, SR);
        assert!((start - 24_000.0).abs() < 1e-6 && (len - 24_000.0).abs() < 1e-6);
        // Under a ramp the loop length is the time that region takes at its place on the map
        let ramp = TempoMap::from_points(vec![(0, 60.0), (960, 60.0), (1920, 120.0)]);
        let (start, len) = AudioPlayback::raw_loop_frames(960, 960, 0, &ramp, 120.0, 960, SR);
        assert!((start - SR).abs() < 1e-6);
        assert!(len < SR && len > 0.5 * SR, "{len}");
    }

    #[test]
    fn raw_reverse_mirrors_the_raw_position() {
        let map = TempoMap::default();
        let pos = AudioPlayback::raw_source_frame(960, 0, &map, 120.0, 960, SR);
        assert_eq!(
            AudioPlayback::reverse_source_frame(pos, 100_000.0),
            99_999.0 - 24_000.0
        );
    }

    #[test]
    fn stretch_mode_parse_and_fallback() {
        assert_eq!(StretchMode::parse("raw"), Some(StretchMode::Raw));
        assert_eq!(StretchMode::parse("bogus"), None);
        assert_eq!(StretchMode::Stretch.effective(), StretchMode::Repitch);
        assert_eq!(StretchMode::Raw.effective(), StretchMode::Raw);
    }
}
