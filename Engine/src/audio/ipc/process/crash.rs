//! Why a host process stopped: its exit status, the tail of its stderr, and the watcher thread
//! that reaps it.

use std::io::Read;
use std::os::unix::io::RawFd;
use std::os::unix::process::ExitStatusExt;
use std::path::PathBuf;
use std::process::ChildStderr;
use std::sync::Arc;
use std::thread;
use std::time::Duration;
use tracing::warn;

use super::lock;
use super::process::PluginProcess;
use super::routing::Routing;

/// Lines of the host's stderr kept for a crash report. Enough for a Rust panic message plus
/// its backtrace, which otherwise pushes the message out.
pub(super) const STDERR_TAIL_LINES: usize = 80;

/// Largest stderr chunk read at once, so a line the host never terminates can't grow the buffer.
pub(super) const STDERR_TAIL_BYTES_PER_READ: usize = 4096;

/// How a host process ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostExit {
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
}

impl HostExit {
    /// One-line description for logs and the UI.
    pub fn describe(&self) -> String {
        match (self.signal, self.exit_code) {
            (Some(signal), _) => format!("killed by signal {} ({})", signal, signal_name(signal)),
            (None, Some(code)) => format!("exited with code {}", code),
            (None, None) => "exited with an unknown status".to_string(),
        }
    }
}

/// Name of the signals a crashing plugin usually dies from.
fn signal_name(signal: i32) -> &'static str {
    match signal {
        libc::SIGSEGV => "SIGSEGV",
        libc::SIGABRT => "SIGABRT",
        libc::SIGBUS => "SIGBUS",
        libc::SIGILL => "SIGILL",
        libc::SIGFPE => "SIGFPE",
        libc::SIGKILL => "SIGKILL",
        libc::SIGTERM => "SIGTERM",
        libc::SIGINT => "SIGINT",
        libc::SIGPIPE => "SIGPIPE",
        _ => "unknown signal",
    }
}

/// Why a host process stopped: what the crash status Godot shows is built from this. A crash
/// belongs to the host, not the instance, because every instance in a host goes down with it.
#[derive(Debug, Clone)]
pub struct HostCrash {
    pub host_key: String,
    pub pid: u32,
    /// None when the process went away before it could be reaped (the socket closed first).
    pub exit: Option<HostExit>,
    /// Last lines the host wrote to stderr, oldest first.
    pub stderr_tail: Vec<String>,
    /// The host's own log file, when known (not under a wrapper, whose pid isn't the host's).
    pub log_path: Option<PathBuf>,
    /// The wrapper program the host ran under (`SONARA_PLUGIN_HOST_WRAPPER`), whose exit status
    /// `exit` then is.
    pub wrapper: Option<String>,
}

impl HostCrash {
    /// One-line reason, for the loading state and the log.
    pub fn describe(&self) -> String {
        let reason = match &self.exit {
            Some(exit) => exit.describe(),
            None => "host process went away (control socket closed)".to_string(),
        };
        match &self.wrapper {
            Some(wrapper) => format!(
                "{} {} (the host ran under it; see its output in the engine's terminal)",
                wrapper, reason
            ),
            None => reason,
        }
    }
}

/// `pidfd_open(2)`, or -1 when the syscall isn't available (older kernels, non-Linux).
pub(super) fn open_pidfd(pid: u32) -> RawFd {
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) } as RawFd;
    if fd < 0 {
        -1
    } else {
        fd
    }
}

/// Block until `pidfd` reports the process exited, or a short interval passes. Falls back to
/// sleeping when no pidfd is available.
pub(super) fn wait_for_exit(pidfd: RawFd) {
    if pidfd < 0 {
        thread::sleep(Duration::from_millis(20));
        return;
    }
    let mut fds = [libc::pollfd {
        fd: pidfd,
        events: libc::POLLIN,
        revents: 0,
    }];
    let result = unsafe { libc::poll(fds.as_mut_ptr(), 1, 250) };
    if result < 0 {
        thread::sleep(Duration::from_millis(20));
    }
}

/// Keep the last `text` as one line of the host's stderr tail.
pub(super) fn push_stderr_line(routing: &Routing, text: &str) {
    let text = text.trim_end();
    if text.is_empty() {
        return;
    }
    let mut tail = lock(&routing.stderr_tail);
    if tail.len() >= STDERR_TAIL_LINES {
        tail.pop_front();
    }
    tail.push_back(text.to_string());
}

/// Drain the host's stderr into a bounded tail buffer, so a host that dies can report why.
pub(super) fn drain_stderr(stderr: ChildStderr, routing: Arc<Routing>) {
    let mut reader = stderr;
    let mut buffer = Vec::with_capacity(STDERR_TAIL_BYTES_PER_READ);
    let mut carry = String::new();
    loop {
        buffer.clear();
        let read = reader
            .by_ref()
            .take(STDERR_TAIL_BYTES_PER_READ as u64)
            .read_to_end(&mut buffer)
            .unwrap_or(0);
        if read == 0 {
            break;
        }
        carry.push_str(&String::from_utf8_lossy(&buffer));
        while let Some(newline) = carry.find('\n') {
            let line: String = carry.drain(..=newline).collect();
            push_stderr_line(&routing, &line);
        }
        if carry.len() > STDERR_TAIL_BYTES_PER_READ {
            let excess = carry.len() - STDERR_TAIL_BYTES_PER_READ;
            carry.drain(..excess);
        }
    }
    push_stderr_line(&routing, &carry);
}

impl PluginProcess {
    /// Watch the child process: drain its stderr into a tail buffer and reap it when it exits,
    /// recording the signal or exit code. A watcher per host makes a crash visible immediately
    /// and keeps its stderr for the crash report (Phase 4).
    pub(super) fn start_supervision(&self, stderr: Option<ChildStderr>) {
        let child = Arc::clone(&self.child);
        let pid = self.pid;
        let host_key = self.host_key.clone();

        if let Some(stderr) = stderr {
            let routing = Arc::clone(&self.routing);
            let _ = thread::Builder::new()
                .name(format!("plugin-stderr-{}", pid))
                .spawn(move || drain_stderr(stderr, routing));
        }

        let routing = Arc::clone(&self.routing);
        let _ = thread::Builder::new()
            .name(format!("plugin-watch-{}", pid))
            .spawn(move || {
                let pidfd = open_pidfd(pid);
                loop {
                    {
                        let mut slot = lock(&child);
                        let Some(process) = slot.as_mut() else { break };
                        match process.try_wait() {
                            Ok(Some(status)) => {
                                *lock(&routing.exit) = Some(HostExit {
                                    exit_code: status.code(),
                                    signal: status.signal(),
                                });
                                slot.take();
                                break;
                            }
                            Ok(None) => {}
                            Err(e) => {
                                warn!("Failed to reap plugin host {}: {}", host_key, e);
                                slot.take();
                                break;
                            }
                        }
                    }
                    wait_for_exit(pidfd);
                }
                if pidfd >= 0 {
                    unsafe { libc::close(pidfd) };
                }
            });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::Path;

    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    fn a_crash_under_a_wrapper_names_the_wrapper() {
        let crash = HostCrash {
            host_key: "instance-1".to_string(),
            pid: 7,
            exit: Some(HostExit {
                exit_code: Some(0),
                signal: None,
            }),
            stderr_tail: Vec::new(),
            log_path: None,
            wrapper: Some("gdb".to_string()),
        };
        assert!(crash
            .describe()
            .starts_with("gdb exited with code 0 (the host ran under it"));
    }

    #[test]
    fn host_exit_describes_signal_and_code() {
        assert_eq!(
            HostExit {
                exit_code: None,
                signal: Some(libc::SIGSEGV)
            }
            .describe(),
            "killed by signal 11 (SIGSEGV)"
        );
        assert_eq!(
            HostExit {
                exit_code: Some(7),
                signal: None
            }
            .describe(),
            "exited with code 7"
        );
    }

    /// A real child process, watched by the same code that supervises plugin hosts. Its exit
    /// status and stderr tail must both survive the crash.
    #[test]
    fn watcher_records_exit_code_and_stderr() {
        let process = PluginProcess::spawn_program(
            "test-exit".to_string(),
            Path::new("/bin/sh"),
            &[
                "-c".to_string(),
                "printf 'first line\\nCHILD CRASH REASON\\n' >&2; exit 7".to_string(),
            ],
            false,
        )
        .expect("spawn /bin/sh");

        let deadline = Instant::now() + Duration::from_secs(5);
        while process.is_alive() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        assert!(!process.is_alive(), "child should have exited");

        let crash = process.crash_info().expect("crash info for an exited host");
        assert_eq!(crash.pid, process.pid);
        assert_eq!(
            crash.exit,
            Some(HostExit {
                exit_code: Some(7),
                signal: None
            })
        );
        // The stderr drain thread may need a moment to flush the pipe.
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut tail = crash.stderr_tail.clone();
        while !tail.iter().any(|l| l.contains("CHILD CRASH REASON")) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
            tail = process.crash_info().expect("crash info").stderr_tail;
        }
        assert!(
            tail.iter().any(|line| line.contains("CHILD CRASH REASON")),
            "stderr tail should keep the child's last line, got {:?}",
            tail
        );
    }

    /// The stderr tail is bounded, so a host that prints forever can't grow it.
    #[test]
    fn stderr_tail_keeps_only_the_last_lines() {
        let line_count = STDERR_TAIL_LINES + 25;
        let process = PluginProcess::spawn_program(
            "test-lines".to_string(),
            Path::new("/bin/sh"),
            &[
                "-c".to_string(),
                format!(
                    "for i in $(seq 1 {}); do echo line-$i >&2; done",
                    line_count
                ),
            ],
            false,
        )
        .expect("spawn /bin/sh");

        let deadline = Instant::now() + Duration::from_secs(5);
        while process.is_alive() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut tail = process.crash_info().expect("crash info").stderr_tail;
        while tail.len() < STDERR_TAIL_LINES && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
            tail = process.crash_info().expect("crash info").stderr_tail;
        }
        assert!(tail.len() <= STDERR_TAIL_LINES, "tail must stay bounded");
        assert!(
            tail.last()
                .is_some_and(|line| line.contains(&format!("line-{}", line_count))),
            "tail should end with the last line, got {:?}",
            tail
        );
    }
}
