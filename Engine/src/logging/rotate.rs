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
        current_path: &Path,
        archived_path: &Path,
        writer: &Arc<Mutex<File>>,
    ) -> Result<()> {
        let tmp_path = current_path.with_extension("log.tmp");

        // Announce rotation before swapping handles so message goes to old file
        info!("Rotating log file to {}", archived_path.display());

        if let Ok(mut w) = writer.lock() {
            let _ = w.flush();
            *w = File::create(&tmp_path)?;
        }

        if current_path.exists() {
            fs::rename(current_path, archived_path)?;
        }

        // Remove temp and recreate the current file
        if tmp_path.exists() {
            fs::remove_file(&tmp_path)?;
        }

        let new_file = File::create(current_path)?;
        if let Ok(mut w) = writer.lock() {
            *w = new_file;
        }

        Ok(())
    }

    // Compose archived names
    let dir = &log_writers.dir;
    let info_archived = dir.join(format!("session_{}_info.log", timestamp));
    let warn_archived = dir.join(format!("session_{}_warn.log", timestamp));
    let combined_archived = dir.join(format!("session_{}_combined.log", timestamp));

    // Rotate each log
    rotate_one(
        &dir.join("last_info.log"),
        &info_archived,
        &log_writers.info,
    )?;
    rotate_one(
        &dir.join("last_warn.log"),
        &warn_archived,
        &log_writers.warn,
    )?;
    rotate_one(
        &dir.join("last_combined.log"),
        &combined_archived,
        &log_writers.combined,
    )?;

    enforce_retention(dir, "session_", "_info.log")?;
    enforce_retention(dir, "session_", "_warn.log")?;
    enforce_retention(dir, "session_", "_combined.log")?;

    info!("Log rotation complete - new session started");

    Ok(())
}

/// Delete the oldest `<dir>/<prefix>*<suffix>` files, keeping the newest `MAX_SESSIONS`.
/// Filenames carry a timestamp, so sorting by name sorts by age.
fn enforce_retention(dir: &Path, prefix: &str, suffix: &str) -> Result<()> {
    let mut files: Vec<_> = fs::read_dir(dir)?
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

#[cfg(test)]
mod tests {
    use super::*;

    fn writers(dir: &Path) -> LogWriters {
        let open = |n: &str| Arc::new(Mutex::new(File::create(dir.join(n)).unwrap()));
        LogWriters {
            dir: dir.to_path_buf(),
            info: open("last_info.log"),
            warn: open("last_warn.log"),
            combined: open("last_combined.log"),
        }
    }

    #[test]
    fn rotation_archives_into_the_given_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let w = writers(tmp.path());
        rotate_log_files(&w).unwrap();
        let names: Vec<String> = fs::read_dir(tmp.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        for kind in ["info", "warn", "combined"] {
            assert!(names.contains(&format!("last_{kind}.log")), "{names:?}");
            assert!(
                names
                    .iter()
                    .any(|n| n.starts_with("session_") && n.ends_with(&format!("_{kind}.log"))),
                "{names:?}"
            );
        }
        assert!(
            !names.iter().any(|n| n.ends_with(".tmp")),
            "temp file left behind: {names:?}"
        );
    }

    #[test]
    fn retention_keeps_the_newest_sessions_in_the_dir() {
        let tmp = tempfile::tempdir().unwrap();
        for i in 0..8 {
            fs::write(
                tmp.path()
                    .join(format!("session_2024010{i}_000000_info.log")),
                "",
            )
            .unwrap();
        }
        fs::write(tmp.path().join("last_info.log"), "").unwrap();
        enforce_retention(tmp.path(), "session_", "_info.log").unwrap();
        let mut left: Vec<String> = fs::read_dir(tmp.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with("session_"))
            .collect();
        left.sort();
        assert_eq!(left.len(), MAX_SESSIONS);
        assert!(left[0].starts_with("session_20240103"));
        assert!(tmp.path().join("last_info.log").exists());
    }
}
