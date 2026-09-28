//! Raw sample windows at the file's own rate, for drawing the waveform at deep zoom.
//!
//! Peaks and the display work in native (source) frames, so this re-reads the source file with
//! a seek plus a short decode instead of using the project-rate playback buffer. The reader
//! keeps the last decoded window per file, so neighbouring chunk requests (and the other
//! channel) are served from memory.

use anyhow::{anyhow, Result};
use std::collections::VecDeque;
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::DecoderOptions;
use symphonia::core::formats::{FormatOptions, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// Most frames one request may ask for. One f32 channel of this fits a 16 KB OSC blob.
pub const MAX_REQUEST_FRAMES: usize = 4096;
/// Frames decoded per cached window; requests are served from aligned windows of this size.
const WINDOW_FRAMES: u64 = 65536;
/// Files whose last window is kept.
const MAX_CACHED_FILES: usize = 8;

/// Decoded planar samples covering `[start, start + len)` native frames of one file.
struct Window {
    key: String,
    start: u64,
    channels: Vec<Vec<f32>>,
}

impl Window {
    fn len(&self) -> u64 {
        self.channels.first().map(|c| c.len() as u64).unwrap_or(0)
    }
}

/// Serves `(file, channel, start, count)` requests from a small per-file window cache.
#[derive(Default)]
pub struct SampleReader {
    windows: VecDeque<Window>,
}

impl SampleReader {
    pub fn new() -> Self {
        Self::default()
    }

    /// Samples of `channel` for native frames `[start, start + count)`, clipped to the end of
    /// the file (so the result may be shorter than `count`, or empty past the end).
    pub fn read(
        &mut self,
        key: &str,
        path: &str,
        channel: usize,
        start: u64,
        count: usize,
    ) -> Result<Vec<f32>> {
        let count = count.min(MAX_REQUEST_FRAMES) as u64;
        let end = start + count;
        let hit = self
            .windows
            .iter()
            .position(|w| w.key == key && w.start <= start && end <= w.start + w.len());
        let idx = match hit {
            Some(i) => i,
            None => {
                let w0 = start / WINDOW_FRAMES * WINDOW_FRAMES;
                let w1 = end.div_ceil(WINDOW_FRAMES) * WINDOW_FRAMES;
                let channels = read_frames(path, w0, w1 - w0)?;
                if self.windows.len() >= MAX_CACHED_FILES {
                    self.windows.pop_back();
                }
                self.windows.retain(|w| w.key != key);
                self.windows.push_front(Window {
                    key: key.to_string(),
                    start: w0,
                    channels,
                });
                0
            }
        };
        let w = &self.windows[idx];
        let data = w
            .channels
            .get(channel)
            .ok_or_else(|| anyhow!("channel {} out of range ({})", channel, w.channels.len()))?;
        let from = ((start - w.start) as usize).min(data.len());
        let to = ((end - w.start) as usize).min(data.len());
        Ok(data[from..to].to_vec())
    }
}

/// Decode native frames `[start, start + count)` of `path` as planar f32, clipped to the end
/// of the file. Seeks when the format supports it; otherwise decodes from the beginning.
/// Frame positions match a straight decode from frame 0, which is what the peak file uses.
pub fn read_frames(path: &str, start: u64, count: u64) -> Result<Vec<Vec<f32>>> {
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = Path::new(path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
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
    let track_id = track.id;
    let codec_params = track.codec_params.clone();
    let sample_rate = codec_params
        .sample_rate
        .ok_or_else(|| anyhow!("Unknown sample rate"))? as u64;
    let channels = codec_params
        .channels
        .ok_or_else(|| anyhow!("Unknown channel layout"))?
        .count();
    let mut decoder =
        symphonia::default::get_codecs().make(&codec_params, &DecoderOptions::default())?;

    // Track timestamps -> native frames. Most audio formats use 1/sample_rate.
    let ts_to_frame = |ts: u64| -> u64 {
        match codec_params.time_base {
            Some(tb) if tb.denom as u64 != sample_rate || tb.numer != 1 => {
                (ts as u128 * tb.numer as u128 * sample_rate as u128 / tb.denom as u128) as u64
            }
            _ => ts,
        }
    };
    let frame_to_ts = |frame: u64| -> u64 {
        match codec_params.time_base {
            Some(tb) if tb.denom as u64 != sample_rate || tb.numer != 1 => {
                (frame as u128 * tb.denom as u128 / (tb.numer as u128 * sample_rate as u128)) as u64
            }
            _ => frame,
        }
    };

    // Position (in native frames) of the next decoded sample. Unknown after a seek until the
    // first packet's timestamp is seen.
    let mut pos: Option<u64> = Some(0);
    if start > 0 {
        let seek = format.seek(
            SeekMode::Accurate,
            SeekTo::TimeStamp {
                ts: frame_to_ts(start),
                track_id,
            },
        );
        match seek {
            Ok(_) => {
                decoder.reset();
                pos = None;
            }
            Err(e) => {
                tracing::debug!(file = %path, error = %e, "sample reader: seek failed, decoding from start");
            }
        }
    }

    let end = start + count;
    let mut out: Vec<Vec<f32>> = vec![Vec::with_capacity(count as usize); channels];
    loop {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(symphonia::core::errors::Error::IoError(e))
                if e.kind() == std::io::ErrorKind::UnexpectedEof =>
            {
                break
            }
            Err(e) => return Err(e.into()),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let packet_pos = *pos.get_or_insert_with(|| ts_to_frame(packet.ts()));
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(symphonia::core::errors::Error::DecodeError(e)) => {
                tracing::debug!(file = %path, error = %e, "sample reader: skipping bad packet");
                continue;
            }
            Err(e) => return Err(e.into()),
        };
        if decoded.frames() == 0 {
            continue;
        }
        let mut buf: SampleBuffer<f32> =
            SampleBuffer::new(decoded.frames() as u64, *decoded.spec());
        buf.copy_interleaved_ref(decoded);
        let samples = buf.samples();
        let frames = samples.len() / channels.max(1);
        let packet_end = packet_pos + frames as u64;
        pos = Some(packet_end);
        if packet_end <= start {
            continue;
        }
        let from = start.saturating_sub(packet_pos) as usize;
        let to = (end.min(packet_end) - packet_pos) as usize;
        for f in from..to {
            for (ch, dst) in out.iter_mut().enumerate() {
                dst.push(samples[f * channels + ch]);
            }
        }
        if packet_end >= end {
            break;
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Mono 16-bit WAV whose sample at frame i encodes i, so positions can be checked exactly.
    fn write_ramp_wav(path: &Path, frames: usize) {
        let sr = 48000u32;
        let mut data = Vec::with_capacity(frames * 2);
        for i in 0..frames {
            data.extend_from_slice(&((i % 30000) as i16).to_le_bytes());
        }
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&sr.to_le_bytes());
        wav.extend_from_slice(&(sr * 2).to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&(data.len() as u32).to_le_bytes());
        wav.extend_from_slice(&data);
        std::fs::write(path, wav).unwrap();
    }

    fn frame_value(i: u64) -> f32 {
        (i % 30000) as f32 / 32768.0
    }

    #[test]
    fn test_read_frames_after_seek_matches_positions() {
        let dir = tempfile::tempdir().unwrap();
        let wav = dir.path().join("ramp.wav");
        write_ramp_wav(&wav, 200_000);
        let path = wav.to_string_lossy().to_string();
        let out = read_frames(&path, 100_003, 50).unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].len(), 50);
        for (k, v) in out[0].iter().enumerate() {
            assert!(
                (v - frame_value(100_003 + k as u64)).abs() < 1e-6,
                "frame {}",
                k
            );
        }
    }

    #[test]
    fn test_reader_clips_at_end_and_caches_window() {
        let dir = tempfile::tempdir().unwrap();
        let wav = dir.path().join("ramp.wav");
        write_ramp_wav(&wav, 70_000);
        let path = wav.to_string_lossy().to_string();
        let mut reader = SampleReader::new();
        assert!(
            reader.read("k", &path, 1, 0, 16).is_err(),
            "mono file has no channel 1"
        );

        let a = reader.read("k", &path, 0, 4096, 4096).unwrap();
        assert_eq!(a.len(), 4096);
        assert!((a[0] - frame_value(4096)).abs() < 1e-6);

        // Past the end of the file: clipped, then empty.
        let b = reader.read("k", &path, 0, 69_000, 4096).unwrap();
        assert_eq!(b.len(), 1000);
        assert!((b[999] - frame_value(69_999)).abs() < 1e-6);
        assert!(reader.read("k", &path, 0, 80_000, 16).unwrap().is_empty());

        // The last window per file is served from memory, even once the file is gone.
        std::fs::remove_file(&wav).unwrap();
        assert_eq!(reader.read("k", &path, 0, 66_000, 16).unwrap().len(), 16);
        assert!(reader.read("k", &path, 0, 8192, 16).is_err());
    }
}
