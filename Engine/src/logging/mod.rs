//! Engine logging: split log files, rotation per project, and forwarding WARN/ERROR to Godot.

pub mod forwarder;
pub mod rotate;

use anyhow::Result;
use crossbeam::channel::Sender;
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
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
    /// The directory holding the log files; rotation archives into it.
    pub dir: PathBuf,
    pub info: Arc<Mutex<File>>,
    pub warn: Arc<Mutex<File>>,
    pub combined: Arc<Mutex<File>>,
}

/// Env var carrying the engine's log directory to child processes (plugin hosts).
pub const LOG_DIR_ENV: &str = "SONARA_LOG_DIR";

/// The engine's default log directory: `$XDG_STATE_HOME/sonara/logs/engine`, with
/// `~/.local/state` when `XDG_STATE_HOME` is unset (or not absolute, as the XDG spec says).
/// Keep in step with `AppPaths.engine_log_dir()` in Godot.
pub fn default_log_dir() -> PathBuf {
    default_log_dir_from(
        std::env::var("XDG_STATE_HOME").ok().as_deref(),
        std::env::var("HOME").ok().as_deref(),
    )
}

/// [`default_log_dir`] with the environment passed in, for tests.
fn default_log_dir_from(xdg_state_home: Option<&str>, home: Option<&str>) -> PathBuf {
    let state = match xdg_state_home {
        Some(s) if Path::new(s).is_absolute() => PathBuf::from(s),
        _ => PathBuf::from(home.unwrap_or(".")).join(".local/state"),
    };
    state.join("sonara").join("logs").join("engine")
}

/// Create `<dir>/last_{info,warn,combined}.log` and install the global tracing subscriber: one
/// layer per file plus a [`LogForwarder`] that sends WARN and ERROR to Godot through
/// `status_tx`. Returns the file handles so `/project/init` can rotate them.
pub fn init(status_tx: &Sender<EngineStatus>, dir: &Path) -> Result<LogWriters> {
    fs::create_dir_all(dir)?;

    let info_writer = RotatableWriter::new(File::create(dir.join("last_info.log"))?);
    let warn_writer = RotatableWriter::new(File::create(dir.join("last_warn.log"))?);
    let combined_writer = RotatableWriter::new(File::create(dir.join("last_combined.log"))?);

    let log_writers = LogWriters {
        dir: dir.to_path_buf(),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_dir_follows_xdg_state_home() {
        assert_eq!(
            default_log_dir_from(Some("/state"), Some("/home/u")),
            PathBuf::from("/state/sonara/logs/engine")
        );
    }

    #[test]
    fn default_dir_falls_back_to_home() {
        let want = PathBuf::from("/home/u/.local/state/sonara/logs/engine");
        assert_eq!(default_log_dir_from(None, Some("/home/u")), want);
        // A relative XDG_STATE_HOME is invalid and ignored.
        assert_eq!(default_log_dir_from(Some("rel"), Some("/home/u")), want);
    }
}
