use super::{
    AudioDevice, AudioPort, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamType,
    ParamValue, PortFlow,
};
use realfft::{RealFftPlanner, RealToComplex};
use std::collections::HashMap;
use std::sync::Arc;
use tracing::info;

/// Spectrum Analyzer Device
///
/// Pass-through effect that performs FFT analysis on audio and streams
/// frequency spectrum data via subscription-based OSC protocol.
///
/// Features:
/// - Configurable FFT size (2048, 4096, 8192)
/// - Hann windowing for reduced spectral leakage
/// - Exponential smoothing for visual stability
/// - ~20Hz update rate when subscribed
/// - Real-time safe operation
pub struct SpectrumAnalyzerDevice {
    // Device metadata
    device_id: String,
    device_name: String,
    sample_rate: f32,

    // FFT configuration
    fft_size: usize,
    fft_planner: Arc<dyn RealToComplex<f32>>,
    smoothing_factor: f32,
    hop_size: usize, // Hop size in samples (controls update cadence)

    // Audio buffers (pre-allocated for real-time safety)
    input_buffer: Vec<f32>,    // Circular buffer for incoming audio
    write_pos: usize,          // Current write position in circular buffer
    fft_input: Vec<f32>,       // Windowed FFT input
    fft_output: Vec<f32>,      // FFT magnitude spectrum (dB)
    smoothed_output: Vec<f32>, // Exponentially smoothed spectrum
    window: Vec<f32>,          // Hann window coefficients

    // Subscription state
    subscriptions: HashMap<String, bool>,
    last_fft_time: std::time::Instant,
    fft_interval: std::time::Duration,

    // Parameters
    current_params: HashMap<ParamId, ParamValue>,
}

impl SpectrumAnalyzerDevice {
    pub fn new(sample_rate: f32) -> Self {
        let fft_size = 2048; // Default FFT size
        let mut planner = RealFftPlanner::<f32>::new();
        let fft_planner = planner.plan_fft_forward(fft_size);

        info!(
            "SpectrumAnalyzerDevice::new() - sample_rate={}",
            sample_rate
        );

        // Pre-allocate all buffers
        let bin_count = fft_size / 2 + 1;
        let input_buffer = vec![0.0; fft_size * 2]; // Double size for circular buffer
        let fft_input = vec![0.0; fft_size];
        let fft_output = vec![0.0; bin_count];
        let smoothed_output = vec![-160.0; bin_count]; // Initialize to silence (-160 dBFS)

        // Generate Hann window
        let window = Self::generate_hann_window(fft_size);

        // Default parameters
        let mut current_params = HashMap::new();
        current_params.insert(0, 0.5); // FFT size selector → 2048 by default
        current_params.insert(1, 0.7); // Speed (UI-only; engine ignores it)

        Self {
            device_id: "sonara.builtin.spectrum_analyzer".to_string(),
            device_name: "Spectrum Analyzer".to_string(),
            sample_rate,
            fft_size,
            fft_planner,
            smoothing_factor: 0.7,
            hop_size: fft_size / 2, // 50% overlap by default
            input_buffer,
            write_pos: 0,
            fft_input,
            fft_output,
            smoothed_output,
            window,
            subscriptions: HashMap::new(),
            last_fft_time: std::time::Instant::now(),
            // Compute update interval from hop size and sample rate
            fft_interval: std::time::Duration::from_secs_f32((fft_size as f32 / 2.0) / sample_rate),
            current_params,
        }
    }

    /// Generate Hann window coefficients
    fn generate_hann_window(size: usize) -> Vec<f32> {
        (0..size)
            .map(|i| {
                let angle = 2.0 * std::f32::consts::PI * i as f32 / (size - 1) as f32;
                0.5 * (1.0 - angle.cos())
            })
            .collect()
    }

    /// Update FFT size and reallocate buffers
    fn update_fft_size(&mut self, new_size: usize) {
        if new_size == self.fft_size {
            return; // No change
        }

        info!(
            "Spectrum Analyzer: Updating FFT size from {} to {}",
            self.fft_size, new_size
        );

        self.fft_size = new_size;

        // Recreate FFT planner
        let mut planner = RealFftPlanner::<f32>::new();
        self.fft_planner = planner.plan_fft_forward(new_size);

        // Reallocate buffers
        let bin_count = new_size / 2 + 1;
        self.input_buffer = vec![0.0; new_size * 2];
        self.write_pos = 0;
        self.fft_input = vec![0.0; new_size];
        self.fft_output = vec![0.0; bin_count];
        self.smoothed_output = vec![-160.0; bin_count];
        self.window = Self::generate_hann_window(new_size);

        // Recompute hop size and update interval from hop size and sample rate
        self.hop_size = self.fft_size / 2; // keep 50% overlap by default on size change
        self.fft_interval =
            std::time::Duration::from_secs_f32(self.hop_size as f32 / self.sample_rate);
    }

    /// Compute FFT and return magnitude spectrum in dB
    fn compute_fft(&mut self) {
        // Copy circular buffer data into FFT input with windowing
        // The write_pos points to the NEXT position to write (oldest data currently in buffer)
        // We want to read the most recent samples in REVERSE time order
        // So that write_pos-1 (newest) appears first in the FFT window
        for i in 0..self.fft_size {
            // Read from newest to oldest: (write_pos - 1 - i) going backwards
            let read_idx = (self.write_pos as i32 - 1 - i as i32)
                .rem_euclid(self.input_buffer.len() as i32) as usize;
            self.fft_input[i] = self.input_buffer[read_idx] * self.window[i];
        }

        // Perform FFT (in-place)
        let mut spectrum = self.fft_planner.make_output_vec();
        self.fft_planner
            .process(&mut self.fft_input, &mut spectrum)
            .unwrap_or_else(|e| {
                tracing::warn!("FFT processing failed: {}", e);
            });

        // Calculate window normalization factor
        // For amplitude spectrum, we need to account for the window's effect
        // Standard formula: amplitude = (2 * FFT_magnitude) / window_sum
        let window_sum: f32 = self.window.iter().sum();
        let norm_factor = 2.0 / window_sum;

        // Convert complex spectrum to magnitude in dBFS
        let bin_count = self.fft_size / 2 + 1;
        let mut raw_magnitudes = Vec::with_capacity(bin_count);
        for i in 0..bin_count {
            let real = spectrum[i].re;
            let imag = spectrum[i].im;
            let magnitude = (real * real + imag * imag).sqrt();

            // Normalize by window only (except DC and Nyquist which we'll silence)
            let normalized_magnitude = magnitude * norm_factor;
            raw_magnitudes.push(normalized_magnitude);

            // Convert to dBFS (20 * log10(magnitude / full_scale))
            // Here normalized_magnitude is already relative to full-scale input (due to window normalization),
            // so full_scale = 1.0
            let db = 20.0 * (normalized_magnitude + 1e-20).log10();

            // Clamp to dBFS range [-160, 0]
            self.fft_output[i] = db.max(-160.0).min(0.0);
        }

        // High-pass filter: silence frequencies below ~30 Hz to remove DC and subsonic rumble
        // Apply BEFORE smoothing to prevent contamination
        let freq_per_bin = self.sample_rate / self.fft_size as f32;
        let cutoff_freq = 30.0; // Hz
                                // Calculate highest bin index where center frequency is <= cutoff
                                // Use ceil to include partial bins (bin 0 at 0Hz + any bins whose upper edge is <= cutoff)
        let cutoff_bin_inclusive =
            ((cutoff_freq / freq_per_bin).ceil() as usize).min(bin_count.saturating_sub(1));
        for i in 0..=cutoff_bin_inclusive {
            self.fft_output[i] = -160.0;
        }
        // Also silence Nyquist bin (not musically relevant)
        self.fft_output[bin_count - 1] = -160.0;

        // Apply exponential smoothing AFTER high-pass filter
        for i in 0..bin_count {
            self.smoothed_output[i] = self.smoothing_factor * self.smoothed_output[i]
                + (1.0 - self.smoothing_factor) * self.fft_output[i];
        }

        // DEBUG: Log low-frequency bins and peak to diagnose red block issue
        static mut DEBUG_LOG_COUNT: u32 = 0;
        unsafe {
            DEBUG_LOG_COUNT += 1;
            if DEBUG_LOG_COUNT <= 20 || DEBUG_LOG_COUNT % 100 == 0 {
                let freq_per_bin = self.sample_rate / self.fft_size as f32;

                // Log first 10 bins (should all be -160.0)
                let mut low_bins_str = String::new();
                for i in 0..10.min(bin_count) {
                    let freq = i as f32 * freq_per_bin;
                    low_bins_str.push_str(&format!(
                        "[{}: {:.1}Hz = {:.1}dB] ",
                        i, freq, self.smoothed_output[i]
                    ));
                }

                // Find peak bin
                let mut peak_bin = cutoff_bin_inclusive + 1;
                let mut peak_db = self.smoothed_output[peak_bin];
                for i in (cutoff_bin_inclusive + 1)..bin_count - 1 {
                    if self.smoothed_output[i] > peak_db {
                        peak_bin = i;
                        peak_db = self.smoothed_output[i];
                    }
                }
                let peak_freq = peak_bin as f32 * freq_per_bin;

                info!(
                    "Spectrum | Cutoff bin: {} ({:.1}Hz) | Low bins (0-9): {} | Peak: bin {} @ {:.1}Hz = {:.1}dBFS",
                    cutoff_bin_inclusive, cutoff_bin_inclusive as f32 * freq_per_bin,
                    low_bins_str, peak_bin, peak_freq, peak_db
                );
            }
        }
    }

    /// Check if it's time to compute FFT and serialize data
    fn maybe_compute_and_serialize(&mut self) -> Option<Vec<u8>> {
        let now = std::time::Instant::now();
        if now.duration_since(self.last_fft_time) < self.fft_interval {
            return None; // Not time yet
        }

        self.last_fft_time = now;
        self.compute_fft();

        // Serialize f32 array to bytes
        let byte_count = self.smoothed_output.len() * std::mem::size_of::<f32>();
        let mut bytes = Vec::with_capacity(byte_count);

        // SAFETY: f32 is repr(C) and has well-defined byte representation
        unsafe {
            let ptr = self.smoothed_output.as_ptr() as *const u8;
            let slice = std::slice::from_raw_parts(ptr, byte_count);
            bytes.extend_from_slice(slice);
        }

        // DEBUG: Log first float's raw bytes
        static mut BYTE_DEBUG_COUNT: u32 = 0;
        unsafe {
            BYTE_DEBUG_COUNT += 1;
            if BYTE_DEBUG_COUNT <= 5 {
                let bin0_value = self.smoothed_output[0];
                let bin0_bytes = &bytes[0..4];
                info!(
                    "Spectrum serialization: bin[0] = {:.1} dBFS, bytes = [{:02X} {:02X} {:02X} {:02X}]",
                    bin0_value, bin0_bytes[0], bin0_bytes[1], bin0_bytes[2], bin0_bytes[3]
                );
            }
        }

        Some(bytes)
    }
}

impl AudioDevice for SpectrumAnalyzerDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Pass through audio unmodified
        outputs[..sample_count * 2].copy_from_slice(&inputs[..sample_count * 2]);

        // Accumulate audio into circular buffer (mono mix of L+R)
        for i in 0..sample_count {
            let left = inputs[i * 2];
            let right = inputs[i * 2 + 1];
            let mono = (left + right) * 0.5;

            self.input_buffer[self.write_pos] = mono;
            self.write_pos = (self.write_pos + 1) % self.input_buffer.len();
        }
    }

    fn set_parameter(&mut self, param_id: ParamId, value: ParamValue) {
        self.current_params.insert(param_id, value);

        match param_id {
            0 => {
                // FFT Size selector (normalized 0.0-1.0) → 512/1024/2048/4096
                let fft_size = if value < 0.25 {
                    512
                } else if value < 0.5 {
                    1024
                } else if value < 0.75 {
                    2048
                } else {
                    4096
                };
                self.update_fft_size(fft_size);
            }
            1 => {
                // Speed is UI-only. Engine keeps its own internal smoothing.
                // Intentionally do nothing here beyond storing in current_params.
            }
            _ => {}
        }
    }

    fn get_parameter(&self, param_id: ParamId) -> Option<ParamValue> {
        self.current_params.get(&param_id).copied()
    }

    fn device_id(&self) -> &str {
        &self.device_id
    }

    fn device_name(&self) -> &str {
        &self.device_name
    }

    fn device_category(&self) -> DeviceCategory {
        DeviceCategory::Utility
    }

    fn device_variant(&self) -> DeviceVariant {
        DeviceVariant::BuiltIn
    }

    fn audio_ports(&self) -> Vec<AudioPort> {
        vec![
            AudioPort {
                id: 0,
                name: "Input".to_string(),
                flow: PortFlow::Input,
                channels: 2,
            },
            AudioPort {
                id: 1,
                name: "Output".to_string(),
                flow: PortFlow::Output,
                channels: 2,
            },
        ]
    }

    fn parameters(&self) -> Vec<ParamInfo> {
        let mut v = vec![
            ParamInfo {
                id: 0,
                name: "FFT Size".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.5, // index will be derived on UI side
                is_automation_safe: true,
                param_type: ParamType::Enum,
                syncable: true,
                enum_values: vec![
                    "Tiny".to_string(),   // 512
                    "Small".to_string(),  // 1024
                    "Medium".to_string(), // 2048
                    "Large".to_string(),  // 4096
                ],
            },
            ParamInfo {
                id: 1,
                name: "Speed".to_string(),
                unit: String::new(),
                min: 0.0,
                max: 1.0,
                default: 0.75, // default to Medium/Fast-ish
                is_automation_safe: true,
                param_type: ParamType::Enum,
                syncable: false,
                enum_values: vec![
                    "Freeze".to_string(),
                    "Slow".to_string(),
                    "Medium".to_string(),
                    "Fast".to_string(),
                ],
            },
        ];

        // UI-only parameters for visualization (not synced to engine)
        // TODO: move these to array above?
        v.push(ParamInfo {
            id: 100,
            name: "Scale".to_string(),
            unit: String::new(),
            min: 0.0,
            max: 0.0,
            default: 0.0,
            is_automation_safe: false,
            param_type: ParamType::Enum,
            syncable: false,
            enum_values: vec!["Log".to_string(), "Linear".to_string()],
        });
        v.push(ParamInfo {
            id: 101,
            name: "Style".to_string(),
            unit: String::new(),
            min: 0.0,
            max: 0.0,
            default: 0.0,
            is_automation_safe: false,
            param_type: ParamType::Enum,
            syncable: false,
            enum_values: vec!["Bars".to_string(), "Line".to_string()],
        });
        // Removed separate "Hold Peaks" boolean; use Speed enum with "Freeze" instead

        v
    }

    fn reset(&mut self) {
        // Clear buffers
        self.input_buffer.fill(0.0);
        self.fft_input.fill(0.0);
        self.fft_output.fill(0.0);
        self.smoothed_output.fill(-160.0);
        self.write_pos = 0;
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    // === Device Data Subscriptions ===

    fn subscribe_data(&mut self, data_type: &str) -> Result<(), String> {
        if data_type == "spectrum" {
            info!("Spectrum Analyzer: Subscribed to spectrum data");
            self.subscriptions.insert(data_type.to_string(), true);
            Ok(())
        } else {
            Err(format!(
                "Spectrum Analyzer does not support '{}' data type",
                data_type
            ))
        }
    }

    fn unsubscribe_data(&mut self, data_type: &str) {
        if data_type == "spectrum" {
            info!("Spectrum Analyzer: Unsubscribed from spectrum data");
            self.subscriptions.remove(data_type);
        }
    }

    fn poll_device_data(&mut self) -> Option<(String, Vec<u8>)> {
        // Only compute FFT if subscribed to spectrum
        if !self.subscriptions.contains_key("spectrum") {
            return None;
        }

        self.maybe_compute_and_serialize()
            .map(|bytes| ("spectrum".to_string(), bytes))
    }
}
