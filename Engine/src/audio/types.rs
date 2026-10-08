use super::active_notes::{ActiveNotes, NoteSource};
use super::devices::container::{ChainCursor, ChainStep};
use super::devices::AudioDevice;
use super::midi_types::{
    create_midi_queue, MidiEvent, MidiEventQueue, MidiRouting, NoteEvent, DEFAULT_RELEASE,
};
use super::render_scratch::{ClipNoteEvent, MixBuffers};
/// Value kind for setting device parameters
#[derive(Debug, Clone, Copy)]
pub enum ParamSetValue {
    /// Normalized value 0.0..1.0
    Normalized(f32),
    /// Discrete index for bool/enum (0/1 for bool, 0..N-1 for enum)
    Index(i32),
}

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

#[cfg(target_arch = "aarch64")]
use std::arch::aarch64::*;

/// SIMD-optimized stereo interleaving: L[0], L[1], L[2]... + R[0], R[1], R[2]... → LR[0], LR[1], LR[2], LR[3]...
#[inline]
fn interleave_stereo(left: &[f32], right: &[f32], output: &mut [f32]) {
    let frames = left.len().min(right.len());
    debug_assert_eq!(output.len(), frames * 2);

    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("avx") {
            unsafe {
                interleave_stereo_avx(left, right, output, frames);
            }
            return;
        }
        if is_x86_feature_detected!("sse") {
            unsafe {
                interleave_stereo_sse(left, right, output, frames);
            }
            return;
        }
    }

    #[cfg(target_arch = "aarch64")]
    {
        if std::arch::is_aarch64_feature_detected!("neon") {
            unsafe {
                interleave_stereo_neon(left, right, output, frames);
            }
            return;
        }
    }

    // Fallback: scalar
    for i in 0..frames {
        output[i * 2] = left[i];
        output[i * 2 + 1] = right[i];
    }
}

/// SIMD-optimized stereo de-interleaving: LR[0], LR[1], LR[2], LR[3]... → L[0], L[1]... + R[0], R[1]...
#[inline]
fn deinterleave_stereo(input: &[f32], left: &mut [f32], right: &mut [f32]) {
    let frames = left.len().min(right.len());
    debug_assert_eq!(input.len(), frames * 2);

    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("avx") {
            unsafe {
                deinterleave_stereo_avx(input, left, right, frames);
            }
            return;
        }
        if is_x86_feature_detected!("sse") {
            unsafe {
                deinterleave_stereo_sse(input, left, right, frames);
            }
            return;
        }
    }

    #[cfg(target_arch = "aarch64")]
    {
        if std::arch::is_aarch64_feature_detected!("neon") {
            unsafe {
                deinterleave_stereo_neon(input, left, right, frames);
            }
            return;
        }
    }

    // Fallback: scalar
    for i in 0..frames {
        left[i] = input[i * 2];
        right[i] = input[i * 2 + 1];
    }
}

// x86_64 AVX implementations
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx")]
unsafe fn interleave_stereo_avx(left: &[f32], right: &[f32], output: &mut [f32], frames: usize) {
    let mut i = 0;
    // Process 8 frames at a time (8 L + 8 R → 16 interleaved)
    while i + 8 <= frames {
        let l = _mm256_loadu_ps(left.as_ptr().add(i));
        let r = _mm256_loadu_ps(right.as_ptr().add(i));

        // Unpack low/high to interleave
        let lr_low = _mm256_unpacklo_ps(l, r); // L0 R0 L1 R1 | L4 R4 L5 R5
        let lr_high = _mm256_unpackhi_ps(l, r); // L2 R2 L3 R3 | L6 R6 L7 R7

        // Permute to get correct order: L0 R0 L1 R1 L2 R2 L3 R3 | L4 R4 L5 R5 L6 R6 L7 R7
        let interleaved_low = _mm256_permute2f128_ps(lr_low, lr_high, 0x20);
        let interleaved_high = _mm256_permute2f128_ps(lr_low, lr_high, 0x31);

        _mm256_storeu_ps(output.as_mut_ptr().add(i * 2), interleaved_low);
        _mm256_storeu_ps(output.as_mut_ptr().add(i * 2 + 8), interleaved_high);

        i += 8;
    }

    // Scalar tail
    while i < frames {
        *output.get_unchecked_mut(i * 2) = *left.get_unchecked(i);
        *output.get_unchecked_mut(i * 2 + 1) = *right.get_unchecked(i);
        i += 1;
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx")]
unsafe fn deinterleave_stereo_avx(
    input: &[f32],
    left: &mut [f32],
    right: &mut [f32],
    frames: usize,
) {
    let mut i = 0;
    // Process 8 frames at a time (16 interleaved → 8 L + 8 R)
    while i + 8 <= frames {
        let interleaved_low = _mm256_loadu_ps(input.as_ptr().add(i * 2));
        let interleaved_high = _mm256_loadu_ps(input.as_ptr().add(i * 2 + 8));

        // Permute to group L and R channels
        let lr_low = _mm256_permute2f128_ps(interleaved_low, interleaved_high, 0x20);
        let lr_high = _mm256_permute2f128_ps(interleaved_low, interleaved_high, 0x31);

        // Shuffle to separate L and R
        let l = _mm256_shuffle_ps(lr_low, lr_high, 0b10001000); // Select L channels
        let r = _mm256_shuffle_ps(lr_low, lr_high, 0b11011101); // Select R channels

        _mm256_storeu_ps(left.as_mut_ptr().add(i), l);
        _mm256_storeu_ps(right.as_mut_ptr().add(i), r);

        i += 8;
    }

    // Scalar tail
    while i < frames {
        *left.get_unchecked_mut(i) = *input.get_unchecked(i * 2);
        *right.get_unchecked_mut(i) = *input.get_unchecked(i * 2 + 1);
        i += 1;
    }
}

// x86_64 SSE implementations
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse")]
unsafe fn interleave_stereo_sse(left: &[f32], right: &[f32], output: &mut [f32], frames: usize) {
    let mut i = 0;
    // Process 4 frames at a time (4 L + 4 R → 8 interleaved)
    while i + 4 <= frames {
        let l = _mm_loadu_ps(left.as_ptr().add(i));
        let r = _mm_loadu_ps(right.as_ptr().add(i));

        let lr_low = _mm_unpacklo_ps(l, r); // L0 R0 L1 R1
        let lr_high = _mm_unpackhi_ps(l, r); // L2 R2 L3 R3

        _mm_storeu_ps(output.as_mut_ptr().add(i * 2), lr_low);
        _mm_storeu_ps(output.as_mut_ptr().add(i * 2 + 4), lr_high);

        i += 4;
    }

    // Scalar tail
    while i < frames {
        *output.get_unchecked_mut(i * 2) = *left.get_unchecked(i);
        *output.get_unchecked_mut(i * 2 + 1) = *right.get_unchecked(i);
        i += 1;
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse")]
unsafe fn deinterleave_stereo_sse(
    input: &[f32],
    left: &mut [f32],
    right: &mut [f32],
    frames: usize,
) {
    let mut i = 0;
    // Process 4 frames at a time (8 interleaved → 4 L + 4 R)
    while i + 4 <= frames {
        let interleaved_low = _mm_loadu_ps(input.as_ptr().add(i * 2));
        let interleaved_high = _mm_loadu_ps(input.as_ptr().add(i * 2 + 4));

        // Shuffle to separate L and R: select indices 0,2,4,6 for L and 1,3,5,7 for R
        let l = _mm_shuffle_ps(interleaved_low, interleaved_high, 0b10001000); // L0 L1 L2 L3
        let r = _mm_shuffle_ps(interleaved_low, interleaved_high, 0b11011101); // R0 R1 R2 R3

        _mm_storeu_ps(left.as_mut_ptr().add(i), l);
        _mm_storeu_ps(right.as_mut_ptr().add(i), r);

        i += 4;
    }

    // Scalar tail
    while i < frames {
        *left.get_unchecked_mut(i) = *input.get_unchecked(i * 2);
        *right.get_unchecked_mut(i) = *input.get_unchecked(i * 2 + 1);
        i += 1;
    }
}

// ARM NEON implementations
#[cfg(target_arch = "aarch64")]
#[target_feature(enable = "neon")]
unsafe fn interleave_stereo_neon(left: &[f32], right: &[f32], output: &mut [f32], frames: usize) {
    let mut i = 0;
    // Process 4 frames at a time
    while i + 4 <= frames {
        let l = vld1q_f32(left.as_ptr().add(i));
        let r = vld1q_f32(right.as_ptr().add(i));

        // Interleave using zip
        let interleaved = float32x4x2_t(l, r);
        vst2q_f32(output.as_mut_ptr().add(i * 2), interleaved);

        i += 4;
    }

    // Scalar tail
    while i < frames {
        *output.get_unchecked_mut(i * 2) = *left.get_unchecked(i);
        *output.get_unchecked_mut(i * 2 + 1) = *right.get_unchecked(i);
        i += 1;
    }
}

#[cfg(target_arch = "aarch64")]
#[target_feature(enable = "neon")]
unsafe fn deinterleave_stereo_neon(
    input: &[f32],
    left: &mut [f32],
    right: &mut [f32],
    frames: usize,
) {
    let mut i = 0;
    // Process 4 frames at a time
    while i + 4 <= frames {
        let interleaved = vld2q_f32(input.as_ptr().add(i * 2));

        vst1q_f32(left.as_mut_ptr().add(i), interleaved.0);
        vst1q_f32(right.as_mut_ptr().add(i), interleaved.1);

        i += 4;
    }

    // Scalar tail
    while i < frames {
        *left.get_unchecked_mut(i) = *input.get_unchecked(i * 2);
        *right.get_unchecked_mut(i) = *input.get_unchecked(i * 2 + 1);
        i += 1;
    }
}

/// RMS integration time constant, matching the standard 300 ms RMS window.
const RMS_WINDOW_SECONDS: f32 = 0.3;

/// Pan mode enumeration (matches Godot's PanMode enum)
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PanMode {
    /// Cubase-style combined panner: the left and right inputs sit at handles
    /// `position - width` and `position + width`, each constant-power panned.
    StereoCombined = 0,
    /// Independent constant-power pan handles for the left and right inputs.
    StereoDual = 1,
    /// Linear balance: attenuates only the input opposite to the pan direction. The default.
    StereoBalance = 2,
    /// Sums the inputs as (L+R)/2 and constant-power pans the sum.
    Mono = 3,
}

impl Default for PanMode {
    fn default() -> Self {
        PanMode::StereoBalance
    }
}

impl From<i32> for PanMode {
    fn from(value: i32) -> Self {
        match value {
            0 => PanMode::StereoCombined,
            1 => PanMode::StereoDual,
            2 => PanMode::StereoBalance,
            3 => PanMode::Mono,
            _ => PanMode::StereoCombined,
        }
    }
}

/// Pan coefficients for mixing
#[derive(Debug, Clone, Copy)]
pub struct PanCoefficients {
    pub left_to_left: f32,
    pub right_to_right: f32,
    pub left_to_right: f32,
    pub right_to_left: f32,
}

/// MIDI note number (0-127)
pub type MidiNote = u8;

/// Position in ticks
pub type Tick = i64;

/// Channel ID
///
/// ID Allocation Scheme:
/// - 0: Null/no output (reserved, channels routing to 0 won't output anywhere)
/// - 1: Master channel (always present, created by Godot on project init, routes to ID 1000)
/// - 2-999: User mixer channels (created dynamically by user)
/// - 1000+: Stereo output pairs on the selected output device (`HARDWARE_OUTPUT_BASE`):
///   1000 = outputs 1/2, 1001 = 3/4, and so on. A pair the device doesn't have plays on 1/2.
pub type ChannelId = usize;

/// First hardware output ID: outputs 1/2 of the selected device.
pub const HARDWARE_OUTPUT_BASE: ChannelId = 1000;

/// Track ID
pub type TrackId = usize;

/// Unique identifier for scheduled notes
pub type NoteId = u64;

/// Unique identifier for clips (GUID from Godot)
pub type ClipId = String;

/// Unique identifier for clip instances (GUID from Godot)
pub type ClipInstanceId = String;

/// Sleep changes one channel can report in a buffer without growing `Channel::sleep_changes`.
const MAX_SLEEP_CHANGES: usize = 64;

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

/// Send routing configuration
#[derive(Debug, Clone)]
pub struct Send {
    pub target_channel_id: ChannelId, // Must be a BUS channel
    pub amount_db: f32,               // Send level in dB (-60.0 to +12.0)
    pub pre_fader: bool, // If true, send before channel fader; if false, send after fader
    pub muted: bool,     // Mute this send
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

/// Audio channel for mixing
pub struct Channel {
    pub id: ChannelId,
    pub name: String,
    pub volume_db: f32, // dB (-60.0 to +12.0)
    pub pan: f32,       // -1.0 (left) to +1.0 (right) for STEREO_COMBINED/MONO/BALANCE
    /// Normalized 0.0-1.0 automation override for the fader. `None` means the base `volume_db` is
    /// used. Written only by the automation pass on the audio callback; never writes `volume_db`.
    pub automation_volume: Option<f32>,
    /// Normalized 0.0-1.0 automation override for `pan`, with the same ownership as
    /// `automation_volume`. Ignored in `PanMode::StereoDual`, which has two independent controls
    /// and so no single automatable pan target.
    pub automation_pan: Option<f32>,
    pub pan_left: f32,  // For STEREO_DUAL mode
    pub pan_right: f32, // For STEREO_DUAL mode
    /// Spread of the two handles around `pan` in `PanMode::StereoCombined`, -1.0..1.0. Negative
    /// swaps the sides. Not automatable.
    pub pan_width: f32,
    pub pan_mode: PanMode, // Pan mode (combined, dual, balance, mono)
    pub mute: bool,
    pub solo: bool,
    pub output_channel_id: Option<ChannelId>, // None for master/no output

    // Sends (parallel routing to BUS channels)
    pub send_channels: Vec<Send>,

    // Runtime state (stereo)
    pub buffer_left: Vec<f32>,
    pub buffer_right: Vec<f32>,
    pub peak_left: f32,
    pub peak_right: f32,
    pub rms_left: f32,
    pub rms_right: f32,
    // Running mean square behind `rms_left`/`rms_right` (internal)
    mean_square_left: f32,
    mean_square_right: f32,

    // Parameter smoothing (prevents clicks/pops when changing volume)
    current_gain: f32,    // Smoothed gain value (internal)
    smoothing_alpha: f32, // Smoothing coefficient (internal)

    // Device chain for processing (instruments or effects)
    pub devices: Vec<Box<dyn AudioDevice>>,

    /// Notes sounding on this channel (clip and live), each with its sounding-note id. Stop,
    /// pause and seek release the clip notes with note-offs instead of resetting devices, so
    /// releases and tails ring out.
    pub active_notes: ActiveNotes,

    // MIDI routing configuration
    pub midi_routing: MidiRouting,

    // Incoming MIDI event queue (non-audio thread writes, audio thread reads)
    pub midi_queue: MidiEventQueue,

    // Scheduled MIDI events for current audio buffer (sorted by frame_offset)
    pub scheduled_midi_events: Vec<MidiEvent>,

    // Temporary interleaved buffer for device processing
    device_input_buffer: Vec<f32>,
    device_output_buffer: Vec<f32>,

    /// Child channel IDs that receive extra device buses (index = bus). 0 = unmapped.
    pub extra_out_targets: Vec<ChannelId>,
    /// Preallocated interleaved stereo extra-out buses (audio thread must not grow these).
    pub extra_out_buffers: Vec<Vec<f32>>,

    /// `(device_path, is_sleeping)` for devices whose sleep state changed this buffer. Filled by
    /// the device chain, drained by `mix_and_output`. Preallocated: only a buffer where more
    /// than `MAX_SLEEP_CHANGES` devices change at once would grow it.
    pub sleep_changes: Vec<(super::devices::DevicePath, bool)>,

    /// Scratch buffers and flags used by `mix_and_output`
    pub mix: MixBuffers,
}

/// Send a note event through `devices` in chain order, waking those that take note input. It
/// stops at the first note effect, which hands it on in the note phase (spec 027).
fn send_note_event_to(
    devices: &mut [Box<dyn AudioDevice>],
    event: &NoteEvent,
    frame_offset: usize,
) {
    super::devices::note_fx::routing::route_note(devices, event, frame_offset);
}

/// Gain smoothing coefficient for a 5 ms one-pole filter: alpha = 1 - exp(-1 / (tau * rate)).
/// 5 ms is a good balance between smoothness and responsiveness.
fn gain_smoothing_alpha(sample_rate: f32) -> f32 {
    let tau = 0.005;
    1.0 - (-1.0 / (tau * sample_rate as f64)).exp() as f32
}

impl Channel {
    pub fn new(id: ChannelId, name: String, buffer_size: usize, sample_rate: f32) -> Self {
        let smoothing_alpha = gain_smoothing_alpha(sample_rate);

        let initial_gain = if id == 1 {
            // Master channel defaults to 0 dB
            1.0
        } else {
            // Other channels default to -6 dB for headroom
            10.0_f32.powf(-6.0 / 20.0)
        };

        Self {
            id,
            name,
            volume_db: if id == 1 { 0.0 } else { -6.0 },
            pan: 0.0,
            automation_volume: None,
            automation_pan: None,
            pan_left: 0.0,
            pan_right: 0.0,
            pan_width: 1.0,
            pan_mode: PanMode::default(),
            mute: false,
            solo: false,
            output_channel_id: Some(1), // Default to master (ID 1)
            send_channels: Vec::new(),
            buffer_left: vec![0.0; buffer_size],
            buffer_right: vec![0.0; buffer_size],
            peak_left: 0.0,
            peak_right: 0.0,
            rms_left: 0.0,
            rms_right: 0.0,
            mean_square_left: 0.0,
            mean_square_right: 0.0,
            current_gain: initial_gain,
            smoothing_alpha,
            devices: Vec::new(),
            active_notes: ActiveNotes::new(),
            midi_routing: MidiRouting::default(),
            midi_queue: create_midi_queue(),
            // Preallocated so the audio thread doesn't allocate while scheduling
            scheduled_midi_events: Vec::with_capacity(256),
            device_input_buffer: vec![0.0; buffer_size * 2],
            device_output_buffer: vec![0.0; buffer_size * 2],
            extra_out_targets: Vec::new(),
            extra_out_buffers: Vec::new(),
            sleep_changes: Vec::with_capacity(MAX_SLEEP_CHANGES),
            mix: MixBuffers::new(buffer_size),
        }
    }

    /// Adopt a new device sample rate (the stream is stopped while this runs).
    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.smoothing_alpha = gain_smoothing_alpha(sample_rate);
    }

    /// Convert dB to linear gain (target value, not smoothed)
    ///
    /// Prefers the automation override when one is set, leaving `volume_db` — the base value the
    /// project saves — untouched.
    pub fn get_gain(&self) -> f32 {
        let db = match self.automation_volume {
            Some(normalized) => super::automation::normalized_to_db(normalized),
            None => self.volume_db,
        };
        if db <= -60.0 {
            0.0
        } else {
            10.0_f32.powf(db / 20.0)
        }
    }

    /// Pan position in use: the automation override when set, otherwise the base `pan`.
    fn effective_pan(&self) -> f32 {
        match self.automation_pan {
            Some(normalized) => super::automation::normalized_to_pan(normalized),
            None => self.pan,
        }
    }

    /// Get smoothed gain value (advances smoothing by one sample)
    /// Call this once per sample to prevent clicks when changing volume
    pub fn get_smoothed_gain(&mut self) -> f32 {
        let target_gain = self.get_gain();
        // One-pole filter: current += (target - current) * alpha
        self.current_gain += (target_gain - self.current_gain) * self.smoothing_alpha;
        self.current_gain
    }

    /// Get pan coefficients based on current pan mode
    /// Returns a 4-coefficient matrix for stereo-to-stereo panning
    pub fn get_pan_coefficients(&self) -> PanCoefficients {
        use std::f32::consts::FRAC_PI_2;

        let pan = self.effective_pan();

        match self.pan_mode {
            PanMode::StereoCombined => {
                let left = (pan - self.pan_width).clamp(-1.0, 1.0);
                let right = (pan + self.pan_width).clamp(-1.0, 1.0);
                Self::dual_matrix(left, right)
            }
            PanMode::StereoDual => Self::dual_matrix(self.pan_left, self.pan_right),
            PanMode::StereoBalance => {
                // Simple balance: pan < 0 reduces right, pan > 0 reduces left
                let left_gain = if pan <= 0.0 { 1.0 } else { 1.0 - pan };
                let right_gain = if pan >= 0.0 { 1.0 } else { 1.0 + pan };
                PanCoefficients {
                    left_to_left: left_gain,
                    right_to_right: right_gain,
                    left_to_right: 0.0,
                    right_to_left: 0.0,
                }
            }
            PanMode::Mono => {
                // Sum to (L+R)/2, then constant-power pan the sum.
                let angle = (pan + 1.0) * 0.5 * FRAC_PI_2;
                let (to_left, to_right) = (angle.cos() * 0.5, angle.sin() * 0.5);
                PanCoefficients {
                    left_to_left: to_left,
                    right_to_left: to_left,
                    left_to_right: to_right,
                    right_to_right: to_right,
                }
            }
        }
    }

    /// Constant-power matrix placing the left input at handle `l` and the right input at handle
    /// `r`, both in -1.0..1.0.
    fn dual_matrix(l: f32, r: f32) -> PanCoefficients {
        use std::f32::consts::FRAC_PI_2;

        let angle_l = (l + 1.0) * 0.5 * FRAC_PI_2;
        let angle_r = (r + 1.0) * 0.5 * FRAC_PI_2;
        PanCoefficients {
            left_to_left: angle_l.cos(),
            right_to_right: angle_r.sin(),
            left_to_right: angle_l.sin(),
            right_to_left: angle_r.cos(),
        }
    }

    /// Clear the channel buffers
    pub fn clear_buffers(&mut self) {
        self.buffer_left.fill(0.0);
        self.buffer_right.fill(0.0);
    }

    /// Resize all buffers (L/R and device buffers)
    pub fn resize_buffers(&mut self, new_size: usize) {
        self.buffer_left.resize(new_size, 0.0);
        self.buffer_right.resize(new_size, 0.0);
        // Device buffers are interleaved stereo (frames * 2)
        self.device_input_buffer.resize(new_size * 2, 0.0);
        self.device_output_buffer.resize(new_size * 2, 0.0);
        for buf in &mut self.extra_out_buffers {
            buf.resize(new_size * 2, 0.0);
        }
        self.mix.resize(new_size);
    }

    /// Map extra device bus `bus_index` to `target_id` (0 clears). Allocates on the command thread.
    pub fn set_aux_out(&mut self, bus_index: usize, target_id: ChannelId) {
        let interleaved = self.buffer_left.len().saturating_mul(2);
        while self.extra_out_targets.len() <= bus_index {
            self.extra_out_targets.push(0);
            self.extra_out_buffers.push(vec![0.0; interleaved]);
        }
        self.extra_out_targets[bus_index] = target_id;
    }

    /// Accumulate peak and RMS meters for this block (post-fader).
    ///
    /// The buffers already hold post-fader audio (gain/pan applied during mixing), but only the
    /// first `frames` samples are live: buffers are allocated at the engine's maximum block size
    /// and never resized, so the tail is stale zeros and must not be metered.
    ///
    /// Peaks accumulate as a max across every block until `take_meters()` sends them, so a
    /// transient landing between the ~20 Hz status sends is not lost. RMS is a one-pole average of
    /// the mean square with a 300 ms time constant (the standard RMS integration window), which
    /// carries across blocks and so needs no reset.
    pub fn update_peaks(&mut self, frames: usize, sample_rate: f32) {
        let frames = frames.min(self.buffer_left.len());
        if frames == 0 {
            return;
        }
        let left = &self.buffer_left[..frames];
        let right = &self.buffer_right[..frames];

        let block_peak_left = left.iter().map(|s| s.abs()).fold(0.0, f32::max);
        let block_peak_right = right.iter().map(|s| s.abs()).fold(0.0, f32::max);
        self.peak_left = self.peak_left.max(block_peak_left);
        self.peak_right = self.peak_right.max(block_peak_right);

        let n = frames as f32;
        let block_ms_left: f32 = left.iter().map(|s| s * s).sum::<f32>() / n;
        let block_ms_right: f32 = right.iter().map(|s| s * s).sum::<f32>() / n;

        // alpha for a 300 ms time constant over a block of `frames` samples
        let alpha = if sample_rate > 0.0 {
            1.0 - (-(n / (RMS_WINDOW_SECONDS * sample_rate))).exp()
        } else {
            1.0
        };
        self.mean_square_left += (block_ms_left - self.mean_square_left) * alpha;
        self.mean_square_right += (block_ms_right - self.mean_square_right) * alpha;

        self.rms_left = self.mean_square_left.sqrt();
        self.rms_right = self.mean_square_right.sqrt();
    }

    /// Read the accumulated meters and reset the peak accumulators for the next interval.
    /// RMS keeps integrating, so it is only read here.
    pub fn take_meters(&mut self) -> (f32, f32, f32, f32) {
        let meters = (
            self.peak_left,
            self.peak_right,
            self.rms_left,
            self.rms_right,
        );
        self.peak_left = 0.0;
        self.peak_right = 0.0;
        meters
    }

    /// Mix this channel into another channel with volume and pan applied
    pub fn mix_into(&self, target: &mut Channel, gain_multiplier: f32) {
        if self.mute {
            return;
        }

        let gain = self.get_gain() * gain_multiplier;
        let pan = self.get_pan_coefficients();

        // Apply 4-coefficient stereo-to-stereo panning matrix
        for i in 0..self.buffer_left.len().min(target.buffer_left.len()) {
            let left_in = self.buffer_left[i] * gain;
            let right_in = self.buffer_right[i] * gain;

            target.buffer_left[i] += left_in * pan.left_to_left + right_in * pan.right_to_left;
            target.buffer_right[i] += left_in * pan.left_to_right + right_in * pan.right_to_right;
        }
    }

    /// Turn this buffer's scheduled live MIDI into note events for the channel's devices.
    ///
    /// A note-on with velocity > 0 starts a note at `v/127`. A note-off ends it with release
    /// `v/127`, and a note-on with velocity 0 ends it with `DEFAULT_RELEASE`.
    fn dispatch_scheduled_midi(&mut self) {
        use super::midi_types::MidiMessageType;

        for i in 0..self.scheduled_midi_events.len() {
            let event = &self.scheduled_midi_events[i];
            let source = NoteSource::Live {
                midi_channel: event.midi_channel,
            };
            let (key, frame_offset) = (event.note, event.frame_offset);
            let value = event.velocity as f32 / 127.0;
            // `None` starts a note; `Some(release)` ends one.
            let ends_with = match (event.message_type, event.velocity) {
                (MidiMessageType::NoteOn, 0) => Some(DEFAULT_RELEASE),
                (MidiMessageType::NoteOn, _) => None,
                (MidiMessageType::NoteOff, _) => Some(value),
                _ => continue,
            };
            match ends_with {
                None => {
                    let (evicted, on) =
                        self.active_notes
                            .note_on(source, key, value, DEFAULT_RELEASE);
                    if let Some(off) = evicted {
                        self.send_note_event_to_devices(&off, frame_offset);
                    }
                    self.send_note_event_to_devices(&on, frame_offset);
                }
                Some(release) => {
                    if let Some(off) = self.active_notes.note_off(source, key, Some(release)) {
                        self.send_note_event_to_devices(&off, frame_offset);
                    }
                }
            }
        }
    }

    /// Process channel audio through the top-level device chain. Sleep state changes are
    /// appended to `sleep_changes`.
    pub fn process_device_chain(&mut self, sample_count: usize) {
        let mut step = self.begin_device_chain(0, sample_count);
        while step == ChainStep::Parked {
            step = self.resume_device_chain(sample_count);
        }
    }

    /// Dispatch this buffer's live MIDI, then run the note phase: each note effect in the
    /// chain hands its output to the devices after it, before any device renders.
    pub fn dispatch_notes(&mut self, sample_count: usize) {
        self.dispatch_scheduled_midi();
        super::devices::note_fx::routing::run_note_phase(&mut self.devices, sample_count, None);
    }

    /// Index of the device that feeds the extra-out buses: the first one that isn't a note
    /// effect (note effects pass audio through, so they can't be the source; amends spec 006
    /// REQ-007). Equals the device count when there is none.
    pub fn aux_source_index(&self) -> usize {
        self.devices
            .iter()
            .position(|d| !d.is_note_effect())
            .unwrap_or(self.devices.len())
    }

    /// Process the aux-source device into this channel plus extra-out buses (no remaining FX).
    /// Leading note effects only get their note phase: their audio is a pass-through of the
    /// silent input.
    pub fn process_aux_source(&mut self, sample_count: usize) {
        self.dispatch_notes(sample_count);
        let src = self.aux_source_index();
        if src >= self.devices.len() {
            return;
        }

        let has_input_activity =
            super::devices::has_audio_signal(&self.buffer_left[..sample_count])
                || super::devices::has_audio_signal(&self.buffer_right[..sample_count]);

        let interleaved_count = sample_count * 2;
        self.device_input_buffer[..interleaved_count].fill(0.0);
        self.device_output_buffer[..interleaved_count].fill(0.0);

        interleave_stereo(
            &self.buffer_left[..sample_count],
            &self.buffer_right[..sample_count],
            &mut self.device_input_buffer[..sample_count * 2],
        );

        let mut extras = std::mem::take(&mut self.extra_out_buffers);
        let extra_count = self.devices[src].extra_output_bus_count().min(extras.len());
        let section =
            super::rt_debug::device_name("process_block_with_extra", self.devices[src].device_id());
        super::rt_debug::device_section(section, || {
            self.devices[src].process_block_with_extra(
                &self.device_input_buffer,
                &mut self.device_output_buffer,
                &mut extras[..extra_count],
                sample_count,
            )
        });
        self.extra_out_buffers = extras;

        deinterleave_stereo(
            &self.device_output_buffer[..sample_count * 2],
            &mut self.buffer_left[..sample_count],
            &mut self.buffer_right[..sample_count],
        );

        let has_output_activity = super::devices::has_audio_signal(
            &self.device_output_buffer[..interleaved_count.min(self.device_output_buffer.len())],
        );
        if self.devices[src].update_sleep_state(has_input_activity || has_output_activity) {
            self.sleep_changes.push((
                super::devices::DevicePath::root(src),
                self.devices[src].is_sleeping(),
            ));
        }
    }

    /// Process devices starting at `start` (no MIDI dispatch). Used after aux children mix in.
    pub fn process_device_chain_from(&mut self, start: usize, sample_count: usize) {
        let mut step = self.begin_chain_from(start, sample_count);
        while step == ChainStep::Parked {
            step = self.resume_device_chain(sample_count);
        }
    }

    /// Start the device chain from `start`, running devices until one begins a block
    /// asynchronously (`Parked`; finish with `resume_device_chain`) or the chain ends. Scheduled
    /// MIDI is dispatched and the note phase runs when `start` is 0. The channel buffers hold the result once `Done`.
    pub fn begin_device_chain(&mut self, start: usize, sample_count: usize) -> ChainStep {
        if start == 0 {
            super::rt_debug::section("device MIDI dispatch", || self.dispatch_notes(sample_count));
        }
        self.begin_chain_from(start, sample_count)
    }

    /// `begin_device_chain` without MIDI dispatch.
    fn begin_chain_from(&mut self, start: usize, sample_count: usize) -> ChainStep {
        if start >= self.devices.len() {
            return ChainStep::Done {
                result_in_output: false,
            };
        }

        let has_input_activity =
            super::devices::has_audio_signal(&self.buffer_left[..sample_count])
                || super::devices::has_audio_signal(&self.buffer_right[..sample_count]);

        let interleaved_count = sample_count * 2;
        self.device_input_buffer[..interleaved_count].fill(0.0);
        self.device_output_buffer[..interleaved_count].fill(0.0);

        interleave_stereo(
            &self.buffer_left[..sample_count],
            &self.buffer_right[..sample_count],
            &mut self.device_input_buffer[..sample_count * 2],
        );

        self.mix.chain_start = start;
        self.mix.cursor = ChainCursor::start(has_input_activity);
        let sleep_changes = &mut self.sleep_changes;
        let step = super::devices::container::run_chain(
            &mut self.devices[start..],
            &mut self.device_input_buffer,
            &mut self.device_output_buffer,
            sample_count,
            &mut self.mix.cursor,
            &mut |idx, sleeping| {
                sleep_changes.push((super::devices::DevicePath::root(start + idx), sleeping))
            },
        );
        self.complete_chain_step(step, sample_count)
    }

    /// Finish the plugin this channel's chain parked at (waiting for it), then run the rest of
    /// the chain until it parks again or ends.
    pub fn resume_device_chain(&mut self, sample_count: usize) -> ChainStep {
        let start = self.mix.chain_start;
        let sleep_changes = &mut self.sleep_changes;
        let step = super::devices::container::resume_chain(
            &mut self.devices[start..],
            &mut self.device_input_buffer,
            &mut self.device_output_buffer,
            sample_count,
            &mut self.mix.cursor,
            &mut |idx, sleeping| {
                sleep_changes.push((super::devices::DevicePath::root(start + idx), sleeping))
            },
        );
        self.complete_chain_step(step, sample_count)
    }

    /// Copy a finished chain's result back into the channel buffers.
    fn complete_chain_step(&mut self, step: ChainStep, sample_count: usize) -> ChainStep {
        if let ChainStep::Done { result_in_output } = step {
            let final_output = if result_in_output {
                &self.device_output_buffer
            } else {
                &self.device_input_buffer
            };

            deinterleave_stereo(
                &final_output[..sample_count * 2],
                &mut self.buffer_left[..sample_count],
                &mut self.buffer_right[..sample_count],
            );
        }
        step
    }

    /// Send a note from clip playback. The note-on gets a sounding-note id from `active_notes`,
    /// and the note-off finds it by clip-note id. A note-off with no sounding note (already
    /// released by stop or seek) is dropped.
    pub fn send_clip_note(&mut self, event: &ClipNoteEvent, frame_offset: usize) {
        let source = NoteSource::Clip {
            clip_note_id: event.clip_note_id,
        };
        if event.is_on {
            let (evicted, on) =
                self.active_notes
                    .note_on(source, event.key, event.velocity, event.release);
            if let Some(off) = evicted {
                self.send_note_event_to_devices(&off, frame_offset);
            }
            self.send_note_event_to_devices(&on, frame_offset);
        } else if let Some(off) = self
            .active_notes
            .note_off(source, event.key, Some(event.release))
        {
            self.send_note_event_to_devices(&off, frame_offset);
        }
    }

    /// Send a note-off for every clip note still sounding, with the release it started with.
    /// Live MIDI isn't touched, so keys held on a controller keep playing.
    pub fn release_clip_notes(&mut self) {
        self.release_clip_notes_at(0);
    }

    /// Transport stop, pause or seek: release the clip notes, then tell every note effect,
    /// which releases what it generated from clip notes at its next note phase (spec 027
    /// REQ-007). Loop wraps use `release_clip_notes_at` instead, so echoes and latched notes
    /// ring across the loop point.
    pub fn stop_clip_notes(&mut self) {
        self.release_clip_notes();
        super::devices::container::visit_devices_mut(&mut self.devices, &mut |_, device| {
            if device.is_note_effect() {
                device.note_discontinuity();
            }
        });
    }

    /// The device list `parent_path` names, when it is a plain chain (the channel root, a
    /// Chain, a slot chain). Note effects only ever sit in these.
    pub fn chain_list_mut(
        &mut self,
        parent_path: &super::devices::DevicePath,
    ) -> Option<&mut Vec<Box<dyn AudioDevice>>> {
        if parent_path.is_empty() {
            return Some(&mut self.devices);
        }
        super::devices::container::device_at_path_mut(&mut self.devices, parent_path)?
            .as_container_mut()?
            .chain_children_mut()
    }

    /// Command thread, before a device at `path` is removed: if it is a note effect, its
    /// sounding notes are released to the devices after it, so none is left hanging (REQ-006).
    pub fn release_note_effect_at(&mut self, path: &super::devices::DevicePath) {
        let Some(index) = path.leaf_index() else {
            return;
        };
        if let Some(list) = self.chain_list_mut(&path.parent()) {
            super::devices::note_fx::routing::release_note_effect_at(list, index);
        }
    }

    /// Command thread, before devices in the list at `parent_path` move: every note effect in
    /// it releases its sounding notes, since its downstream devices are about to change.
    pub fn release_note_effects_in(&mut self, parent_path: &super::devices::DevicePath) {
        if let Some(list) = self.chain_list_mut(parent_path) {
            super::devices::note_fx::routing::release_note_effects(list);
        }
    }

    /// Like `release_clip_notes`, with the note-offs placed `frame_offset` frames into the buffer.
    pub fn release_clip_notes_at(&mut self, frame_offset: usize) {
        let devices = &mut self.devices;
        self.active_notes
            .release_clip(|off| send_note_event_to(devices, &off, frame_offset));
    }

    /// Send a note event to every top-level device with a frame offset, like scheduled notes.
    ///
    /// Audio effects ignore notes (the trait default); containers forward to their children.
    /// Only a device that accepts note input, or carries a note-driven modulator, is woken, so
    /// a sleeping reverb stays asleep (ADR-0014).
    pub fn send_note_event_to_devices(&mut self, event: &NoteEvent, frame_offset: usize) {
        send_note_event_to(&mut self.devices, event, frame_offset);
    }

    /// Set a device parameter by path.
    pub fn set_device_parameter(
        &mut self,
        path: &super::devices::DevicePath,
        param_id: u32,
        value: f32,
    ) -> bool {
        if let Some(device) = super::devices::container::device_at_path_mut(&mut self.devices, path)
        {
            device.set_parameter(param_id, value);
            true
        } else {
            false
        }
    }

    /// Get a device parameter by path.
    pub fn get_device_parameter(
        &self,
        path: &super::devices::DevicePath,
        param_id: u32,
    ) -> Option<f32> {
        super::devices::container::device_at_path(&self.devices, path)
            .and_then(|device| device.get_parameter(param_id))
    }

    /// Mutable device at `path`, including nested container children.
    pub fn device_at_path_mut(
        &mut self,
        path: &super::devices::DevicePath,
    ) -> Option<&mut dyn super::devices::AudioDevice> {
        super::devices::container::device_at_path_mut(&mut self.devices, path)
    }

    /// Immutable device at `path`, including nested container children.
    pub fn device_at_path(
        &self,
        path: &super::devices::DevicePath,
    ) -> Option<&dyn super::devices::AudioDevice> {
        super::devices::container::device_at_path(&self.devices, path)
    }
}

/// Track that generates audio and routes to a channel
#[derive(Debug, Clone)]
pub struct Track {
    pub id: TrackId,
    pub channel_id: ChannelId,
    pub clip_instances: Vec<ClipInstance>,
    /// Automation lanes driving parameters on the track's linked channel.
    pub automation_lanes: Vec<super::automation::AutomationLane>,
}

impl Track {
    pub fn new(id: TrackId, channel_id: ChannelId) -> Self {
        Self {
            id,
            channel_id,
            clip_instances: Vec::new(),
            automation_lanes: Vec::new(),
        }
    }

    /// Mutable lane with this id, if the track has one.
    pub fn automation_lane_mut(
        &mut self,
        lane_id: &str,
    ) -> Option<&mut super::automation::AutomationLane> {
        self.automation_lanes.iter_mut().find(|l| l.id == lane_id)
    }
}

/// Audio playback state for clips (handles time-stretching and fractional sample position)
#[derive(Debug, Clone)]
pub struct AudioPlayback {
    pub clip_instance_id: ClipInstanceId,
    pub current_sample_pos: f64, // Fractional sample position for smooth playback
    pub is_playing: bool,
}

impl AudioPlayback {
    pub fn new(clip_instance_id: ClipInstanceId) -> Self {
        Self {
            clip_instance_id,
            current_sample_pos: 0.0,
            is_playing: true,
        }
    }

    /// Calculate stretch factor: how many samples to advance per sample in time
    /// Stretch > 1.0 = speed up (pitch up)
    /// Stretch < 1.0 = slow down (pitch down)
    /// Example: recorded at 120 BPM, playing at 200 BPM → stretch = 200/120 = 1.667
    pub fn calculate_stretch_factor(project_bpm: f32, recorded_bpm: f32) -> f32 {
        if recorded_bpm <= 0.0 {
            1.0 // Fallback to 1:1 if invalid BPM
        } else {
            project_bpm / recorded_bpm
        }
    }

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

    /// Advance playback position by the stretch factor
    /// Returns the interpolated sample value (handles fractional positions)
    pub fn advance_and_get_sample(
        &mut self,
        audio_samples: &[f32],
        stretch_factor: f32,
        channels: usize,
    ) -> Option<(f32, f32)> {
        // Check if we've reached end of audio
        let total_samples = (audio_samples.len() / channels) as f64;
        if self.current_sample_pos >= total_samples {
            self.is_playing = false;
            return None;
        }

        // Get current and next sample indices for linear interpolation
        let sample_idx = self.current_sample_pos.floor() as usize;
        let next_idx = sample_idx + 1;
        let frac = (self.current_sample_pos.fract()) as f32;

        // Extract left and right samples with interpolation
        let (left_sample, right_sample) = if channels == 1 {
            // Mono - use same sample for both channels
            let s0 = audio_samples.get(sample_idx).copied().unwrap_or(0.0);
            let s1 = audio_samples.get(next_idx).copied().unwrap_or(0.0);
            let interpolated = Self::lerp(s0, s1, frac);
            (interpolated, interpolated)
        } else if channels == 2 {
            // Stereo - interleaved samples
            let left_idx = sample_idx * 2;
            let right_idx = sample_idx * 2 + 1;
            let next_left_idx = next_idx * 2;
            let next_right_idx = next_idx * 2 + 1;

            let left_0 = audio_samples.get(left_idx).copied().unwrap_or(0.0);
            let right_0 = audio_samples.get(right_idx).copied().unwrap_or(0.0);
            let left_1 = audio_samples.get(next_left_idx).copied().unwrap_or(0.0);
            let right_1 = audio_samples.get(next_right_idx).copied().unwrap_or(0.0);

            (
                Self::lerp(left_0, left_1, frac),
                Self::lerp(right_0, right_1, frac),
            )
        } else {
            // Fallback for other channel counts
            (0.0, 0.0)
        };

        // Advance position by stretch factor
        self.current_sample_pos += stretch_factor as f64;

        Some((left_sample, right_sample))
    }

    /// Linear interpolation helper
    fn lerp(a: f32, b: f32, t: f32) -> f32 {
        a + (b - a) * t
    }
}

/// Project settings
#[derive(Debug, Clone)]
pub struct ProjectSettings {
    pub tempo: f32,
    pub time_numerator: i32,
    pub time_denominator: i32,
    pub ppq: i32,
    pub sample_rate: i32,
    /// Project scale as a 12-bit pitch-class mask (bit 0 = C), 0 = none. Only note effects
    /// read it (Transpose following the project scale, spec 027 amending spec 026).
    pub scale_mask: u16,
}

impl Default for ProjectSettings {
    fn default() -> Self {
        Self {
            tempo: 120.0,
            time_numerator: 4,
            time_denominator: 4,
            ppq: 960,
            sample_rate: 48000,
            scale_mask: 0,
        }
    }
}

impl ProjectSettings {
    /// Calculate ticks per sample
    pub fn ticks_per_sample(&self) -> f64 {
        (self.tempo as f64 * self.ppq as f64) / (60.0 * self.sample_rate as f64)
    }

    /// Ticks per second at constant tempo
    pub fn ticks_per_second(&self) -> f64 {
        (self.tempo as f64 * self.ppq as f64) / 60.0
    }

    /// Seconds per tick at constant tempo
    pub fn seconds_per_tick(&self) -> f64 {
        1.0 / self.ticks_per_second()
    }

    /// Convert sample count to ticks using a given sample rate (constant tempo)
    pub fn samples_to_ticks(&self, samples: u64, sample_rate: f32) -> i64 {
        let seconds = samples as f64 / sample_rate as f64;
        (seconds * self.ticks_per_second()).floor() as i64
    }

    /// Convert ticks to samples using a given sample rate (constant tempo)
    pub fn ticks_to_samples(&self, ticks: Tick, sample_rate: f32) -> u64 {
        let seconds = ticks as f64 * self.seconds_per_tick();
        (seconds * sample_rate as f64).floor() as u64
    }

    /// Convert tick position to bars.beats.sixteenths.ticks format
    /// Returns (bars, beats, sixteenths, ticks) - 1-indexed for bars/beats/sixteenths, 0-indexed for ticks
    pub fn tick_to_musical_time(&self, tick: Tick) -> (i64, i32, i32, i32) {
        let ticks_per_beat = self.ppq as i64;
        let ticks_per_bar = ticks_per_beat * self.time_numerator as i64;
        let ticks_per_sixteenth = ticks_per_beat / 4;

        let bars = tick / ticks_per_bar;
        let remaining_after_bars = tick % ticks_per_bar;

        let beats = remaining_after_bars / ticks_per_beat;
        let remaining_after_beats = remaining_after_bars % ticks_per_beat;

        let sixteenths = remaining_after_beats / ticks_per_sixteenth;
        let remaining_ticks = remaining_after_beats % ticks_per_sixteenth;

        (
            bars + 1,
            beats as i32 + 1,
            sixteenths as i32 + 1,
            remaining_ticks as i32,
        )
    }

    /// Format tick position as "bars.beats.sixteenths.ticks" string
    pub fn format_tick_position(&self, tick: Tick) -> String {
        let (bars, beats, sixteenths, ticks) = self.tick_to_musical_time(tick);
        format!("{}.{}.{}.{}", bars, beats, sixteenths, ticks)
    }
}

#[cfg(test)]
mod meter_tests {
    use super::*;

    const SR: f32 = 48_000.0;
    /// Channels are allocated at the engine's max block size, well above the real block size.
    const ALLOC: usize = 8192;
    const FRAMES: usize = 1024;

    fn channel_with_signal(amplitude: f32, frames: usize) -> Channel {
        let mut channel = Channel::new(2, "Meter".to_string(), ALLOC, SR);
        for i in 0..frames {
            channel.buffer_left[i] = amplitude;
            channel.buffer_right[i] = amplitude;
        }
        channel
    }

    #[test]
    fn rms_ignores_the_unwritten_tail_of_an_oversized_buffer() {
        // A full-scale DC block has an RMS of exactly its amplitude. Metering the whole
        // allocation instead of `frames` used to divide by 8x too many samples (-9 dB).
        let mut channel = channel_with_signal(0.5, FRAMES);
        // Settle the 300 ms integrator by feeding the same block for well over a second.
        for _ in 0..(SR as usize / FRAMES) * 2 {
            channel.update_peaks(FRAMES, SR);
        }
        assert!(
            (channel.rms_left - 0.5).abs() < 0.01,
            "expected RMS ~0.5, got {}",
            channel.rms_left
        );
    }

    #[test]
    fn peaks_accumulate_across_blocks_until_taken() {
        let mut channel = channel_with_signal(0.2, FRAMES);
        channel.update_peaks(FRAMES, SR);

        // A transient in a later block must survive, even though a quiet block follows it.
        channel.buffer_left[7] = 0.9;
        channel.update_peaks(FRAMES, SR);
        channel.buffer_left[7] = 0.2;
        channel.update_peaks(FRAMES, SR);

        let (peak_left, _, _, _) = channel.take_meters();
        assert!(
            (peak_left - 0.9).abs() < 1e-6,
            "expected the held transient 0.9, got {peak_left}"
        );

        // Taking the meters restarts the max, so the next interval reports only its own blocks.
        channel.update_peaks(FRAMES, SR);
        let (peak_left, _, _, _) = channel.take_meters();
        assert!(
            (peak_left - 0.2).abs() < 1e-6,
            "expected the accumulator to reset to 0.2, got {peak_left}"
        );
    }

    #[test]
    fn rms_integrates_over_roughly_300ms() {
        // One time constant of a step response reaches ~63% of the target in mean-square terms.
        let mut channel = channel_with_signal(1.0, FRAMES);
        let blocks = (0.3 * SR / FRAMES as f32).round() as usize;
        for _ in 0..blocks {
            channel.update_peaks(FRAMES, SR);
        }
        let mean_square = channel.rms_left * channel.rms_left;
        assert!(
            (mean_square - 0.632).abs() < 0.02,
            "expected ~0.632 mean square after one 300 ms time constant, got {mean_square}"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::{DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue};
    use crate::audio::midi_types::MidiMessageType;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    /// Instrument that records every note event it receives.
    struct NoteProbe {
        events: Arc<Mutex<Vec<NoteEvent>>>,
    }

    impl AudioDevice for NoteProbe {
        fn process_block(&mut self, _inputs: &[f32], _outputs: &mut [f32], _sample_count: usize) {}
        fn send_note_event(&mut self, event: &NoteEvent, _frame_offset: usize) {
            self.events.lock().unwrap().push(*event);
        }
        fn set_parameter(&mut self, _param_id: ParamId, _value: ParamValue) {}
        fn get_parameter(&self, _param_id: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.note_probe"
        }
        fn device_name(&self) -> &str {
            "Note Probe"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Instrument
        }
        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }
        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }
        fn reset(&mut self) {}
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    /// Dispatch `midi` as one buffer of live MIDI and return what the probe received.
    fn dispatch_live(midi: &[(MidiMessageType, u8, u8)]) -> Vec<NoteEvent> {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut channel = Channel::new(2, "Probe".to_string(), 64, 48_000.0);
        channel.devices.push(Box::new(NoteProbe {
            events: events.clone(),
        }));
        for &(message_type, note, velocity) in midi {
            channel.scheduled_midi_events.push(MidiEvent {
                message_type,
                midi_channel: 0,
                note,
                velocity,
                received_at: Instant::now(),
                frame_offset: 0,
            });
        }
        channel.dispatch_scheduled_midi();
        let received = events.lock().unwrap().clone();
        received
    }

    #[test]
    fn stop_releases_generated_clip_notes_only() {
        use crate::audio::devices::note_fx::host::tests::test_host;
        use crate::audio::devices::note_fx::routing::test_devices::Recorder;
        use crate::audio::render_scratch::ClipNoteEvent;
        let mut channel = Channel::new(2, "test".to_string(), 128, 48_000.0);
        // Each note plus one generated copy an octave up, 32 frames later.
        channel.devices.push(Box::new(test_host(0.0, 32.0, 1.0)));
        let (recorder, log) = Recorder::new();
        channel.devices.push(Box::new(recorder));

        channel.send_clip_note(
            &ClipNoteEvent {
                track_id: 1,
                clip_note_id: 7,
                key: 60,
                velocity: 0.8,
                release: DEFAULT_RELEASE,
                is_on: true,
            },
            0,
        );
        channel
            .scheduled_midi_events
            .push(MidiEvent::note_on(0, 48, 100, Instant::now()));
        channel.dispatch_notes(64);
        channel.scheduled_midi_events.clear();
        log.lock().unwrap().clear();

        channel.stop_clip_notes();
        channel.dispatch_notes(64);
        let offs: Vec<u8> = log
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, e)| matches!(e, NoteEvent::Off { .. }))
            .map(|(_, e)| e.key())
            .collect();
        // The clip note and its copy end; the live 48 and its copy (60) keep sounding.
        let mut sorted = offs.clone();
        sorted.sort();
        assert_eq!(sorted, vec![60, 72], "{offs:?}");
        let ids: Vec<u32> = log
            .lock()
            .unwrap()
            .iter()
            .map(|(_, e)| e.note_id())
            .collect();
        assert!(ids
            .iter()
            .all(|&id| crate::audio::midi_types::is_clip_note(id)));
    }

    #[test]
    fn live_note_off_carries_release() {
        let events = dispatch_live(&[
            (MidiMessageType::NoteOn, 60, 127),
            (MidiMessageType::NoteOff, 60, 32),
        ]);
        assert_eq!(events.len(), 2, "{events:?}");
        assert!(matches!(events[0], NoteEvent::On { key: 60, velocity, .. } if velocity == 1.0));
        assert_eq!(
            events[1],
            NoteEvent::Off {
                note_id: events[0].note_id(),
                key: 60,
                release: 32.0 / 127.0
            }
        );
    }

    #[test]
    fn live_note_on_zero_is_release_default() {
        let events = dispatch_live(&[
            (MidiMessageType::NoteOn, 60, 100),
            (MidiMessageType::NoteOn, 60, 0),
            // A note-off with nothing sounding on its key is dropped.
            (MidiMessageType::NoteOff, 61, 64),
        ]);
        assert_eq!(events.len(), 2, "{events:?}");
        assert_eq!(
            events[1],
            NoteEvent::Off {
                note_id: events[0].note_id(),
                key: 60,
                release: DEFAULT_RELEASE
            }
        );
    }

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

    fn channel(mode: PanMode, pan: f32, width: f32) -> Channel {
        let mut c = Channel::new(2, "T".to_string(), 128, 48_000.0);
        c.pan_mode = mode;
        c.pan = pan;
        c.pan_width = width;
        c
    }

    fn assert_matrix(c: &PanCoefficients, ll: f32, rr: f32, lr: f32, rl: f32) {
        let close = |a: f32, b: f32| (a - b).abs() < 1e-5;
        assert!(
            close(c.left_to_left, ll)
                && close(c.right_to_right, rr)
                && close(c.left_to_right, lr)
                && close(c.right_to_left, rl),
            "got {:?}, expected ll={ll} rr={rr} lr={lr} rl={rl}",
            c
        );
    }

    const H: f32 = std::f32::consts::FRAC_1_SQRT_2;

    #[test]
    fn pan_mode_default_is_balance() {
        assert_eq!(PanMode::default(), PanMode::StereoBalance);
        let c = Channel::new(2, "T".to_string(), 128, 48_000.0);
        assert_eq!(c.pan_mode, PanMode::StereoBalance);
        assert_eq!(c.pan_width, 1.0);
    }

    #[test]
    fn pan_balance_coefficients() {
        assert_matrix(
            &channel(PanMode::StereoBalance, 0.0, 1.0).get_pan_coefficients(),
            1.0,
            1.0,
            0.0,
            0.0,
        );
        assert_matrix(
            &channel(PanMode::StereoBalance, 0.5, 1.0).get_pan_coefficients(),
            0.5,
            1.0,
            0.0,
            0.0,
        );
        assert_matrix(
            &channel(PanMode::StereoBalance, -1.0, 1.0).get_pan_coefficients(),
            1.0,
            0.0,
            0.0,
            0.0,
        );
    }

    #[test]
    fn pan_combined_coefficients() {
        // Width 1 at center: handles -1/+1, identity.
        assert_matrix(
            &channel(PanMode::StereoCombined, 0.0, 1.0).get_pan_coefficients(),
            1.0,
            1.0,
            0.0,
            0.0,
        );
        // Width 0: both handles at center.
        assert_matrix(
            &channel(PanMode::StereoCombined, 0.0, 0.0).get_pan_coefficients(),
            H,
            H,
            H,
            H,
        );
        // Negative width swaps the sides.
        assert_matrix(
            &channel(PanMode::StereoCombined, 0.0, -1.0).get_pan_coefficients(),
            0.0,
            0.0,
            1.0,
            1.0,
        );
        // Position +0.5, width 1: handles -0.5 / +1.0 (right clamped).
        let expected = Channel::dual_matrix(-0.5, 1.0);
        let got = channel(PanMode::StereoCombined, 0.5, 1.0).get_pan_coefficients();
        assert_matrix(
            &got,
            expected.left_to_left,
            expected.right_to_right,
            expected.left_to_right,
            expected.right_to_left,
        );
        assert!((got.right_to_right - 1.0).abs() < 1e-5 && got.right_to_left.abs() < 1e-5);
    }

    #[test]
    fn pan_dual_coefficients_unchanged() {
        use std::f32::consts::FRAC_PI_2;
        let mut c = channel(PanMode::StereoDual, 0.0, 1.0);
        c.pan_left = -1.0;
        c.pan_right = 0.2;
        let al = 0.0_f32;
        let ar = 1.2 * 0.5 * FRAC_PI_2;
        assert_matrix(
            &c.get_pan_coefficients(),
            al.cos(),
            ar.sin(),
            al.sin(),
            ar.cos(),
        );
    }

    #[test]
    fn pan_mono_sums_half() {
        let c = channel(PanMode::Mono, 0.0, 1.0).get_pan_coefficients();
        // Identical L and R content x = 1 sums to 1, then -3 dB to each side.
        assert!((c.left_to_left + c.right_to_left - H).abs() < 1e-5);
        assert!((c.left_to_right + c.right_to_right - H).abs() < 1e-5);
        let r = channel(PanMode::Mono, 1.0, 1.0).get_pan_coefficients();
        assert!((r.left_to_left + r.right_to_left).abs() < 1e-5);
        assert!((r.left_to_right + r.right_to_right - 1.0).abs() < 1e-5);
    }

    #[test]
    fn pan_combined_automation_moves_position() {
        let mut c = channel(PanMode::StereoCombined, 0.0, 0.5);
        c.automation_pan = Some(1.0);
        let expected = Channel::dual_matrix(0.5, 1.0);
        assert_matrix(
            &c.get_pan_coefficients(),
            expected.left_to_left,
            expected.right_to_right,
            expected.left_to_right,
            expected.right_to_left,
        );
        assert_eq!(c.pan_width, 0.5, "width must not be written");
        assert_eq!(c.pan, 0.0, "base pan must not be written");
    }
}
