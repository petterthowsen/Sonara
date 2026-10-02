use super::{
    AudioDevice, AudioPort, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamType,
    ParamValue, PortFlow,
};
use crate::audio::dsp::spectrum::Spectrum;
use std::collections::HashMap;
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

    /// Windowed FFT and smoothed dB spectrum (`dsp::spectrum`).
    spectrum: Spectrum,
    hop_size: usize, // Hop size in samples (controls update cadence)

    // Subscription state
    subscriptions: HashMap<String, bool>,
    last_fft_time: std::time::Instant,
    fft_interval: std::time::Duration,

    // Parameters
    current_params: HashMap<ParamId, ParamValue>,
}

/// FFT size a new analyser starts with.
const DEFAULT_FFT_SIZE: usize = 2048;
/// Exponential smoothing of the displayed spectrum.
const SMOOTHING: f32 = 0.7;

impl SpectrumAnalyzerDevice {
    pub fn new(sample_rate: f32) -> Self {
        info!(
            "SpectrumAnalyzerDevice::new() - sample_rate={}",
            sample_rate
        );

        // Default parameters
        let mut current_params = HashMap::new();
        current_params.insert(0, 0.5); // FFT size selector → 2048 by default
        current_params.insert(1, 0.7); // Speed (UI-only; engine ignores it)

        let hop_size = DEFAULT_FFT_SIZE / 2; // 50% overlap
        Self {
            device_id: "sonara.builtin.spectrum_analyzer".to_string(),
            device_name: "Spectrum Analyzer".to_string(),
            sample_rate,
            spectrum: Spectrum::new(DEFAULT_FFT_SIZE, SMOOTHING),
            hop_size,
            subscriptions: HashMap::new(),
            last_fft_time: std::time::Instant::now(),
            fft_interval: std::time::Duration::from_secs_f32(hop_size as f32 / sample_rate),
            current_params,
        }
    }

    /// Update FFT size and reallocate buffers (command thread, from `set_parameter`).
    fn update_fft_size(&mut self, new_size: usize) {
        if new_size == self.spectrum.size() {
            return;
        }
        info!(
            "Spectrum Analyzer: Updating FFT size from {} to {}",
            self.spectrum.size(),
            new_size
        );
        self.spectrum.resize(new_size);
        self.hop_size = new_size / 2; // keep 50% overlap
        self.fft_interval =
            std::time::Duration::from_secs_f32(self.hop_size as f32 / self.sample_rate);
    }

    /// Check if it's time to compute FFT and serialize data
    fn maybe_compute_and_serialize(&mut self) -> Option<Vec<u8>> {
        let now = std::time::Instant::now();
        if now.duration_since(self.last_fft_time) < self.fft_interval {
            return None; // Not time yet
        }

        self.last_fft_time = now;
        self.spectrum.compute(self.sample_rate);

        // Serialize the f32 bins as little-endian bytes.
        let bins = self.spectrum.smoothed();
        let mut bytes = Vec::with_capacity(bins.len() * std::mem::size_of::<f32>());
        for value in bins {
            bytes.extend_from_slice(&value.to_le_bytes());
        }
        Some(bytes)
    }
}

impl AudioDevice for SpectrumAnalyzerDevice {
    fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
        // Pass through audio unmodified
        outputs[..sample_count * 2].copy_from_slice(&inputs[..sample_count * 2]);

        // Accumulate a mono mix of L+R for the FFT.
        for frame in inputs[..sample_count * 2].chunks_exact(2) {
            self.spectrum.push((frame[0] + frame[1]) * 0.5);
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                is_logarithmic: false,
                skew: 1.0,
                display: Vec::new(),
                module: String::new(),
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
                is_hidden: false,
                is_read_only: false,
                is_bypass: false,
                is_logarithmic: false,
                skew: 1.0,
                display: Vec::new(),
                module: String::new(),
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
            is_hidden: false,
            is_read_only: false,
            is_bypass: false,
            is_logarithmic: false,
            skew: 1.0,
            display: Vec::new(),
            module: String::new(),
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
            is_hidden: false,
            is_read_only: false,
            is_bypass: false,
            is_logarithmic: false,
            skew: 1.0,
            display: Vec::new(),
            module: String::new(),
            param_type: ParamType::Enum,
            syncable: false,
            enum_values: vec!["Bars".to_string(), "Line".to_string()],
        });
        // Removed separate "Hold Peaks" boolean; use Speed enum with "Freeze" instead

        v
    }

    fn prepare(&mut self, sample_rate: f32, _max_frames: usize) {
        self.sample_rate = sample_rate;
        self.fft_interval =
            std::time::Duration::from_secs_f32(self.hop_size as f32 / self.sample_rate);
        self.reset();
    }

    fn reset(&mut self) {
        self.spectrum.reset();
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
