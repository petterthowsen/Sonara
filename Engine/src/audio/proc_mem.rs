//! Process memory figures from `/proc`, for the per-device RAM readout and the Engine panel.
//!
//! Read only on the command thread (never the audio callback). PSS (proportional set size)
//! splits shared pages between the processes sharing them, so the engine's PSS plus each
//! `plugin_host`'s adds up to what the session really uses. When the kernel has no
//! `smaps_rollup` (or the process is not ours to read) RSS from `statm` is the fallback.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// Bytes of resident memory shared out proportionally (PSS) from `smaps_rollup` text. `None` when
/// the text has no `Pss:` line.
pub fn parse_smaps_rollup_pss(text: &str) -> Option<u64> {
    text.lines().find_map(|line| {
        let rest = line.strip_prefix("Pss:")?;
        let kib: u64 = rest.trim().strip_suffix("kB")?.trim().parse().ok()?;
        Some(kib * 1024)
    })
}

/// Bytes of resident memory (RSS) from `statm` text: its second field counts pages.
pub fn parse_statm_rss(text: &str, page_size: u64) -> Option<u64> {
    let pages: u64 = text.split_whitespace().nth(1)?.parse().ok()?;
    Some(pages * page_size)
}

fn page_size() -> u64 {
    // Safety: sysconf has no preconditions.
    let size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if size > 0 {
        size as u64
    } else {
        4096
    }
}

/// PSS of process `pid` in bytes (RSS if PSS isn't readable). `None` once the process is gone.
pub fn read_process_memory(pid: u32) -> Option<u64> {
    if let Ok(text) = std::fs::read_to_string(format!("/proc/{pid}/smaps_rollup")) {
        if let Some(bytes) = parse_smaps_rollup_pss(&text) {
            return Some(bytes);
        }
    }
    let text = std::fs::read_to_string(format!("/proc/{pid}/statm")).ok()?;
    parse_statm_rss(&text, page_size())
}

/// Memory of this process in bytes.
pub fn read_own_memory() -> Option<u64> {
    read_process_memory(std::process::id())
}

/// How often `/proc` is read; `MemorySampler::refresh` returns the cached figures in between.
pub const MEMORY_REFRESH_INTERVAL: Duration = Duration::from_secs(1);

/// Cached memory of the engine and its plugin host processes, refreshed at most once a second.
#[derive(Default)]
pub struct MemorySampler {
    last: Option<Instant>,
    engine_bytes: u64,
    hosts: HashMap<u32, u64>,
}

impl MemorySampler {
    /// Re-read the engine and the given host pids if the cache is older than the refresh interval.
    /// Pids not listed are forgotten, and so are those that have exited.
    pub fn refresh(&mut self, now: Instant, host_pids: impl IntoIterator<Item = u32>) {
        let pids: Vec<u32> = host_pids.into_iter().collect();
        let due = self
            .last
            .map_or(true, |t| now.duration_since(t) >= MEMORY_REFRESH_INTERVAL);
        // A host that loaded since the last read has no figure yet: read it at once.
        let missing = pids
            .iter()
            .any(|pid| *pid != 0 && !self.hosts.contains_key(pid));
        if !due && !missing {
            return;
        }
        if due {
            self.last = Some(now);
            self.engine_bytes = read_own_memory().unwrap_or(0);
        }
        let old = std::mem::take(&mut self.hosts);
        for pid in pids {
            if pid == 0 {
                continue;
            }
            let cached = if due { None } else { old.get(&pid).copied() };
            if let Some(bytes) = cached.or_else(|| read_process_memory(pid)) {
                self.hosts.insert(pid, bytes);
            }
        }
    }

    pub fn engine_bytes(&self) -> u64 {
        self.engine_bytes
    }

    /// Memory of host `pid`, if it was read.
    pub fn host_bytes(&self, pid: u32) -> Option<u64> {
        self.hosts.get(&pid).copied()
    }

    /// Sum over the hosts read.
    pub fn plugin_bytes(&self) -> u64 {
        self.hosts.values().sum()
    }

    pub fn host_count(&self) -> usize {
        self.hosts.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROLLUP: &str = "55d0c0a00000-7ffd5c3ff000 ---p 00000000 00:00 0   [rollup]\n\
Rss:               20480 kB\n\
Pss:               12345 kB\n\
Pss_Anon:           8000 kB\n\
Shared_Clean:       4096 kB\n";

    #[test]
    fn pss_is_read_in_bytes() {
        assert_eq!(parse_smaps_rollup_pss(ROLLUP), Some(12345 * 1024));
    }

    #[test]
    fn pss_ignores_the_pss_anon_lines_and_garbage() {
        assert_eq!(parse_smaps_rollup_pss("Pss_Anon: 5 kB\n"), None);
        assert_eq!(parse_smaps_rollup_pss("Pss: lots kB\n"), None);
        assert_eq!(parse_smaps_rollup_pss(""), None);
    }

    #[test]
    fn statm_rss_is_the_second_field_in_pages() {
        assert_eq!(
            parse_statm_rss("5000 300 120 10 0 200 0\n", 4096),
            Some(300 * 4096)
        );
        assert_eq!(parse_statm_rss("5000", 4096), None);
        assert_eq!(parse_statm_rss("5000 x", 4096), None);
    }

    #[test]
    fn own_memory_is_readable_and_a_dead_pid_is_not() {
        assert!(read_own_memory().unwrap() > 0);
        assert_eq!(read_process_memory(u32::MAX - 1), None);
    }

    #[test]
    fn sampler_sums_hosts_and_forgets_unlisted_ones() {
        let mut sampler = MemorySampler::default();
        let me = std::process::id();
        let now = Instant::now();
        sampler.refresh(now, [me, u32::MAX - 1]);
        assert!(sampler.engine_bytes() > 0);
        assert_eq!(sampler.host_count(), 1, "the dead pid has no figure");
        assert_eq!(sampler.plugin_bytes(), sampler.host_bytes(me).unwrap());
        sampler.refresh(now + Duration::from_secs(2), []);
        assert_eq!(sampler.host_count(), 0);
        assert_eq!(sampler.plugin_bytes(), 0);
    }
}
