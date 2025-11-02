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
    level_metadata: Vec<LevelMetadata>,
    current_offset: u64,
}

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
            dir_offset: 0, // Will be set later
        };

        let mut writer = Self {
            file,
            header,
            level_metadata: Vec::with_capacity(levels as usize),
            current_offset: 0,
        };

        // Write placeholder header
        writer.write_header()?;

        Ok(writer)
    }

    /// Write header to file
    fn write_header(&mut self) -> Result<()> {
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(MAGIC)?;
        self.file.write_u16::<LittleEndian>(self.header.version)?;
        self.file.write_u16::<LittleEndian>(self.header.channels)?;
        self.file
            .write_u32::<LittleEndian>(self.header.sample_rate)?;
        self.file.write_u64::<LittleEndian>(self.header.frames)?;
        self.file.write_u16::<LittleEndian>(self.header.levels)?;
        self.file
            .write_u64::<LittleEndian>(self.header.dir_offset)?;
        self.current_offset = 40; // Size of header
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

    /// Finalize the cache by writing the directory
    pub fn finalize(&mut self) -> Result<()> {
        // Set directory offset
        self.header.dir_offset = self.current_offset;
        let dir_offset = self.header.dir_offset;
        self.write_header()?;
        self.file.seek(SeekFrom::Start(dir_offset))?;
        self.current_offset = dir_offset;

        // Write directory entries at the end of the data section
        for metadata in &self.level_metadata {
            let serialized = bincode::serialize(metadata)?;
            self.file.write_all(&serialized)?;
            self.current_offset += serialized.len() as u64;
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
            let metadata: LevelMetadata = bincode::deserialize_from(&mut file)?;
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
