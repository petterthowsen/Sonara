//! Rotating the engine's log files into timestamped session files.

use anyhow::Result;
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use std::sync::{Arc, Mutex};
use tracing::info;

use super::LogWriters;

/// Session log files kept per type (info, warn, combined); older ones are deleted.
const MAX_SESSIONS: usize = 5;

/// Rotate all log files to timestamped session files and enforce retention
pub fn rotate_log_files(log_writers: &LogWriters) -> Result<()> {
    use chrono::Local;

    // Generate timestamp for the archived log files
    let timestamp = Local::now().format("%Y%m%d_%H%M%S");

    /// Rotate one writer from `last_*.log` to its archived session file.
    fn rotate_one(
        current_path: &str,
        archived_path: &str,
        writer: &Arc<Mutex<File>>,
    ) -> Result<()> {
        // Announce rotation before swapping handles so message goes to old file
        info!("Rotating log file to {}", archived_path);

        if let Ok(mut w) = writer.lock() {
            let _ = w.flush();
            *w = File::create(format!("{}.tmp", current_path))?;
        }

        if Path::new(current_path).exists() {
            fs::rename(current_path, archived_path)?;
        }

        // Remove temp and recreate the current file
        let tmp_path = format!("{}.tmp", current_path);
        if Path::new(&tmp_path).exists() {
            fs::remove_file(&tmp_path)?;
        }

        let new_file = File::create(current_path)?;
        if let Ok(mut w) = writer.lock() {
            *w = new_file;
        }

        Ok(())
    }

    // Compose archived names
    let info_archived = format!("logs/session_{}_info.log", timestamp);
    let warn_archived = format!("logs/session_{}_warn.log", timestamp);
    let combined_archived = format!("logs/session_{}_combined.log", timestamp);

    // Rotate each log
    rotate_one("logs/last_info.log", &info_archived, &log_writers.info)?;
    rotate_one("logs/last_warn.log", &warn_archived, &log_writers.warn)?;
    rotate_one(
        "logs/last_combined.log",
        &combined_archived,
        &log_writers.combined,
    )?;

    enforce_retention("session_", "_info.log")?;
    enforce_retention("session_", "_warn.log")?;
    enforce_retention("session_", "_combined.log")?;

    info!("Log rotation complete - new session started");

    Ok(())
}

/// Delete the oldest `logs/<prefix>*<suffix>` files, keeping the newest `MAX_SESSIONS`. Filenames
/// carry a timestamp, so sorting by name sorts by age.
fn enforce_retention(prefix: &str, suffix: &str) -> Result<()> {
    let mut files: Vec<_> = fs::read_dir("logs")?
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .map(|e| e.path())
        .filter(|p| {
            if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                name.starts_with(prefix) && name.ends_with(suffix)
            } else {
                false
            }
        })
        .collect();

    files.sort(); // timestamp is in filename, ascending
    let excess = files.len().saturating_sub(MAX_SESSIONS);
    if excess > 0 {
        for p in files.into_iter().take(excess) {
            let _ = fs::remove_file(p);
        }
    }
    Ok(())
}
