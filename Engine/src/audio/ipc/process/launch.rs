//! Launching plugin host processes: the wrapper/debugger settings, the host's log files and the
//! `fork`/`exec` of one host with its control socket and doorbell region.

use std::collections::{HashMap, VecDeque};
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32};
use std::sync::{Arc, Mutex};
use std::thread;
use tracing::{info, warn};

use super::process::PluginProcess;
use super::routing::{run_reader, Routing};
use super::{sanitize_name, ProcessManager};
use crate::audio::ipc::shared_memory::HostSharedMemory;

/// The control socket's descriptor number in the host process.
pub(super) const HOST_SOCKET_FD: i32 = 3;

/// The host doorbell region's descriptor number in the host process.
pub(super) const HOST_SHARED_MEMORY_FD: i32 = 4;

/// Env var with a command prefix for spawning hosts, e.g. `gdb -q -batch -ex run -ex bt --args`
/// or `valgrind`. Split like a shell would (quotes allowed, no expansion).
pub const HOST_WRAPPER_ENV: &str = "SONARA_PLUGIN_HOST_WRAPPER";

/// Env var that makes every host wait for a debugger before it reads a command. The host reads
/// it too (the variable is inherited).
pub const HOST_WAIT_ENV: &str = "SONARA_PLUGIN_HOST_WAIT";

/// Plugin host logs kept in the log directory; older ones are deleted at engine start.
pub const PLUGIN_LOGS_KEPT: usize = 50;

/// Where plugin hosts write their logs: `logs/plugins` under the engine's working directory,
/// next to the engine's own logs.
pub fn plugin_log_dir() -> PathBuf {
    std::env::current_dir()
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("logs")
        .join("plugins")
}

/// Delete all but the newest `keep` `.log` files in `dir`. Missing directory is fine.
pub fn prune_plugin_logs(dir: &Path, keep: usize) -> std::io::Result<usize> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
        Err(e) => return Err(e),
    };
    let mut logs: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "log"))
        .filter_map(|path| {
            let modified = std::fs::metadata(&path).ok()?.modified().ok()?;
            Some((modified, path))
        })
        .collect();
    if logs.len() <= keep {
        return Ok(0);
    }
    logs.sort_by(|a, b| b.0.cmp(&a.0));
    let mut removed = 0;
    for (_, path) in logs.drain(keep..) {
        if std::fs::remove_file(&path).is_ok() {
            removed += 1;
        }
    }
    Ok(removed)
}

/// How host processes are launched: normally, or under a debugger or wrapper (Phase 6).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostLaunch {
    /// Command prefix, e.g. `["gdb", "-q", "-batch", "-ex", "run", "-ex", "bt", "--args"]`.
    pub wrapper: Vec<String>,
    /// Hosts wait for a debugger to attach before they start.
    pub wait_for_debugger: bool,
}

impl HostLaunch {
    /// Read `SONARA_PLUGIN_HOST_WRAPPER` and `SONARA_PLUGIN_HOST_WAIT`.
    pub fn from_env() -> Self {
        let wrapper = std::env::var(HOST_WRAPPER_ENV)
            .map(|value| split_command(&value))
            .unwrap_or_default();
        let wait_for_debugger =
            std::env::var(HOST_WAIT_ENV).is_ok_and(|value| !value.is_empty() && value != "0");
        Self {
            wrapper,
            wait_for_debugger,
        }
    }

    /// True when hosts may stop for a debugger or run far slower than normal. Hung-host
    /// detection is off and requests wait `DEBUG_REQUEST_TIMEOUT`, so a host sitting at a
    /// breakpoint isn't killed.
    pub fn is_debugging(&self) -> bool {
        !self.wrapper.is_empty() || self.wait_for_debugger
    }
}

/// Split a command line into words like a shell would: whitespace separates words, single and
/// double quotes group, a backslash escapes the next character. No variable or glob expansion.
pub fn split_command(line: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('"'), '\\') | (None, '\\') => {
                if let Some(next) = chars.next() {
                    word.push(next);
                }
                in_word = true;
            }
            (Some(_), c) => word.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                in_word = true;
            }
            (None, c) if c.is_whitespace() => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            (None, c) => {
                word.push(c);
                in_word = true;
            }
        }
    }
    if in_word {
        words.push(word);
    }
    words
}

/// `dup2` `fd` onto `target` in a freshly forked child, clearing close-on-exec so the descriptor
/// survives `exec`. A no-op when the numbers already match.
pub(super) fn move_fd_to(fd: RawFd, target: RawFd) -> std::io::Result<()> {
    if fd != target {
        if unsafe { libc::dup2(fd, target) } < 0 {
            return Err(std::io::Error::last_os_error());
        }
        unsafe { libc::close(fd) };
    }
    let flags = unsafe { libc::fcntl(target, libc::F_GETFD) };
    if flags >= 0 {
        unsafe { libc::fcntl(target, libc::F_SETFD, flags & !libc::FD_CLOEXEC) };
    }
    Ok(())
}

impl PluginProcess {
    /// Spawn a `plugin_host` process (under `launch`'s wrapper, if any) and start its reader
    /// thread.
    pub(super) fn spawn(host_key: String, launch: &HostLaunch) -> Result<Self, String> {
        let plugin_host_path = ProcessManager::plugin_host_path()?;
        let log_dir = plugin_log_dir();
        let host_args = [
            HOST_SOCKET_FD.to_string(),
            "--host-key".to_string(),
            host_key.clone(),
            "--log-dir".to_string(),
            log_dir.to_string_lossy().into_owned(),
        ];

        let mut process = if launch.wrapper.is_empty() {
            Self::spawn_program(
                host_key,
                &plugin_host_path,
                &host_args,
                launch.is_debugging(),
            )?
        } else {
            // wrapper[0] wrapper[1..] plugin_host <args>
            let mut args: Vec<String> = launch.wrapper[1..].to_vec();
            args.push(plugin_host_path.to_string_lossy().into_owned());
            args.extend(host_args);
            info!(
                "Spawning plugin host {} under wrapper: {} {}",
                host_key,
                launch.wrapper[0],
                args.join(" ")
            );
            let mut process =
                Self::spawn_program(host_key, Path::new(&launch.wrapper[0]), &args, true)?;
            process.wrapper = Some(launch.wrapper[0].clone());
            process
        };

        // Under a wrapper the child is the wrapper (gdb forks the host), so its pid doesn't name
        // the log file.
        if launch.wrapper.is_empty() {
            let name = crate::audio::ipc::protocol::log_file_name(&process.host_key, process.pid);
            process.log_path = Some(log_dir.join(name));
        }
        match &process.log_path {
            Some(path) => info!(
                "Plugin host {} logs to {}",
                process.host_key,
                path.display()
            ),
            None => info!(
                "Plugin host {} logs to {}/{}-<pid>.log",
                process.host_key,
                log_dir.display(),
                process.host_key
            ),
        }
        if launch.wait_for_debugger {
            warn!(
                "Plugin host {} (pid {}) is waiting for a debugger: gdb -p {}",
                process.host_key, process.pid, process.pid
            );
        }
        Ok(process)
    }

    /// Spawn `program` as a host process: a control socketpair, a doorbell region and a stderr
    /// pipe, with the socket and doorbell moved to their well-known descriptors in the child.
    ///
    /// `debugging`: the host may stop at a breakpoint. Its stderr goes to the engine's terminal
    /// (a debugger's or valgrind's report belongs there), and hung detection is off.
    pub(super) fn spawn_program(
        host_key: String,
        program: &Path,
        args: &[String],
        debugging: bool,
    ) -> Result<Self, String> {
        let (engine_socket, host_socket) = UnixStream::pair()
            .map_err(|e| format!("Failed to create control socketpair: {}", e))?;
        let host_socket_fd = host_socket.as_raw_fd();

        let host_shared = Arc::new(HostSharedMemory::new(&format!(
            "sonara_host_{}",
            sanitize_name(&host_key)
        ))?);
        let host_shared_fd = host_shared.as_raw_fd();

        use std::os::unix::process::CommandExt;
        let mut command = Command::new(program);
        command
            .args(args)
            .stdout(Stdio::inherit())
            // Captured so a crash can report what the host printed before it died.
            .stderr(if debugging {
                Stdio::inherit()
            } else {
                Stdio::piped()
            });
        let child = unsafe {
            command
                .pre_exec(move || {
                    // Move both descriptors to their well-known numbers. dup2 clears
                    // close-on-exec on the new descriptor, except when both are equal.
                    move_fd_to(host_socket_fd, HOST_SOCKET_FD)?;
                    move_fd_to(host_shared_fd, HOST_SHARED_MEMORY_FD)?;
                    Ok(())
                })
                .spawn()
                .map_err(|e| {
                    format!(
                        "Failed to spawn plugin_host at {}: {}",
                        program.display(),
                        e
                    )
                })?
        };
        drop(host_socket);

        let pid = child.id();
        info!("Plugin host {} spawned: PID={}", host_key, pid);

        let mut child = child;
        let stderr = child.stderr.take();
        let mut process = Self::connect(host_key, pid, Some(child), engine_socket, host_shared)?;
        process.debugging = debugging;
        process.start_supervision(stderr);
        Ok(process)
    }

    /// Start the reader thread for a host connected through `engine_socket`.
    pub(super) fn connect(
        host_key: String,
        pid: u32,
        child: Option<Child>,
        engine_socket: UnixStream,
        host_shared: Arc<HostSharedMemory>,
    ) -> Result<Self, String> {
        let routing = Arc::new(Routing {
            pending: Mutex::new(HashMap::new()),
            events: Mutex::new(HashMap::new()),
            connected: AtomicBool::new(true),
            exit: Mutex::new(None),
            stderr_tail: Mutex::new(VecDeque::new()),
            hung: AtomicBool::new(false),
            initializing: AtomicU32::new(0),
        });
        let reader_socket = engine_socket
            .try_clone()
            .map_err(|e| format!("Failed to clone control socket: {}", e))?;
        let reader_routing = Arc::clone(&routing);
        let reader_host = format!("{} (pid {})", host_key, pid);
        thread::Builder::new()
            .name(format!("plugin-ipc-{}", pid))
            .spawn(move || run_reader(reader_socket, reader_routing, reader_host))
            .map_err(|e| format!("Failed to start plugin host reader thread: {}", e))?;

        Ok(Self {
            pid,
            host_key,
            child: Arc::new(Mutex::new(child)),
            writer: Mutex::new(engine_socket),
            routing,
            next_request_id: AtomicU32::new(1),
            host_shared,
            debugging: false,
            log_path: None,
            wrapper: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::time::Duration;

    #[test]
    fn wrapper_commands_split_like_a_shell() {
        assert_eq!(
            split_command("gdb -q -batch -ex run -ex bt --args"),
            vec!["gdb", "-q", "-batch", "-ex", "run", "-ex", "bt", "--args"]
        );
        assert_eq!(
            split_command(r#"gdb -ex 'handle SIGPIPE nostop' -ex "set pagination off" --args"#),
            vec![
                "gdb",
                "-ex",
                "handle SIGPIPE nostop",
                "-ex",
                "set pagination off",
                "--args"
            ]
        );
        assert_eq!(
            split_command(r"valgrind --log-file=a\ b.txt"),
            vec!["valgrind", "--log-file=a b.txt"]
        );
        assert!(split_command("   ").is_empty());
        assert_eq!(split_command("''"), vec![""]);
    }

    #[test]
    fn debugging_follows_wrapper_and_wait() {
        assert!(!HostLaunch::default().is_debugging());
        assert!(HostLaunch {
            wrapper: vec!["valgrind".to_string()],
            wait_for_debugger: false
        }
        .is_debugging());
        assert!(HostLaunch {
            wrapper: Vec::new(),
            wait_for_debugger: true
        }
        .is_debugging());
    }

    #[test]
    fn prune_keeps_the_newest_logs() {
        let dir = tempfile::tempdir().unwrap();
        for i in 0..5 {
            let path = dir.path().join(format!("host-{}.log", i));
            std::fs::write(&path, "x").unwrap();
            let time = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_000 + i);
            std::fs::File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_modified(time)
                .unwrap();
        }
        std::fs::write(dir.path().join("notes.txt"), "keep").unwrap();

        assert_eq!(prune_plugin_logs(dir.path(), 2).unwrap(), 3);
        let mut left: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(left, vec!["host-3.log", "host-4.log", "notes.txt"]);
        assert_eq!(
            prune_plugin_logs(&dir.path().join("missing"), 2).unwrap(),
            0
        );
    }
}
