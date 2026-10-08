//! Peak cache file format v2 (`<key>.swp`).
//!
//! All values little-endian. A fixed 64-byte header, a level table (16 bytes per level), then
//! for each channel two texture-shaped planes of `total_rows × TEX_WIDTH` RGBA16F texels:
//! plane A holds `(min, max, rms, 0)` and plane B holds `(low, mid, high, 0)`. All levels of a
//! channel are stacked into one plane; each level starts on a new row and is zero-padded to a
//! full row. Godot hands each plane straight to `Image.create_from_data(..., FORMAT_RGBAH, ...)`.

use super::peaks::Peaks;
use anyhow::{anyhow, bail, Result};
use half::f16;
use std::fs::{self, File};
use std::io::{BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

pub const MAGIC: &[u8; 8] = b"SONAPK02";
pub const VERSION: u16 = 2;
pub const HEADER_SIZE: usize = 64;
pub const LEVEL_ENTRY_SIZE: usize = 16;
pub const TEX_WIDTH: u32 = 4096;
/// GPU texture height limit.
pub const MAX_ROWS: u64 = 16384;
pub const CACHE_EXT: &str = "swp";
const TEXEL_BYTES: u64 = 8;
const COMPLETE_OFFSET: u64 = 48;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LevelEntry {
    pub num_blocks: u64,
    pub row_offset: u32,
    pub rows: u32,
}

/// Header of a waveform cache file. Some fields are format metadata that only tests read back.
#[derive(Debug, Clone)]
pub struct PeakHeader {
    pub version: u16,
    pub channels: u16,
    #[allow(dead_code)] // On-disk format field, checked by the round-trip tests.
    pub source_sample_rate: u32,
    #[allow(dead_code)] // On-disk format field, checked by the round-trip tests.
    pub frames: u64,
    #[allow(dead_code)] // On-disk format field, checked by the round-trip tests.
    pub base_block: u32,
    pub tex_width: u16,
    pub src_size: u64,
    pub src_mtime_ns: u64,
    pub complete: bool,
    pub levels: Vec<LevelEntry>,
}

impl PeakHeader {
    pub fn total_rows(&self) -> u64 {
        self.levels.iter().map(|l| l.rows as u64).sum()
    }

    fn plane_bytes(&self) -> u64 {
        self.total_rows() * self.tex_width as u64 * TEXEL_BYTES
    }

    fn data_offset(&self) -> u64 {
        (HEADER_SIZE + self.levels.len() * LEVEL_ENTRY_SIZE) as u64
    }
}

fn level_table(peaks: &Peaks) -> Result<Vec<LevelEntry>> {
    let mut row = 0u64;
    let mut table = Vec::with_capacity(peaks.levels.len());
    for level in &peaks.levels {
        let num_blocks = level.num_blocks();
        let rows = num_blocks.div_ceil(TEX_WIDTH as u64).max(1);
        table.push(LevelEntry {
            num_blocks,
            row_offset: row as u32,
            rows: rows as u32,
        });
        row += rows;
    }
    if row > MAX_ROWS {
        bail!(
            "peak data needs {} texture rows, limit is {} (file too long)",
            row,
            MAX_ROWS
        );
    }
    Ok(table)
}

pub struct PeakFile;

impl PeakFile {
    /// Write `peaks` to `path`. The `complete` flag is written last, after the data is flushed.
    pub fn write(path: &Path, peaks: &Peaks, src_size: u64, src_mtime_ns: u64) -> Result<()> {
        let table = level_table(peaks)?;
        let mut file = File::create(path)?;
        {
            let mut w = BufWriter::with_capacity(1 << 20, &mut file);

            let mut header = [0u8; HEADER_SIZE];
            header[0..8].copy_from_slice(MAGIC);
            header[8..10].copy_from_slice(&VERSION.to_le_bytes());
            header[10..12].copy_from_slice(&peaks.channels.to_le_bytes());
            header[12..16].copy_from_slice(&peaks.source_sample_rate.to_le_bytes());
            header[16..24].copy_from_slice(&peaks.frames.to_le_bytes());
            header[24..28].copy_from_slice(&peaks.base_block.to_le_bytes());
            header[28..30].copy_from_slice(&(peaks.levels.len() as u16).to_le_bytes());
            header[30..32].copy_from_slice(&(TEX_WIDTH as u16).to_le_bytes());
            header[32..40].copy_from_slice(&src_size.to_le_bytes());
            header[40..48].copy_from_slice(&src_mtime_ns.to_le_bytes());
            header[COMPLETE_OFFSET as usize] = 0;
            w.write_all(&header)?;

            for entry in &table {
                w.write_all(&entry.num_blocks.to_le_bytes())?;
                w.write_all(&entry.row_offset.to_le_bytes())?;
                w.write_all(&entry.rows.to_le_bytes())?;
            }

            let texel = |a: f32, b: f32, c: f32| -> [u8; 8] {
                let mut t = [0u8; 8];
                t[0..2].copy_from_slice(&f16::from_f32(a).to_le_bytes());
                t[2..4].copy_from_slice(&f16::from_f32(b).to_le_bytes());
                t[4..6].copy_from_slice(&f16::from_f32(c).to_le_bytes());
                t
            };
            for ch in 0..peaks.channels as usize {
                for plane_b in [false, true] {
                    for (level, entry) in peaks.levels.iter().zip(&table) {
                        for block in &level.blocks[ch] {
                            let t = if plane_b {
                                texel(block[3].sqrt(), block[4].sqrt(), block[5].sqrt())
                            } else {
                                texel(block[0], block[1], block[2].sqrt())
                            };
                            w.write_all(&t)?;
                        }
                        let pad = entry.rows as u64 * TEX_WIDTH as u64 - entry.num_blocks;
                        let zeros = [0u8; 8 * 256];
                        let mut left = pad * TEXEL_BYTES;
                        while left > 0 {
                            let n = left.min(zeros.len() as u64) as usize;
                            w.write_all(&zeros[..n])?;
                            left -= n as u64;
                        }
                    }
                }
            }
            w.flush()?;
        }
        file.seek(SeekFrom::Start(COMPLETE_OFFSET))?;
        file.write_all(&[1])?;
        file.sync_all()?;
        Ok(())
    }

    pub fn read_header(path: &Path) -> Result<PeakHeader> {
        let mut file = File::open(path)?;
        let mut h = [0u8; HEADER_SIZE];
        file.read_exact(&mut h)?;
        if &h[0..8] != MAGIC {
            bail!("bad magic");
        }
        let u16_at = |o: usize| u16::from_le_bytes([h[o], h[o + 1]]);
        let u32_at = |o: usize| u32::from_le_bytes(h[o..o + 4].try_into().unwrap());
        let u64_at = |o: usize| u64::from_le_bytes(h[o..o + 8].try_into().unwrap());
        let num_levels = u16_at(28) as usize;
        let mut table = vec![0u8; num_levels * LEVEL_ENTRY_SIZE];
        file.read_exact(&mut table)?;
        let levels = table
            .chunks_exact(LEVEL_ENTRY_SIZE)
            .map(|e| LevelEntry {
                num_blocks: u64::from_le_bytes(e[0..8].try_into().unwrap()),
                row_offset: u32::from_le_bytes(e[8..12].try_into().unwrap()),
                rows: u32::from_le_bytes(e[12..16].try_into().unwrap()),
            })
            .collect();
        Ok(PeakHeader {
            version: u16_at(8),
            channels: u16_at(10),
            source_sample_rate: u32_at(12),
            frames: u64_at(16),
            base_block: u32_at(24),
            tex_width: u16_at(30),
            src_size: u64_at(32),
            src_mtime_ns: u64_at(40),
            complete: h[COMPLETE_OFFSET as usize] == 1,
            levels,
        })
    }

    /// Read one texel as f32 RGBA. `plane` is 0 (min/max/rms) or 1 (low/mid/high).
    #[cfg(test)]
    pub fn read_texel(
        path: &Path,
        header: &PeakHeader,
        channel: usize,
        plane: usize,
        level: usize,
        block: u64,
    ) -> Result<[f32; 4]> {
        let entry = header
            .levels
            .get(level)
            .ok_or_else(|| anyhow!("no level {}", level))?;
        let w = header.tex_width as u64;
        let row = entry.row_offset as u64 + block / w;
        let texel = row * w + block % w;
        let offset = header.data_offset()
            + (channel as u64 * 2 + plane as u64) * header.plane_bytes()
            + texel * TEXEL_BYTES;
        let mut file = File::open(path)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut t = [0u8; 8];
        file.read_exact(&mut t)?;
        Ok([0, 2, 4, 6].map(|i| f16::from_le_bytes([t[i], t[i + 1]]).to_f32()))
    }

    /// A cached file is usable only if it is complete, matches this format and was built from
    /// the source file as it is now on disk.
    pub fn is_valid(path: &Path, src_size: u64, src_mtime_ns: u64) -> bool {
        match Self::read_header(path) {
            Ok(h) => {
                h.version == VERSION
                    && h.complete
                    && h.src_size == src_size
                    && h.src_mtime_ns == src_mtime_ns
                    && fs::metadata(path)
                        .map(|m| {
                            m.len() >= h.data_offset() + h.plane_bytes() * 2 * h.channels as u64
                        })
                        .unwrap_or(false)
            }
            Err(_) => false,
        }
    }
}

/// Get the waveform cache directory (`$XDG_CACHE_HOME/sonara/waveforms/`).
pub fn get_cache_dir() -> Result<PathBuf> {
    if let Ok(cache_dir) = std::env::var("XDG_CACHE_HOME") {
        Ok(PathBuf::from(cache_dir).join("sonara").join("waveforms"))
    } else if let Some(home) = dirs::home_dir() {
        Ok(home.join(".cache").join("sonara").join("waveforms"))
    } else {
        Err(anyhow!("Could not determine cache directory"))
    }
}

/// Stable 64-bit FNV-1a cache key over the source identity and the format version.
pub fn generate_cache_key(abs_path: &str, src_size: u64, src_mtime_ns: u64) -> String {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut h = OFFSET;
    let mut feed = |bytes: &[u8]| {
        for &b in bytes {
            h ^= b as u64;
            h = h.wrapping_mul(PRIME);
        }
    };
    feed(abs_path.as_bytes());
    feed(&[0]);
    feed(&src_size.to_le_bytes());
    feed(&src_mtime_ns.to_le_bytes());
    feed(&VERSION.to_le_bytes());
    format!("{:016x}", h)
}

/// Delete leftover `*.tmp` files older than an hour (from crashed or killed writers).
pub fn cleanup_stale_temp_files(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    let cutoff = SystemTime::now() - Duration::from_secs(3600);
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("tmp") {
            continue;
        }
        let old = entry
            .metadata()
            .and_then(|m| m.modified())
            .map(|t| t < cutoff)
            .unwrap_or(false);
        if old {
            if let Err(e) = fs::remove_file(&path) {
                tracing::warn!(
                    "Failed to remove stale peak temp file {}: {}",
                    path.display(),
                    e
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::io::peaks::PeakBuilder;

    #[test]
    fn cache_key_is_stable_and_sensitive() {
        let k1 = generate_cache_key("/a.wav", 10, 20);
        assert_eq!(k1, generate_cache_key("/a.wav", 10, 20));
        assert_ne!(k1, generate_cache_key("/a.wav", 11, 20));
        assert_ne!(k1, generate_cache_key("/a.wav", 10, 21));
        assert_ne!(k1, generate_cache_key("/b.wav", 10, 20));
        assert_eq!(k1.len(), 16);
    }

    #[test]
    fn round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.swp");
        let frames = 64 * 5000 + 7;
        let left: Vec<f32> = (0..frames)
            .map(|i| if i == 64 * 4500 + 3 { 0.75 } else { 0.0 })
            .collect();
        let right = vec![-0.25f32; frames];
        let mut b = PeakBuilder::new(2, 44100);
        b.push(&[left, right]);
        let peaks = b.finish();
        PeakFile::write(&path, &peaks, 1234, 5678).unwrap();

        let h = PeakFile::read_header(&path).unwrap();
        assert!(h.complete);
        assert_eq!(h.version, VERSION);
        assert_eq!(h.channels, 2);
        assert_eq!(h.source_sample_rate, 44100);
        assert_eq!(h.frames, frames as u64);
        assert_eq!(h.base_block, 64);
        assert_eq!(h.tex_width as u32, TEX_WIDTH);
        assert_eq!(h.levels.len(), peaks.levels.len());
        assert_eq!(
            h.levels[0],
            LevelEntry {
                num_blocks: 5001,
                row_offset: 0,
                rows: 2
            }
        );
        assert_eq!(
            h.levels[1],
            LevelEntry {
                num_blocks: 2501,
                row_offset: 2,
                rows: 1
            }
        );
        assert_eq!(h.levels[2].row_offset, 3);

        // Block 4500 of level 0 is on the second row.
        let t = PeakFile::read_texel(&path, &h, 0, 0, 0, 4500).unwrap();
        assert_eq!(t[0], 0.0);
        assert_eq!(t[1], 0.75);
        let t = PeakFile::read_texel(&path, &h, 1, 0, 1, 10).unwrap();
        assert_eq!(t[0], -0.25);
        assert_eq!(t[1], -0.25);
        assert!((t[2] - 0.25).abs() < 1e-3);
        let top = h.levels.len() - 1;
        let t = PeakFile::read_texel(&path, &h, 0, 0, top, 0).unwrap();
        assert_eq!(t[1], 0.75);

        assert!(PeakFile::is_valid(&path, 1234, 5678));
        assert!(!PeakFile::is_valid(&path, 1234, 5679));
    }

    #[test]
    fn incomplete_file_is_invalid() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.swp");
        let mut b = PeakBuilder::new(1, 48000);
        b.push(&[vec![0.1; 1000]]);
        PeakFile::write(&path, &b.finish(), 1, 2).unwrap();
        let mut bytes = fs::read(&path).unwrap();
        bytes[COMPLETE_OFFSET as usize] = 0;
        fs::write(&path, &bytes).unwrap();
        assert!(!PeakFile::is_valid(&path, 1, 2));
    }
}
