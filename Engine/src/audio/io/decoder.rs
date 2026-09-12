use anyhow::{anyhow, Result};
use rubato::{FftFixedIn, Resampler};
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use tracing;

/// Information about decoded audio data
#[derive(Debug, Clone)]
pub struct DecodedInfo {
    pub channels: u16,
    pub frames: u64,
    pub sample_rate: u32,
    pub duration_s: f32,
}

/// Trait for audio decoding with streaming callback
pub trait AudioDecoder {
    fn decode_to_f32_stream(
        &mut self,
        target_sr: u32,
        on_chunk: &mut dyn FnMut(&[Vec<f32>]) -> Result<()>,
    ) -> Result<DecodedInfo>;
}

/// Symphonia-based decoder implementation
pub struct SymphoniaDecoder {
    path: String,
}

impl SymphoniaDecoder {
    pub fn new(path: impl Into<String>) -> Self {
        Self { path: path.into() }
    }
}

impl AudioDecoder for SymphoniaDecoder {
    fn decode_to_f32_stream(
        &mut self,
        target_sr: u32,
        on_chunk: &mut dyn FnMut(&[Vec<f32>]) -> Result<()>,
    ) -> Result<DecodedInfo> {
        // Open the file and create a media source
        let file = File::open(&self.path)?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());

        // Create a probe hint with the file extension
        let mut hint = Hint::new();
        if let Some(ext) = Path::new(&self.path).extension() {
            if let Some(ext_str) = ext.to_str() {
                hint.with_extension(ext_str);
            }
        }

        // Probe the media source
        let probed = symphonia::default::get_probe().format(
            &hint,
            mss,
            &FormatOptions::default(),
            &MetadataOptions::default(),
        )?;

        let mut format = probed.format;
        let track = format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != symphonia::core::codecs::CODEC_TYPE_NULL)
            .ok_or_else(|| anyhow!("No suitable audio track found"))?;

        let sample_rate = track
            .codec_params
            .sample_rate
            .ok_or_else(|| anyhow!("Unknown sample rate"))?;
        let channels = track
            .codec_params
            .channels
            .ok_or_else(|| anyhow!("Unknown channel layout"))?
            .count() as u16;

        tracing::info!(
            "Symphonia decoder: original sample_rate={}, target_sr={}, channels={}",
            sample_rate,
            target_sr,
            channels
        );

        // Create decoder using the default registry
        let registry = symphonia::default::get_codecs();
        let mut decoder = registry.make(&track.codec_params, &DecoderOptions::default())?;

        let mut total_frames = 0u64;
        let mut resampler: Option<FftFixedIn<f32>> = None;
        let mut input_buffer: Vec<Vec<f32>> = Vec::new(); // Buffer for accumulating chunks
        let resampler_chunk_size = 4096usize;

        // Initialize resampler if needed
        if sample_rate != target_sr {
            resampler = Some(FftFixedIn::<f32>::new(
                sample_rate as usize,
                target_sr as usize,
                resampler_chunk_size, // chunk size for processing (larger for FFT quality)
                2,                    // sub_chunks (quality)
                channels as usize,
            )?);
            // Pre-allocate buffer for accumulating input chunks
            input_buffer = vec![Vec::with_capacity(resampler_chunk_size); channels as usize];
        }

        // Decode loop
        loop {
            let packet = match format.next_packet() {
                Ok(packet) => packet,
                Err(symphonia::core::errors::Error::IoError(err))
                    if err.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    break
                }
                Err(err) => return Err(err.into()),
            };

            // Decode the packet into f32 buffer
            let decoded = decoder.decode(&packet)?;
            let frame_count = decoded.frames();
            if frame_count == 0 {
                continue;
            }

            let mut sample_buf: SampleBuffer<f32> =
                SampleBuffer::new(frame_count as u64, decoded.spec().clone());
            sample_buf.copy_interleaved_ref(decoded);

            // Some codecs (e.g. MP3) may report a larger frame count than the
            // actual interleaved sample slice provides. Clamp the logical
            // length so downstream consumers see only valid frames.
            let available_frames = if channels > 0 {
                sample_buf.samples().len() / channels as usize
            } else {
                0
            };

            if available_frames == 0 {
                tracing::warn!(
                    "MP3 decode: available_frames is 0, frame_count={}, sample_buf.len()={}",
                    frame_count,
                    sample_buf.len()
                );
                continue;
            }

            // Use the available frames directly - it's been clamped to actual samples
            let frames_to_use = available_frames;

            tracing::debug!("MP3 decode: frame_count={}, available_frames={}, frames_to_use={}, channels={}, samples.len()={}",
                frame_count, available_frames, frames_to_use, channels, sample_buf.samples().len());

            // Convert to planar f32 vectors
            let planar_data = buffer_to_planar_f32(&sample_buf, channels as usize, frames_to_use);
            if planar_data.is_empty() || planar_data[0].is_empty() {
                continue;
            }

            // Resample if needed
            let processed_data = if let Some(ref mut resamp) = resampler {
                // Accumulate input chunks until we have enough for the resampler
                for ch in 0..channels as usize {
                    input_buffer[ch].extend_from_slice(&planar_data[ch]);
                }

                let mut output_data_all = vec![Vec::new(); channels as usize];

                // Process all complete chunks in the buffer
                while input_buffer[0].len() >= resampler_chunk_size {
                    // Extract one chunk from the buffer
                    let mut chunk_data =
                        vec![Vec::with_capacity(resampler_chunk_size); channels as usize];
                    for ch in 0..channels as usize {
                        chunk_data[ch]
                            .extend_from_slice(&input_buffer[ch][0..resampler_chunk_size]);
                        input_buffer[ch].drain(0..resampler_chunk_size);
                    }

                    // Allocate output buffer based on resampling ratio
                    let resample_ratio = target_sr as f32 / sample_rate as f32;
                    let estimated_output =
                        (resampler_chunk_size as f32 * resample_ratio * 1.2) as usize + 512;
                    let mut output_data = vec![vec![0.0f32; estimated_output]; channels as usize];

                    // Process the resampler
                    let (_input_consumed, output_frames) =
                        resamp.process_into_buffer(&chunk_data, &mut output_data, None)?;

                    // Truncate and append to result
                    for ch in 0..channels as usize {
                        output_data[ch].truncate(output_frames);
                        output_data_all[ch].extend_from_slice(&output_data[ch]);
                    }

                    tracing::debug!(
                        "MP3 resample: chunk_size={}, output_frames={}, buffer_remaining={}",
                        resampler_chunk_size,
                        output_frames,
                        input_buffer[0].len()
                    );

                    total_frames += output_frames as u64;
                }

                // Return all accumulated output so far
                if output_data_all[0].is_empty() {
                    // No complete chunks yet, skip callback
                    vec![vec![]; channels as usize]
                } else {
                    output_data_all
                }
            } else {
                total_frames += planar_data[0].len() as u64;
                planar_data
            };

            // Only call callback if we have data to process
            if !processed_data.is_empty() && !processed_data[0].is_empty() {
                on_chunk(&processed_data)?;
            }
        }

        // Flush remaining input buffer and resampler
        if let Some(ref mut resamp) = resampler {
            // First, process any remaining partial chunk in input_buffer by padding with zeros
            if !input_buffer.is_empty() && !input_buffer[0].is_empty() {
                let remaining_frames = input_buffer[0].len();
                tracing::debug!(
                    "MP3 resample: flushing remaining buffer with {} frames",
                    remaining_frames
                );

                // Pad the partial chunk with zeros to reach resampler_chunk_size
                let mut padded_chunk = input_buffer.clone();
                for ch in 0..channels as usize {
                    padded_chunk[ch].resize(resampler_chunk_size, 0.0);
                }

                // Process the padded chunk
                let resample_ratio = target_sr as f32 / sample_rate as f32;
                let estimated_output =
                    (resampler_chunk_size as f32 * resample_ratio * 1.2) as usize + 512;
                let mut output_data = vec![vec![0.0f32; estimated_output]; channels as usize];

                if let Ok((_consumed, output_frames)) =
                    resamp.process_into_buffer(&padded_chunk, &mut output_data, None)
                {
                    if output_frames > 0 {
                        for ch in 0..channels as usize {
                            output_data[ch].truncate(output_frames);
                        }
                        tracing::debug!(
                            "MP3 resample: padded flush output_frames={}",
                            output_frames
                        );
                        total_frames += output_frames as u64;
                        on_chunk(&output_data)?;
                    }
                }

                input_buffer.clear();
            }

            // Now flush resampler internal state
            let mut all_flushed = false;
            let max_flushes = 10;
            let mut flush_count = 0;

            while !all_flushed && flush_count < max_flushes {
                let flush_output_size = 16384;
                let mut output_data = vec![vec![0.0f32; flush_output_size]; channels as usize];
                let zero_input = vec![vec![0.0f32; resampler_chunk_size]; channels as usize];

                match resamp.process_into_buffer(&zero_input, &mut output_data, None) {
                    Ok((_consumed, output_frames)) => {
                        if output_frames > 0 {
                            // Truncate to actual output
                            for ch in 0..channels as usize {
                                output_data[ch].truncate(output_frames);
                            }

                            tracing::debug!(
                                "MP3 resample flush: output_frames={}, flush_count={}",
                                output_frames,
                                flush_count
                            );
                            total_frames += output_frames as u64;
                            on_chunk(&output_data)?;
                        } else {
                            all_flushed = true;
                        }
                    }
                    Err(e) => {
                        // If flush fails, log warning but don't fail the entire decode
                        tracing::warn!(
                            "MP3 resample flush failed at iteration {}: {}",
                            flush_count,
                            e
                        );
                        all_flushed = true;
                    }
                }
                flush_count += 1;
            }
        }

        let duration_s = total_frames as f32 / target_sr as f32;

        Ok(DecodedInfo {
            channels,
            frames: total_frames,
            sample_rate: target_sr,
            duration_s,
        })
    }
}

/// Convert Symphonia SampleBuffer to planar f32 vectors
fn buffer_to_planar_f32(buf: &SampleBuffer<f32>, channels: usize, frames: usize) -> Vec<Vec<f32>> {
    if channels == 0 || frames == 0 {
        return Vec::new();
    }

    let samples = buf.samples();
    let max_frames = samples.len() / channels;
    if max_frames == 0 {
        return vec![Vec::new(); channels];
    }

    let frames = frames.min(max_frames);

    let mut planar = vec![Vec::with_capacity(frames); channels];

    for frame in 0..frames {
        for ch in 0..channels {
            let sample = samples[frame * channels + ch];
            planar[ch].push(sample);
        }
    }

    planar
}

/// Load audio file synchronously and return interleaved f32 samples
/// Compatible with the existing load_wav_file API
pub fn load_audio_file(file_path: &str) -> Result<Vec<f32>> {
    let mut decoder = SymphoniaDecoder::new(file_path.to_string());
    let mut all_samples = Vec::new();
    let mut channels = 0;

    let decoded_info = decoder.decode_to_f32_stream(44100, &mut |chunk: &[Vec<f32>]| {
        // Convert planar to interleaved
        if channels == 0 {
            channels = chunk.len();
        }

        // Interleave samples: [L, R, L, R, ...]
        let frames_in_chunk = chunk[0].len();
        for frame in 0..frames_in_chunk {
            for ch in 0..channels {
                all_samples.push(chunk[ch][frame]);
            }
        }

        Ok(())
    })?;

    tracing::info!(
        "Loaded audio file: {} samples, {} Hz, {} channels, {:.2}s duration",
        all_samples.len(),
        decoded_info.sample_rate,
        decoded_info.channels,
        decoded_info.duration_s
    );

    Ok(all_samples)
}
