use anyhow::{anyhow, Result};
use byteorder::{LittleEndian, ReadBytesExt, WriteBytesExt};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// Waveform cache file magic number
const MAGIC: &[u8; 8] = b"SONAWRM1";
const VERSION: u16 = 1;

/// Header for the waveform cache file
#[derive(Debug, Clone)]
pub struct CacheHeader {
    pub version: u16,
    pub channels: u16,
    pub sample_rate: u32,
    pub frames: u64,
    pub levels: u16,
    pub dir_offset: u64,
}

/// Directory entry for each level
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LevelMetadata {
    pub level: u16,
    pub block_size: u32,
    pub num_blocks: u64,
    pub channel_offsets: Vec<u64>, // Offset for each channel's data in the file
}

/// Waveform cache writer for progressive writing
pub struct WaveformCacheWriter {
    file: File,
    header: CacheHeader,
    pub(crate) level_metadata: Vec<LevelMetadata>,
    current_offset: u64,
}

/// Fixed metadata directory size: supports up to 16 levels
/// Each level needs: 2 + 4 + 8 + 8 + (2 channels * 8) = 38 bytes minimum
/// With 16 levels: 16 * 64 = 1024 bytes (allocate generously)
const METADATA_DIRECTORY_SIZE: u64 = 1024;
const METADATA_DIRECTORY_OFFSET: u64 = 34; // Right after 34-byte header

impl WaveformCacheWriter {
    /// Create a new cache writer
    pub fn create<P: AsRef<Path>>(
        path: P,
        channels: u16,
        sample_rate: u32,
        frames: u64,
        levels: u16,
    ) -> Result<Self> {
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)?;

        let header = CacheHeader {
            version: VERSION,
            channels,
            sample_rate,
            frames,
            levels,
            dir_offset: METADATA_DIRECTORY_OFFSET, // Known upfront
        };

        let mut writer = Self {
            file,
            header,
            level_metadata: Vec::with_capacity(levels as usize),
            current_offset: 0,
        };

        // Write header and reserve space for metadata directory
        writer.write_header_and_reserve_metadata()?;

        Ok(writer)
    }

    /// Write header and reserve space for metadata directory
    fn write_header_and_reserve_metadata(&mut self) -> Result<()> {
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(MAGIC)?;                                              // 8 bytes
        self.file.write_u16::<LittleEndian>(self.header.version)?;               // 2 bytes
        self.file.write_u16::<LittleEndian>(self.header.channels)?;              // 2 bytes
        self.file.write_u32::<LittleEndian>(self.header.sample_rate)?;           // 4 bytes
        self.file.write_u64::<LittleEndian>(self.header.frames)?;                // 8 bytes
        self.file.write_u16::<LittleEndian>(self.header.levels)?;                // 2 bytes
        self.file.write_u64::<LittleEndian>(self.header.dir_offset)?;            // 8 bytes
        // Total: 8+2+2+4+8+2+8 = 34 bytes

        // Reserve space for metadata directory (1024 bytes after header)
        self.file.seek(SeekFrom::Start(METADATA_DIRECTORY_OFFSET))?;
        let zeros = vec![0u8; METADATA_DIRECTORY_SIZE as usize];
        self.file.write_all(&zeros)?;

        // Waveform data starts after the reserved metadata space
        self.current_offset = METADATA_DIRECTORY_OFFSET + METADATA_DIRECTORY_SIZE;
        Ok(())
    }

    /// Write header to file (for updates only)
    fn write_header(&mut self) -> Result<()> {
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(MAGIC)?;                                              // 8 bytes
        self.file.write_u16::<LittleEndian>(self.header.version)?;               // 2 bytes
        self.file.write_u16::<LittleEndian>(self.header.channels)?;              // 2 bytes
        self.file.write_u32::<LittleEndian>(self.header.sample_rate)?;           // 4 bytes
        self.file.write_u64::<LittleEndian>(self.header.frames)?;                // 8 bytes
        self.file.write_u16::<LittleEndian>(self.header.levels)?;                // 2 bytes
        self.file.write_u64::<LittleEndian>(self.header.dir_offset)?;            // 8 bytes
        Ok(())
    }

    /// Pre-calculate and write metadata directory with predicted offsets
    /// Call this before writing any level data to enable progressive reading
    pub fn write_metadata_directory(
        &mut self,
        level_specs: &[(u16, u32, u64)], // [(level, block_size, num_blocks), ...]
    ) -> Result<()> {
        // Calculate predicted offsets for each level
        let mut predicted_offset = METADATA_DIRECTORY_OFFSET + METADATA_DIRECTORY_SIZE;

        self.level_metadata.clear();
        self.level_metadata.reserve(level_specs.len());

        for &(level, block_size, num_blocks) in level_specs {
            let mut channel_offsets = Vec::with_capacity(self.header.channels as usize);

            // Predict offsets for each channel
            for _ch in 0..self.header.channels {
                channel_offsets.push(predicted_offset);
                // Each channel: num_blocks * 3 values * 4 bytes per f32
                predicted_offset += num_blocks * 3 * 4;
            }

            self.level_metadata.push(LevelMetadata {
                level,
                block_size,
                num_blocks,
                channel_offsets,
            });
        }

        // Write metadata directory
        self.file.seek(SeekFrom::Start(METADATA_DIRECTORY_OFFSET))?;
        let mut metadata_pos = METADATA_DIRECTORY_OFFSET;

        for metadata in &self.level_metadata {
            self.file.write_u16::<LittleEndian>(metadata.level)?;
            self.file.write_u32::<LittleEndian>(metadata.block_size)?;
            self.file.write_u64::<LittleEndian>(metadata.num_blocks)?;
            self.file.write_u64::<LittleEndian>(metadata.channel_offsets.len() as u64)?;

            for &offset in &metadata.channel_offsets {
                self.file.write_u64::<LittleEndian>(offset)?;
            }

            metadata_pos += 2 + 4 + 8 + 8 + (metadata.channel_offsets.len() as u64 * 8);

            if metadata_pos > METADATA_DIRECTORY_OFFSET + METADATA_DIRECTORY_SIZE {
                return Err(anyhow!(
                    "Metadata directory exceeded reserved space ({} > {})",
                    metadata_pos,
                    METADATA_DIRECTORY_OFFSET + METADATA_DIRECTORY_SIZE
                ));
            }
        }

        // Flush to ensure metadata is on disk before data writes
        self.file.flush()?;

        // Position file pointer at start of data region
        self.current_offset = METADATA_DIRECTORY_OFFSET + METADATA_DIRECTORY_SIZE;
        self.file.seek(SeekFrom::Start(self.current_offset))?;

        Ok(())
    }

    /// Add a level with its metadata and data
    pub fn add_level(
        &mut self,
        level: u16,
        block_size: u32,
        channel_data: &[Vec<f32>], // [channel][min, max, rms, min, max, rms, ...]
    ) -> Result<LevelMetadata> {
        let num_blocks = channel_data[0].len() as u64 / 3; // 3 values per block (min, max, rms)
        let mut channel_offsets = Vec::with_capacity(self.header.channels as usize);

        // Write data for each channel
        for ch_data in channel_data {
            channel_offsets.push(self.current_offset);
            // Write as little-endian f32
            for &sample in ch_data {
                self.file.write_f32::<LittleEndian>(sample)?;
                self.current_offset += 4;
            }
        }

        let metadata = LevelMetadata {
            level,
            block_size,
            num_blocks,
            channel_offsets,
        };

        self.level_metadata.push(metadata.clone());
        Ok(metadata)
    }

    /// Write only the data for a level (metadata must already be written via write_metadata_directory)
    pub fn write_level_data(
        &mut self,
        level_idx: usize,
        channel_data: &[Vec<f32>], // [channel][min, max, rms, min, max, rms, ...]
    ) -> Result<()> {
        if level_idx >= self.level_metadata.len() {
            return Err(anyhow!("Invalid level index: {}", level_idx));
        }

        let metadata = &self.level_metadata[level_idx];
        let expected_num_blocks = metadata.num_blocks;
        let actual_num_blocks = channel_data[0].len() as u64 / 3;

        if actual_num_blocks != expected_num_blocks {
            return Err(anyhow!(
                "Level {} block count mismatch: expected {}, got {}",
                level_idx,
                expected_num_blocks,
                actual_num_blocks
            ));
        }

        // Verify we're at the expected offset for first channel
        let expected_offset = metadata.channel_offsets[0];
        if self.current_offset != expected_offset {
            return Err(anyhow!(
                "Level {} offset mismatch: expected {}, at {}",
                level_idx,
                expected_offset,
                self.current_offset
            ));
        }

        // Write data for each channel
        for ch_data in channel_data {
            for &sample in ch_data {
                self.file.write_f32::<LittleEndian>(sample)?;
                self.current_offset += 4;
            }
        }

        // Flush after each level for progressive availability
        self.file.flush()?;

        Ok(())
    }

    /// Finalize the cache by writing the metadata directory
    pub fn finalize(&mut self) -> Result<()> {
        // Metadata directory is at fixed METADATA_DIRECTORY_OFFSET (known upfront)
        // dir_offset was already set in header during create()
        self.file.seek(SeekFrom::Start(METADATA_DIRECTORY_OFFSET))?;

        // Write directory entries in simple binary format (NOT bincode)
        // so that Godot can read it without a bincode library
        let mut metadata_pos = METADATA_DIRECTORY_OFFSET;
        for metadata in &self.level_metadata {
            self.file.write_u16::<LittleEndian>(metadata.level)?;
            self.file.write_u32::<LittleEndian>(metadata.block_size)?;
            self.file.write_u64::<LittleEndian>(metadata.num_blocks)?;
            // Write number of channel offsets
            self.file.write_u64::<LittleEndian>(metadata.channel_offsets.len() as u64)?;
            // Write each channel offset
            for &offset in &metadata.channel_offsets {
                self.file.write_u64::<LittleEndian>(offset)?;
            }
            metadata_pos += 2 + 4 + 8 + 8 + (metadata.channel_offsets.len() as u64 * 8);

            // Safety check: don't overflow reserved metadata space
            if metadata_pos > METADATA_DIRECTORY_OFFSET + METADATA_DIRECTORY_SIZE {
                return Err(anyhow!(
                    "Metadata directory exceeded reserved space ({} > {})",
                    metadata_pos,
                    METADATA_DIRECTORY_OFFSET + METADATA_DIRECTORY_SIZE
                ));
            }
        }

        self.file.flush()?;
        Ok(())
    }
}

/// Waveform cache reader
pub struct WaveformCacheReader {
    file: File,
    header: CacheHeader,
    level_metadata: Vec<LevelMetadata>,
}

impl WaveformCacheReader {
    /// Open an existing cache file
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        let mut file = File::open(path)?;
        let header = Self::read_header(&mut file)?;

        // Read directory
        file.seek(SeekFrom::Start(header.dir_offset))?;
        let mut level_metadata = Vec::with_capacity(header.levels as usize);

        for _ in 0..header.levels {
            let metadata = Self::read_level_metadata(&mut file)?;
            level_metadata.push(metadata);
        }

        Ok(Self {
            file,
            header,
            level_metadata,
        })
    }

    /// Read header from file
    fn read_header(file: &mut File) -> Result<CacheHeader> {
        let mut magic = [0u8; 8];
        file.read_exact(&mut magic)?;
        if magic != *MAGIC {
            return Err(anyhow!("Invalid cache file magic"));
        }

        let version = file.read_u16::<LittleEndian>()?;
        if version != VERSION {
            return Err(anyhow!("Unsupported cache version: {}", version));
        }

        let channels = file.read_u16::<LittleEndian>()?;
        let sample_rate = file.read_u32::<LittleEndian>()?;
        let frames = file.read_u64::<LittleEndian>()?;
        let levels = file.read_u16::<LittleEndian>()?;
        let dir_offset = file.read_u64::<LittleEndian>()?;

        Ok(CacheHeader {
            version,
            channels,
            sample_rate,
            frames,
            levels,
            dir_offset,
        })
    }

    /// Read level metadata from file (plain binary format, matching writer)
    fn read_level_metadata(file: &mut File) -> Result<LevelMetadata> {
        let level = file.read_u16::<LittleEndian>()?;
        let block_size = file.read_u32::<LittleEndian>()?;
        let num_blocks = file.read_u64::<LittleEndian>()?;
        let vec_len = file.read_u64::<LittleEndian>()?;

        if vec_len < 0 || vec_len > 100 {
            return Err(anyhow!("Invalid channel offset count: {}", vec_len));
        }

        let mut channel_offsets = Vec::with_capacity(vec_len as usize);
        for _ in 0..vec_len {
            channel_offsets.push(file.read_u64::<LittleEndian>()?);
        }

        Ok(LevelMetadata {
            level,
            block_size,
            num_blocks,
            channel_offsets,
        })
    }

    /// Get header information
    pub fn header(&self) -> &CacheHeader {
        &self.header
    }

    /// Get level metadata
    pub fn level_metadata(&self) -> &[LevelMetadata] {
        &self.level_metadata
    }

    /// Read waveform data for a specific level and channel
    pub fn read_level_channel(&mut self, level: u16, channel: usize) -> Result<Vec<f32>> {
        let metadata = self
            .level_metadata
            .get(level as usize)
            .ok_or_else(|| anyhow!("Level {} not found", level))?;

        if channel >= self.header.channels as usize {
            return Err(anyhow!("Channel {} out of range", channel));
        }

        let offset = metadata.channel_offsets[channel];
        let data_size = (metadata.num_blocks * 3 * 4) as usize; // 3 f32 per block
        let mut data = vec![0u8; data_size];

        self.file.seek(SeekFrom::Start(offset))?;
        self.file.read_exact(&mut data)?;

        // Convert bytes to f32
        let mut result = Vec::with_capacity(data_size / 4);
        let mut reader = std::io::Cursor::new(data);
        while reader.position() < data_size as u64 {
            result.push(reader.read_f32::<LittleEndian>()?);
        }

        Ok(result)
    }
}

/// Get the cache directory path
pub fn get_cache_dir() -> Result<PathBuf> {
    if let Ok(cache_dir) = std::env::var("XDG_CACHE_HOME") {
        Ok(PathBuf::from(cache_dir).join("sonara").join("waveforms"))
    } else if let Some(home) = dirs::home_dir() {
        Ok(home.join(".cache").join("sonara").join("waveforms"))
    } else {
        Err(anyhow!("Could not determine cache directory"))
    }
}

/// Generate cache key from file metadata
pub fn generate_cache_key(
    abs_path: &str,
    size: u64,
    mtime: u64,
    project_sr: u32,
    decoder_version: &str,
) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    let mut hasher = DefaultHasher::new();
    abs_path.hash(&mut hasher);
    size.hash(&mut hasher);
    mtime.hash(&mut hasher);
    project_sr.hash(&mut hasher);
    decoder_version.hash(&mut hasher);

    format!("{:x}.swf", hasher.finish())
}

/// Check if cache is valid for a file
pub fn is_cache_valid<P: AsRef<Path>>(
    cache_path: P,
    abs_path: &str,
    size: u64,
    mtime: u64,
    project_sr: u32,
    decoder_version: &str,
) -> bool {
    let expected_key = generate_cache_key(abs_path, size, mtime, project_sr, decoder_version);
    let cache_filename = cache_path
        .as_ref()
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("");

    expected_key == cache_filename
}
