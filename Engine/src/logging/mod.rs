//! Engine logging: split log files, rotation per project, and forwarding WARN/ERROR to Godot.

pub mod forwarder;
pub mod rotate;

use anyhow::Result;
use crossbeam::channel::Sender;
use std::fs::{self, File};
use std::io::{self, Write};
use std::sync::{Arc, Mutex};
use tracing::Level;
use tracing_subscriber::filter::{self, LevelFilter};
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::Layer;

use crate::audio::EngineStatus;
use forwarder::LogForwarder;

pub use rotate::rotate_log_files;

/// Wrapper that makes a shared `Arc<Mutex<File>>` usable as a tracing writer, so the file can be
/// swapped underneath it when logs rotate.
struct RotatableWriter {
    file: Arc<Mutex<File>>,
}

impl RotatableWriter {
    /// Wrap `file` in a shared handle.
    fn new(file: File) -> Self {
        Self {
            file: Arc::new(Mutex::new(file)),
        }
    }

    /// The shared file handle, for rotation.
    fn get_handle(&self) -> Arc<Mutex<File>> {
        self.file.clone()
    }
}

impl Write for RotatableWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.file.lock().unwrap().write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.lock().unwrap().flush()
    }
}

impl Clone for RotatableWriter {
    fn clone(&self) -> Self {
        Self {
            file: self.file.clone(),
        }
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for RotatableWriter {
    type Writer = Self;

    fn make_writer(&'a self) -> Self::Writer {
        self.clone()
    }
}

/// Shared file handles for rotating log writers (info, warn, combined)
pub struct LogWriters {
    pub info: Arc<Mutex<File>>,
    pub warn: Arc<Mutex<File>>,
    pub combined: Arc<Mutex<File>>,
}

/// Create `logs/last_{info,warn,combined}.log` and install the global tracing subscriber: one
/// layer per file plus a [`LogForwarder`] that sends WARN and ERROR to Godot through
/// `status_tx`. Returns the file handles so `/project/init` can rotate them.
pub fn init(status_tx: &Sender<EngineStatus>) -> Result<LogWriters> {
    fs::create_dir_all("logs")?;

    let info_writer = RotatableWriter::new(File::create("logs/last_info.log")?);
    let warn_writer = RotatableWriter::new(File::create("logs/last_warn.log")?);
    let combined_writer = RotatableWriter::new(File::create("logs/last_combined.log")?);

    let log_writers = LogWriters {
        info: info_writer.get_handle(),
        warn: warn_writer.get_handle(),
        combined: combined_writer.get_handle(),
    };

    // info-only layer (exactly INFO)
    let info_layer = tracing_subscriber::fmt::layer()
        .with_writer(info_writer)
        .with_ansi(false)
        .with_filter(filter::filter_fn(|meta| meta.level() == &Level::INFO));

    // warn+ layer (WARN and ERROR)
    let warn_layer = tracing_subscriber::fmt::layer()
        .with_writer(warn_writer)
        .with_ansi(false)
        .with_filter(LevelFilter::WARN);

    // combined: INFO and above
    let combined_layer = tracing_subscriber::fmt::layer()
        .with_writer(combined_writer)
        .with_ansi(false)
        .with_filter(LevelFilter::INFO);

    tracing_subscriber::registry()
        .with(info_layer)
        .with(warn_layer)
        .with(combined_layer)
        .with(LogForwarder::new(status_tx.clone()))
        .init();

    Ok(log_writers)
}
