use tracing::info;
use rustwav::WaveReader;

/// Load WAV file and return samples as Vec<f32>
///
/// Returns samples in the range -1.0 to 1.0, with channels interleaved
/// (e.g., for stereo: [L, R, L, R, ...])
pub fn load_wav_file(file_path: &str) -> std::result::Result<Vec<f32>, Box<dyn std::error::Error>> {
    // Open file with rustwav
    let mut reader = WaveReader::open(file_path)?;

    let spec = reader.spec();
    let num_channels = spec.channels as usize;
    let sample_rate = spec.sample_rate;
    let bits_per_sample = spec.bits_per_sample;

    info!("Loading WAV file: {} Hz, {} channels, {} bits/sample",
        sample_rate, num_channels, bits_per_sample);

    let mut samples = Vec::new();

    // Read samples using appropriate iterator based on channel count
    // rustwav already returns normalized f32 samples in the -1.0 to 1.0 range
    match num_channels {
        1 => {
            // Mono: read samples directly
            let iter = reader.mono_iter::<f32>()?;
            for sample in iter {
                samples.push(sample);
            }
        }
        2 => {
            // Stereo: read (left, right) pairs and interleave
            let iter = reader.stereo_iter::<f32>()?;
            for (left, right) in iter {
                samples.push(left);
                samples.push(right);
            }
        }
        _ => {
            // Multi-channel: read frames and interleave
            let iter = reader.frame_iter::<f32>()?;
            for frame in iter {
                for sample in frame {
                    samples.push(sample);
                }
            }
        }
    }

    // Log sample statistics for debugging
    if !samples.is_empty() {
        let min = samples.iter().cloned().fold(f32::INFINITY, f32::min);
        let max = samples.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        let first_10 = samples.iter().take(10).map(|s| format!("{:.6}", s)).collect::<Vec<_>>().join(", ");
        info!("Loaded {} total samples: min={:.6}, max={:.6} ({} channels × {} frames)",
            samples.len(), min, max, num_channels, samples.len() / num_channels);
        info!("First 10 samples: {}", first_10);
    }

    Ok(samples)
}
