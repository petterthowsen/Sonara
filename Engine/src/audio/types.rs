use super::devices::AudioDevice;
use std::collections::HashMap;
use tracing::info;
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
            unsafe { interleave_stereo_avx(left, right, output, frames); }
            return;
        }
        if is_x86_feature_detected!("sse") {
            unsafe { interleave_stereo_sse(left, right, output, frames); }
            return;
        }
    }
    
    #[cfg(target_arch = "aarch64")]
    {
        if std::arch::is_aarch64_feature_detected!("neon") {
            unsafe { interleave_stereo_neon(left, right, output, frames); }
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
            unsafe { deinterleave_stereo_avx(input, left, right, frames); }
            return;
        }
        if is_x86_feature_detected!("sse") {
            unsafe { deinterleave_stereo_sse(input, left, right, frames); }
            return;
        }
    }
    
    #[cfg(target_arch = "aarch64")]
    {
        if std::arch::is_aarch64_feature_detected!("neon") {
            unsafe { deinterleave_stereo_neon(input, left, right, frames); }
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
        let lr_low = _mm256_unpacklo_ps(l, r);  // L0 R0 L1 R1 | L4 R4 L5 R5
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
unsafe fn deinterleave_stereo_avx(input: &[f32], left: &mut [f32], right: &mut [f32], frames: usize) {
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
        
        let lr_low = _mm_unpacklo_ps(l, r);   // L0 R0 L1 R1
        let lr_high = _mm_unpackhi_ps(l, r);  // L2 R2 L3 R3
        
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
unsafe fn deinterleave_stereo_sse(input: &[f32], left: &mut [f32], right: &mut [f32], frames: usize) {
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
unsafe fn deinterleave_stereo_neon(input: &[f32], left: &mut [f32], right: &mut [f32], frames: usize) {
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

/// Pan mode enumeration (matches Godot's PanMode enum)
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PanMode {
    StereoCombined = 0, // Single pan knob controls stereo balance
    StereoDual = 1,     // Separate L/R pan controls
    StereoBalance = 2,  // Balance between L and R channels
    Mono = 3,           // Mono panner (single channel)
}

impl Default for PanMode {
    fn default() -> Self {
        PanMode::StereoCombined
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

/// MIDI velocity (0-127)
pub type MidiVelocity = u8;

/// Position in ticks
pub type Tick = i64;

/// Channel ID
///
/// ID Allocation Scheme:
/// - 0: Null/no output (reserved, channels routing to 0 won't output anywhere)
/// - 1: Master channel (always present, created by Godot on project init, routes to ID 1000)
/// - 2-999: User mixer channels (created dynamically by user)
/// - 1000+: Hardware output devices (enumerated by audio engine on startup)
///   - 1000: Default output device (the one currently running the audio stream)
///   - 1001+: Additional output devices (future support for multi-device routing)
pub type ChannelId = usize;

/// Track ID
pub type TrackId = usize;

/// Unique identifier for scheduled notes
pub type NoteId = u64;

/// Unique identifier for clips (GUID from Godot)
pub type ClipId = String;

/// Unique identifier for clip instances (GUID from Godot)
pub type ClipInstanceId = String;

/// MIDI note stored in a Clip (relative to clip start)
#[derive(Debug, Clone)]
pub struct ClipNote {
    pub id: NoteId,
    pub note: MidiNote,
    pub velocity: MidiVelocity,
    pub start_tick: Tick, // Relative to clip start (0-based)
    pub duration_ticks: Tick,
}

/// Clip type enumeration
#[derive(Debug, Clone, PartialEq)]
pub enum ClipType {
    Midi,
    Audio,
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
    pub loop_start_ticks: Tick, // Relative to clip start
    pub loop_length_ticks: Tick,
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
        }
    }

    pub fn end_tick(&self) -> Tick {
        self.start_tick + self.duration_ticks
    }
}

/// Audio channel for mixing
pub struct Channel {
    pub id: ChannelId,
    pub name: String,
    pub volume_db: f32,    // dB (-60.0 to +12.0)
    pub pan: f32,          // -1.0 (left) to +1.0 (right) for STEREO_COMBINED/MONO/BALANCE
    pub pan_left: f32,     // For STEREO_DUAL mode
    pub pan_right: f32,    // For STEREO_DUAL mode
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

    // Parameter smoothing (prevents clicks/pops when changing volume)
    current_gain: f32,    // Smoothed gain value (internal)
    smoothing_alpha: f32, // Smoothing coefficient (internal)

    // Device chain for processing (instruments or effects)
    pub devices: Vec<Box<dyn AudioDevice>>,

    // Active voices for INSTRUMENT channels only
    pub active_voices: HashMap<MidiNote, Voice>,

    // Temporary interleaved buffer for device processing
    device_input_buffer: Vec<f32>,
    device_output_buffer: Vec<f32>,
}

impl Channel {
    pub fn new(id: ChannelId, name: String, buffer_size: usize, sample_rate: f32) -> Self {
        // Calculate smoothing coefficient for 5ms smoothing time
        // One-pole filter: alpha = 1 - exp(-1 / (tau * sample_rate))
        // tau = 0.005s (5ms) is a good balance between smoothness and responsiveness
        let tau = 0.005;
        let smoothing_alpha = 1.0 - (-1.0 / (tau * sample_rate as f64)).exp() as f32;

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
            pan_left: 0.0,
            pan_right: 0.0,
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
            current_gain: initial_gain,
            smoothing_alpha,
            devices: Vec::new(),
            active_voices: HashMap::new(),
            device_input_buffer: vec![0.0; buffer_size * 2],
            device_output_buffer: vec![0.0; buffer_size * 2],
        }
    }

    /// Convert dB to linear gain (target value, not smoothed)
    pub fn get_gain(&self) -> f32 {
        if self.volume_db <= -60.0 {
            0.0
        } else {
            10.0_f32.powf(self.volume_db / 20.0)
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

        match self.pan_mode {
            PanMode::StereoCombined => {
                // Constant power panning
                let angle = (self.pan + 1.0) * 0.5 * FRAC_PI_2; // Map -1..1 to 0..PI/2
                PanCoefficients {
                    left_to_left: angle.cos(),
                    right_to_right: angle.sin(),
                    left_to_right: 0.0,
                    right_to_left: 0.0,
                }
            }
            PanMode::StereoDual => {
                // Separate L/R pan controls
                let angle_l = (self.pan_left + 1.0) * 0.5 * FRAC_PI_2;
                let angle_r = (self.pan_right + 1.0) * 0.5 * FRAC_PI_2;
                PanCoefficients {
                    left_to_left: angle_l.cos(),
                    right_to_right: angle_r.sin(),
                    left_to_right: angle_l.sin(),
                    right_to_left: angle_r.cos(),
                }
            }
            PanMode::StereoBalance => {
                // Simple balance: pan < 0 reduces right, pan > 0 reduces left
                let left_gain = if self.pan <= 0.0 { 1.0 } else { 1.0 - self.pan };
                let right_gain = if self.pan >= 0.0 { 1.0 } else { 1.0 + self.pan };
                PanCoefficients {
                    left_to_left: left_gain,
                    right_to_right: right_gain,
                    left_to_right: 0.0,
                    right_to_left: 0.0,
                }
            }
            PanMode::Mono => {
                // Mono to stereo panning
                let angle = (self.pan + 1.0) * 0.5 * FRAC_PI_2;
                PanCoefficients {
                    left_to_left: angle.cos(),
                    right_to_right: angle.sin(),
                    left_to_right: angle.sin(),
                    right_to_left: angle.cos(),
                }
            }
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
    }

    /// Update peak and RMS meters (post-fader)
    /// Peaks and RMS are calculated directly from the buffer content after all mixing has occurred
    /// The buffer already contains the post-fader audio (gain/pan applied during mixing)
    pub fn update_peaks(&mut self) {
        self.peak_left = self.buffer_left.iter().map(|s| s.abs()).fold(0.0, f32::max);
        self.peak_right = self
            .buffer_right
            .iter()
            .map(|s| s.abs())
            .fold(0.0, f32::max);
        
        // Compute RMS (Root Mean Square) for both channels
        // RMS = sqrt(sum(samples^2) / count)
        let n = self.buffer_left.len() as f32;
        if n > 0.0 {
            let sum_squares_left: f32 = self.buffer_left.iter().map(|s| s * s).sum();
            let sum_squares_right: f32 = self.buffer_right.iter().map(|s| s * s).sum();
            self.rms_left = (sum_squares_left / n).sqrt();
            self.rms_right = (sum_squares_right / n).sqrt();
        } else {
            self.rms_left = 0.0;
            self.rms_right = 0.0;
        }
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

    /// Process channel audio through device chain (instruments or effects)
    /// Devices process on interleaved stereo buffers with alternating input/output
    pub fn process_device_chain(&mut self, sample_count: usize) {
        if self.devices.is_empty() {
            return;
        }

        static mut DEVICE_DEBUG_COUNT: u32 = 0;
        unsafe {
            DEVICE_DEBUG_COUNT += 1;
            if DEVICE_DEBUG_COUNT <= 10 || (DEVICE_DEBUG_COUNT > 100 && DEVICE_DEBUG_COUNT <= 110) {
                info!("DEVICE CHAIN DEBUG: channel={} sample_count={} buffer_left_len={} device_input_buffer_len={} device_output_buffer_len={} devices={}",
                    self.id, sample_count, self.buffer_left.len(), self.device_input_buffer.len(), self.device_output_buffer.len(), self.devices.len());
                // Check for non-zero in input
                let non_zero_left = self
                    .buffer_left
                    .iter()
                    .take(sample_count)
                    .filter(|&&s| s.abs() > 0.0001)
                    .count();
                let non_zero_left_full = self
                    .buffer_left
                    .iter()
                    .filter(|&&s| s.abs() > 0.0001)
                    .count();
                info!("  buffer_left: {} non-zero in first {} samples, {} non-zero in FULL buffer of {} samples",
                    non_zero_left, sample_count, non_zero_left_full, self.buffer_left.len());
            }
        }

        // CRITICAL: Clear device buffers to prevent stale data from previous frames
        // These buffers are allocated for max_buffer_size but only sample_count is active
        let interleaved_count = sample_count * 2;
        self.device_input_buffer[..interleaved_count].fill(0.0);
        self.device_output_buffer[..interleaved_count].fill(0.0);

        // Prepare input buffer (convert L/R to interleaved) with SIMD optimization
        interleave_stereo(
            &self.buffer_left[..sample_count],
            &self.buffer_right[..sample_count],
            &mut self.device_input_buffer[..sample_count * 2],
        );

        // Process through device chain, alternating between buffers
        for (idx, device) in self.devices.iter_mut().enumerate() {
            if idx % 2 == 0 {
                // Input from device_input_buffer, output to device_output_buffer
                device.process_block(
                    &self.device_input_buffer[..],
                    &mut self.device_output_buffer,
                    sample_count,
                );
            } else {
                // Input from device_output_buffer, output to device_input_buffer
                device.process_block(
                    &self.device_output_buffer[..],
                    &mut self.device_input_buffer,
                    sample_count,
                );
            }
        }

        // Copy final output back to L/R buffers
        // Device 0 (first device) writes to device_output_buffer
        // Device 1 writes to device_input_buffer
        // Device 2 writes to device_output_buffer, etc.
        // So: even index → writes to output_buffer, odd index → writes to input_buffer
        // Final output location depends on the last device's index
        let final_output = if (self.devices.len() - 1) % 2 == 0 {
            // Last device has even index, wrote to device_output_buffer
            &self.device_output_buffer
        } else {
            // Last device has odd index, wrote to device_input_buffer
            &self.device_input_buffer
        };

        // De-interleave with SIMD optimization
        deinterleave_stereo(
            &final_output[..sample_count * 2],
            &mut self.buffer_left[..sample_count],
            &mut self.buffer_right[..sample_count],
        );

        // Debug output
        unsafe {
            if DEVICE_DEBUG_COUNT <= 10 || (DEVICE_DEBUG_COUNT > 100 && DEVICE_DEBUG_COUNT <= 110) {
                let non_zero_output = self
                    .buffer_left
                    .iter()
                    .take(sample_count)
                    .filter(|&&s| s.abs() > 0.0001)
                    .count();
                info!(
                    "  AFTER processing: {} non-zero samples in output",
                    non_zero_output
                );
                if non_zero_output > 0 {
                    // Show first non-zero value
                    if let Some(&val) = self
                        .buffer_left
                        .iter()
                        .take(sample_count)
                        .find(|&&s| s.abs() > 0.0001)
                    {
                        info!("    First non-zero value: {}", val);
                    }
                }
            }
        }
    }

    /// Send MIDI event to the first device (instrument) only with a frame offset
    /// Effects in the chain don't receive MIDI
    pub fn send_midi_event_to_devices(
        &mut self,
        note: u8,
        velocity: u8,
        is_note_on: bool,
        frame_offset: usize,
    ) {
        if let Some(device) = self.devices.first_mut() {
            device.send_midi_event(note, velocity, is_note_on, frame_offset);
        }
    }

    /// Set a device parameter
    pub fn set_device_parameter(&mut self, device_index: usize, param_id: u32, value: f32) -> bool {
        if device_index < self.devices.len() {
            self.devices[device_index].set_parameter(param_id, value);
            true
        } else {
            false
        }
    }

    /// Get a device parameter
    pub fn get_device_parameter(&self, device_index: usize, param_id: u32) -> Option<f32> {
        if device_index < self.devices.len() {
            self.devices[device_index].get_parameter(param_id)
        } else {
            None
        }
    }
}

/// Track that generates audio and routes to a channel
#[derive(Debug, Clone)]
pub struct Track {
    pub id: TrackId,
    pub channel_id: ChannelId,
    pub clip_instances: Vec<ClipInstance>,
    pub active_voices: HashMap<MidiNote, Voice>,
    // Track fractional sample positions for audio playback (per clip instance)
    pub audio_playback_positions: HashMap<ClipInstanceId, f64>,
}

impl Track {
    pub fn new(id: TrackId, channel_id: ChannelId) -> Self {
        Self {
            id,
            channel_id,
            clip_instances: Vec::new(),
            active_voices: HashMap::new(),
            audio_playback_positions: HashMap::new(),
        }
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

/// Voice for MIDI note playback (sine wave generator)
/// TODO: remove this?
#[derive(Debug, Clone)]
pub struct Voice {
    pub note: MidiNote,
    pub velocity: MidiVelocity,
    pub phase: f32,
    pub sample_rate: f32,
}

impl Voice {
    pub fn new(note: MidiNote, velocity: MidiVelocity, sample_rate: f32) -> Self {
        Self {
            note,
            velocity,
            phase: 0.0,
            sample_rate,
        }
    }

    /// Get frequency for MIDI note (A4 = 440Hz)
    pub fn get_frequency(&self) -> f32 {
        440.0 * 2.0_f32.powf((self.note as f32 - 69.0) / 12.0)
    }

    /// Get amplitude from velocity
    pub fn get_amplitude(&self) -> f32 {
        (self.velocity as f32 / 127.0) * 0.3 // Scale down to prevent clipping
    }

    /// Generate next sample
    pub fn process(&mut self) -> f32 {
        let freq = self.get_frequency();
        let amp = self.get_amplitude();

        // Calculate sine wave output
        // Phase is in range [0, 1), convert to radians [0, 2π)
        let phase_radians = self.phase * 2.0 * std::f32::consts::PI;
        let output = amp * phase_radians.sin();

        // Increment phase by frequency/sample_rate (cycles per sample)
        let phase_increment = freq / self.sample_rate;
        self.phase += phase_increment;

        // Wrap phase to keep it in [0, 1) range
        while self.phase >= 1.0 {
            self.phase -= 1.0;
        }

        output
    }
}

/// Output device (hardware audio output)
#[derive(Debug, Clone)]
pub struct OutputDevice {
    pub id: ChannelId,    // ID >= 1000
    pub name: String,     // Device name from CPAL
    pub is_default: bool, // Whether this is the default device
}

impl OutputDevice {
    pub fn new(id: ChannelId, name: String, is_default: bool) -> Self {
        Self {
            id,
            name,
            is_default,
        }
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
}

impl Default for ProjectSettings {
    fn default() -> Self {
        Self {
            tempo: 120.0,
            time_numerator: 4,
            time_denominator: 4,
            ppq: 960,
            sample_rate: 48000,
        }
    }
}

impl ProjectSettings {
    /// Calculate ticks per sample
    pub fn ticks_per_sample(&self) -> f64 {
        (self.tempo as f64 * self.ppq as f64) / (60.0 * self.sample_rate as f64)
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
