//! Stereo WAV files for renders, written to a `.part` file and renamed when complete, so a
//! failed or cancelled render never leaves a truncated file at the requested path.

use hound::{SampleFormat, WavSpec, WavWriter};
use std::fs::File;
use std::io::BufWriter;
use std::path::{Path, PathBuf};

use super::WavFormat;

/// One stereo WAV file being written. Dropping it unfinished deletes the partial file.
pub struct WavOutput {
    path: PathBuf,
    part_path: PathBuf,
    format: WavFormat,
    writer: Option<WavWriter<BufWriter<File>>>,
}

impl WavOutput {
    /// Create `<path>.part` (and missing parent directories) for a stereo file at `sample_rate`.
    pub fn create(path: &Path, sample_rate: u32, format: WavFormat) -> Result<Self, String> {
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("can't create {}: {}", parent.display(), e))?;
        }
        let mut part_name = path.as_os_str().to_owned();
        part_name.push(".part");
        let part_path = PathBuf::from(part_name);
        let (bits_per_sample, sample_format) = match format {
            WavFormat::Int16 => (16, SampleFormat::Int),
            WavFormat::Int24 => (24, SampleFormat::Int),
            WavFormat::Float32 => (32, SampleFormat::Float),
        };
        let spec = WavSpec {
            channels: 2,
            sample_rate,
            bits_per_sample,
            sample_format,
        };
        let writer = WavWriter::create(&part_path, spec)
            .map_err(|e| format!("can't write {}: {}", part_path.display(), e))?;
        Ok(Self {
            path: path.to_path_buf(),
            part_path,
            format,
            writer: Some(writer),
        })
    }

    /// Append interleaved stereo frames.
    pub fn write(&mut self, interleaved: &[f32]) -> Result<(), String> {
        let Some(writer) = self.writer.as_mut() else {
            return Err("output already finished".to_string());
        };
        let result = match self.format {
            WavFormat::Float32 => interleaved.iter().try_for_each(|&s| writer.write_sample(s)),
            WavFormat::Int16 => interleaved.iter().try_for_each(|&s| {
                writer.write_sample((s.clamp(-1.0, 1.0) * 32_767.0).round() as i16)
            }),
            WavFormat::Int24 => interleaved.iter().try_for_each(|&s| {
                writer.write_sample((s.clamp(-1.0, 1.0) * 8_388_607.0).round() as i32)
            }),
        };
        result.map_err(|e| format!("can't write {}: {}", self.part_path.display(), e))
    }

    /// Finish the file and move it to its final path, replacing any file there.
    pub fn finish(mut self) -> Result<PathBuf, String> {
        let writer = self.writer.take().expect("finish is only called once");
        writer
            .finalize()
            .map_err(|e| format!("can't finish {}: {}", self.part_path.display(), e))?;
        std::fs::rename(&self.part_path, &self.path).map_err(|e| {
            let _ = std::fs::remove_file(&self.part_path);
            format!("can't move the render to {}: {}", self.path.display(), e)
        })?;
        Ok(std::mem::take(&mut self.path))
    }
}

impl Drop for WavOutput {
    fn drop(&mut self) {
        if let Some(writer) = self.writer.take() {
            drop(writer);
            let _ = std::fs::remove_file(&self.part_path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_and_renames_or_cleans_up() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sub/out.wav");

        let mut out = WavOutput::create(&path, 48_000, WavFormat::Int16).unwrap();
        out.write(&[0.5, -0.5, 2.0, -2.0]).unwrap();
        assert_eq!(out.finish().unwrap(), path);
        let samples: Vec<i16> = hound::WavReader::open(&path)
            .unwrap()
            .samples::<i16>()
            .map(Result::unwrap)
            .collect();
        assert_eq!(samples, vec![16_384, -16_384, 32_767, -32_767]);

        let dropped = dir.path().join("dropped.wav");
        let mut out = WavOutput::create(&dropped, 48_000, WavFormat::Float32).unwrap();
        out.write(&[0.1, 0.1]).unwrap();
        drop(out);
        assert!(!dropped.exists());
        assert!(!dir.path().join("dropped.wav.part").exists());
    }
}
