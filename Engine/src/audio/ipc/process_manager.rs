//! Plugin Process Manager
//!
//! Spawns plugin host processes and routes messages to the plugin instances inside them.
//!
//! Each host process has one control socket (a Unix socketpair) and a reader thread. Requests
//! carry a `request_id`; the reader thread completes the waiting request when the matching
//! response arrives. Unsolicited events go to a per-instance channel that the command thread
//! drains. Writes are serialized by a mutex that is only held while a frame is written, so a
//! slow request never blocks other senders.

use crossbeam::channel::{self, Receiver, RecvTimeoutError, Sender};
use std::collections::{HashMap, VecDeque};
use std::io::Read;
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStderr, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tracing::{debug, error, info, warn};

use super::hosting::{HostAssignment, HostingPolicy};
use super::protocol::{
    HostMessage, HostRequest, InstanceId, LogLevel, PluginCommand, PluginEvent, PluginResponse,
    RequestId, SharedMemoryLayout, NO_REPLY,
};
use super::shared_memory::{HostSharedMemory, SharedMemory};
use super::wire;

/// Default wait for a blocking request's reply. A host that hasn't answered in this long is
/// counted as unresponsive and killed by the command thread (Phase 4).
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

/// Wait for `Initialize`: loading a plugin can read large sample libraries.
const INITIALIZE_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a host gets to exit after `Shutdown` before it is killed.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(1);

/// How long the watcher waits for a killed host to be reaped before giving up on it.
const KILL_REAP_GRACE: Duration = Duration::from_millis(500);

/// Lines of the host's stderr kept for a crash report. Enough for a Rust panic message plus
/// its backtrace, which otherwise pushes the message out.
const STDERR_TAIL_LINES: usize = 80;

/// Largest stderr chunk read at once, so a line the host never terminates can't grow the buffer.
const STDERR_TAIL_BYTES_PER_READ: usize = 4096;

/// How long a shared host gets to drop one of its instances (`Unload`).
const UNLOAD_TIMEOUT: Duration = Duration::from_secs(2);

/// How long `crash_info` waits for the watcher to record the exit status.
const CRASH_STATUS_GRACE: Duration = Duration::from_millis(250);

/// The control socket's descriptor number in the host process.
const HOST_SOCKET_FD: i32 = 3;

/// The host doorbell region's descriptor number in the host process.
const HOST_SHARED_MEMORY_FD: i32 = 4;

/// Env var with a command prefix for spawning hosts, e.g. `gdb -q -batch -ex run -ex bt --args`
/// or `valgrind`. Split like a shell would (quotes allowed, no expansion).
pub const HOST_WRAPPER_ENV: &str = "SONARA_PLUGIN_HOST_WRAPPER";

/// Env var that makes every host wait for a debugger before it reads a command. The host reads
/// it too (the variable is inherited).
pub const HOST_WAIT_ENV: &str = "SONARA_PLUGIN_HOST_WAIT";

/// Request timeout while a host runs under a debugger or wrapper: it may sit at a breakpoint, or
/// run tens of times slower under valgrind. Long, but still bounded.
const DEBUG_REQUEST_TIMEOUT: Duration = Duration::from_secs(120);

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
fn open_pidfd(pid: u32) -> RawFd {
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) } as RawFd;
    if fd < 0 {
        -1
    } else {
        fd
    }
}

/// Block until `pidfd` reports the process exited, or a short interval passes. Falls back to
/// sleeping when no pidfd is available.
fn wait_for_exit(pidfd: RawFd) {
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
fn push_stderr_line(routing: &Routing, text: &str) {
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
fn drain_stderr(stderr: ChildStderr, routing: Arc<Routing>) {
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

/// Lock a mutex, recovering it if a panicking thread held it.
fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `dup2` `fd` onto `target` in a freshly forked child, clearing close-on-exec so the descriptor
/// survives `exec`. A no-op when the numbers already match.
fn move_fd_to(fd: RawFd, target: RawFd) -> std::io::Result<()> {
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

/// State shared between a host's `PluginProcess` and its reader thread.
struct Routing {
    /// Requests waiting for a reply, by request id.
    pending: Mutex<HashMap<RequestId, Sender<PluginResponse>>>,
    /// Where each instance's unsolicited events go.
    events: Mutex<HashMap<InstanceId, Sender<PluginEvent>>>,
    /// False once the control socket has closed.
    connected: AtomicBool,
    /// Set by the watcher thread once the host process has been reaped.
    exit: Mutex<Option<HostExit>>,
    /// Last lines of the host's stderr, oldest first.
    stderr_tail: Mutex<VecDeque<String>>,
    /// Set when a blocking request timed out. The command thread kills a hung host (Phase 4).
    hung: AtomicBool,
    /// `Initialize` requests in flight. Loading a plugin can keep a shared host's main thread
    /// busy for many seconds, so while one runs, other requests timing out don't mean the host
    /// is hung.
    initializing: AtomicU32,
}

impl Routing {
    fn dispatch(&self, host: &str, msg: HostMessage) {
        match msg {
            HostMessage::Response {
                instance_id,
                request_id,
                response,
            } => {
                let waiter = lock(&self.pending).remove(&request_id);
                match waiter {
                    Some(tx) => {
                        let _ = tx.send(response);
                    }
                    None if request_id == NO_REPLY => {
                        if let PluginResponse::Error { command, error } = response {
                            warn!(
                                "Plugin host {} instance {}: {} failed: {}",
                                host, instance_id, command, error
                            );
                        }
                    }
                    None => debug!(
                        "Plugin host {} instance {}: dropping late response to request {}: {:?}",
                        host, instance_id, request_id, response
                    ),
                }
            }
            HostMessage::Log {
                instance_id,
                plugin,
                level,
                message,
            } => {
                // Logged again here so the line reaches the engine log and, through the log
                // forwarder, Godot's `/log`. The host's own log file has the full context.
                let source = match (instance_id, plugin.is_empty()) {
                    (0, _) => format!("Plugin host {}", host),
                    (id, true) => format!("Plugin instance {} (host {})", id, host),
                    (id, false) => format!("Plugin {} (instance {}, host {})", plugin, id, host),
                };
                match level {
                    LogLevel::Warn => warn!("{}: {}", source, message),
                    LogLevel::Error => error!("{}: {}", source, message),
                }
            }
            HostMessage::Event { instance_id, event } => {
                let events = lock(&self.events);
                match events.get(&instance_id) {
                    Some(tx) => {
                        let _ = tx.send(event);
                    }
                    None => debug!(
                        "Plugin host {}: event for unknown instance {}: {:?}",
                        host, instance_id, event
                    ),
                }
            }
        }
    }

    /// The socket closed: fail every waiting request and disconnect the event channels.
    fn disconnect(&self) {
        self.connected.store(false, Ordering::Release);
        lock(&self.pending).clear();
        lock(&self.events).clear();
    }

    /// Why the host stopped, as far as the watcher has seen.
    fn crash(&self, process: &PluginProcess) -> HostCrash {
        HostCrash {
            host_key: process.host_key.clone(),
            pid: process.pid,
            exit: *lock(&self.exit),
            stderr_tail: lock(&self.stderr_tail).iter().cloned().collect(),
            log_path: process.log_path.clone(),
            wrapper: process.wrapper.clone(),
        }
    }
}

/// Reader thread: decode frames until the host closes the socket.
fn run_reader(socket: UnixStream, routing: Arc<Routing>, host: String) {
    loop {
        match wire::recv_frame::<HostMessage>(&socket) {
            Ok(Some((msg, _fds))) => routing.dispatch(&host, msg),
            Ok(None) => {
                info!("Plugin host {} closed its control socket", host);
                break;
            }
            Err(e) => {
                error!("Plugin host {} control socket failed: {}", host, e);
                break;
            }
        }
    }
    routing.disconnect();
}

/// One plugin host process and its control socket.
pub struct PluginProcess {
    /// Process ID
    pub pid: u32,
    host_key: String,
    /// The child handle, shared with the watcher thread that reaps it.
    child: Arc<Mutex<Option<Child>>>,
    /// Write side of the control socket. Held only while a frame is written.
    writer: Mutex<UnixStream>,
    routing: Arc<Routing>,
    next_request_id: AtomicU32,
    /// One doorbell word shared with this host, used by the per-block audio handshake and by
    /// every instance that will share this host in later phases.
    host_shared: Arc<HostSharedMemory>,
    /// Runs under a debugger or wrapper: no hung detection, long request timeouts.
    debugging: bool,
    /// The host's log file, when its name is known.
    log_path: Option<PathBuf>,
    /// The wrapper program the host runs under, if any.
    wrapper: Option<String>,
}

impl PluginProcess {
    /// Spawn a `plugin_host` process (under `launch`'s wrapper, if any) and start its reader
    /// thread.
    fn spawn(host_key: String, launch: &HostLaunch) -> Result<Self, String> {
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
            let name = super::protocol::log_file_name(&process.host_key, process.pid);
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
    fn spawn_program(
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
    fn connect(
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

    /// Watch the child process: drain its stderr into a tail buffer and reap it when it exits,
    /// recording the signal or exit code. A watcher per host makes a crash visible immediately
    /// and keeps its stderr for the crash report (Phase 4).
    fn start_supervision(&self, stderr: Option<ChildStderr>) {
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

    fn next_request_id(&self) -> RequestId {
        loop {
            let id = self.next_request_id.fetch_add(1, Ordering::Relaxed);
            if id != NO_REPLY {
                return id;
            }
        }
    }

    fn write(&self, request: &HostRequest, fds: &[i32]) -> Result<(), String> {
        if !self.routing.connected.load(Ordering::Acquire) {
            return Err(format!("Plugin host {} is not running", self.host_key));
        }
        let writer = lock(&self.writer);
        wire::send_frame(&writer, request, fds)
            .map_err(|e| format!("Failed to send to plugin host {}: {}", self.host_key, e))
    }

    /// Send a command and wait up to `timeout` for its reply.
    fn request_with_fds(
        &self,
        instance_id: InstanceId,
        command: PluginCommand,
        fds: &[i32],
        timeout: Duration,
    ) -> Result<PluginResponse, String> {
        let timeout = if self.debugging {
            timeout.max(DEBUG_REQUEST_TIMEOUT)
        } else {
            timeout
        };
        let request_id = self.next_request_id();
        let (tx, rx) = channel::bounded(1);
        lock(&self.routing.pending).insert(request_id, tx);

        let request = HostRequest {
            instance_id,
            request_id,
            command,
        };
        if let Err(e) = self.write(&request, fds) {
            lock(&self.routing.pending).remove(&request_id);
            return Err(e);
        }

        match rx.recv_timeout(timeout) {
            Ok(response) => Ok(response),
            Err(RecvTimeoutError::Timeout) => {
                lock(&self.routing.pending).remove(&request_id);
                self.record_timeout(&request.command);
                Err(format!(
                    "Plugin host {} didn't answer {:?} within {:.1}s",
                    self.host_key,
                    request.command,
                    timeout.as_secs_f32()
                ))
            }
            Err(RecvTimeoutError::Disconnected) => Err(format!(
                "Plugin host {} exited before answering {:?}",
                self.host_key, request.command
            )),
        }
    }

    /// A request timed out. A host that lets a request time out is unresponsive: the command
    /// thread kills it on its next tick and treats it as crashed. Not while another instance is
    /// loading in it, though (its main thread is busy, not stuck), nor under a debugger (it may
    /// be stopped on purpose). An `Initialize` that times out itself always counts, unless
    /// debugging.
    fn record_timeout(&self, command: &PluginCommand) {
        if self.debugging {
            return;
        }
        let initializing = matches!(command, PluginCommand::Initialize { .. });
        let loading_other = self.routing.initializing.load(Ordering::Acquire) > 0;
        if initializing || !loading_other {
            self.routing.hung.store(true, Ordering::Release);
        }
    }

    /// Send a command without waiting for a reply.
    fn send(&self, instance_id: InstanceId, command: PluginCommand) -> Result<(), String> {
        self.write(
            &HostRequest {
                instance_id,
                request_id: NO_REPLY,
                command,
            },
            &[],
        )
    }

    /// This host's doorbell word, shared with every instance that runs in it.
    pub fn host_shared(&self) -> &Arc<HostSharedMemory> {
        &self.host_shared
    }

    /// False once the control socket has closed or the process has exited.
    pub fn is_alive(&self) -> bool {
        if !self.routing.connected.load(Ordering::Acquire) {
            return false;
        }
        if lock(&self.routing.exit).is_some() {
            return false;
        }
        // No child handle means an in-process stand-in (tests): trust the socket.
        match lock(&self.child).as_mut() {
            Some(child) => matches!(child.try_wait(), Ok(None)),
            None => true,
        }
    }

    /// True when a blocking request timed out and the host hasn't answered since.
    pub fn is_hung(&self) -> bool {
        self.routing.hung.load(Ordering::Acquire)
    }

    /// True when the host runs under a debugger or wrapper (no hung detection).
    pub fn is_debugging(&self) -> bool {
        self.debugging
    }

    /// The host's log file, when its name is known.
    pub fn log_path(&self) -> Option<&Path> {
        self.log_path.as_deref()
    }

    /// Why this host stopped, or None while it is still running. Waits briefly for the watcher
    /// to record the exit status, so a crash report has the signal or exit code.
    pub fn crash_info(&self) -> Option<HostCrash> {
        let deadline = Instant::now() + CRASH_STATUS_GRACE;
        loop {
            if lock(&self.routing.exit).is_some() {
                return Some(self.routing.crash(self));
            }
            let suspicious = !self.routing.connected.load(Ordering::Acquire) || self.is_hung();
            if !suspicious || Instant::now() >= deadline {
                if suspicious {
                    return Some(self.routing.crash(self));
                }
                return None;
            }
            thread::sleep(Duration::from_millis(5));
        }
    }

    /// Kill the host process now, for a host that stopped responding. The watcher reaps it.
    pub fn kill(&self) {
        warn!("Killing plugin host {} (pid {})", self.host_key, self.pid);
        if let Some(child) = lock(&self.child).as_mut() {
            if let Err(e) = child.kill() {
                warn!("Failed to kill plugin host {}: {}", self.host_key, e);
            }
        }
        // The socket reader sees the close and fails pending requests; the watcher records the
        // exit status. Nothing here waits, so the command thread isn't held up.
        let _ = lock(&self.writer).shutdown(std::net::Shutdown::Both);
    }

    /// Ask the host to exit, then kill it if it hasn't within `SHUTDOWN_GRACE`. The watcher
    /// thread reaps the process; this waits for it to record the exit status.
    pub fn shutdown(&self) {
        info!("Shutting down plugin host {}", self.host_key);
        if self.routing.connected.load(Ordering::Acquire) {
            if let Err(e) = self.send(0, PluginCommand::Shutdown) {
                warn!("{}", e);
            }
        }
        let _ = lock(&self.writer).shutdown(std::net::Shutdown::Write);

        let deadline = Instant::now() + SHUTDOWN_GRACE;
        while lock(&self.routing.exit).is_none()
            && lock(&self.child).is_some()
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(10));
        }
        if lock(&self.routing.exit).is_some() || lock(&self.child).is_none() {
            debug!("Plugin host {} exited", self.host_key);
            return;
        }

        warn!(
            "Plugin host {} didn't exit within {:?}; killing it",
            self.host_key, SHUTDOWN_GRACE
        );
        if let Some(child) = lock(&self.child).as_mut() {
            let _ = child.kill();
        }
        let deadline = Instant::now() + KILL_REAP_GRACE;
        while lock(&self.routing.exit).is_none() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for PluginProcess {
    fn drop(&mut self) {
        // Kill without waiting for the grace period: Drop runs when the host is being thrown
        // away anyway (device removed, engine shutting down). The watcher reaps it.
        let alive = self.is_alive();
        if alive {
            warn!("Force killing plugin host {} in Drop", self.host_key);
            if let Some(child) = lock(&self.child).as_mut() {
                let _ = child.kill();
            }
        }
    }
}

/// Connection to one plugin instance: its host process, event channel and shared memory.
/// Cheap to clone; every clone talks to the same instance.
#[derive(Clone)]
pub struct InstanceConnection {
    instance_id: InstanceId,
    host: Arc<PluginProcess>,
    events: Receiver<PluginEvent>,
    shared_memory: Arc<SharedMemory>,
    host_shared: Arc<HostSharedMemory>,
}

impl InstanceConnection {
    /// Send a command and wait up to `timeout` for the reply.
    pub fn request(
        &self,
        command: PluginCommand,
        timeout: Duration,
    ) -> Result<PluginResponse, String> {
        self.host
            .request_with_fds(self.instance_id, command, &[], timeout)
    }

    /// Send a command without waiting. Errors the host reports are logged.
    pub fn send(&self, command: PluginCommand) -> Result<(), String> {
        self.host.send(self.instance_id, command)
    }

    /// Next unsolicited event from the instance, if any. Never blocks.
    pub fn try_event(&self) -> Option<PluginEvent> {
        self.events.try_recv().ok()
    }

    pub fn is_alive(&self) -> bool {
        self.host.is_alive()
    }

    /// True when a blocking request timed out and the host hasn't answered since.
    pub fn is_hung(&self) -> bool {
        self.host.is_hung()
    }

    /// Why this host stopped, or None while it is running.
    pub fn crash_info(&self) -> Option<HostCrash> {
        self.host.crash_info()
    }

    /// True when the host runs under a debugger or wrapper: don't kill it for being slow.
    pub fn is_debugging(&self) -> bool {
        self.host.is_debugging()
    }

    /// The host's log file, when its name is known.
    pub fn log_path(&self) -> Option<&Path> {
        self.host.log_path()
    }

    /// Kill the host process (hung host handling).
    pub fn kill_host(&self) {
        self.host.kill()
    }

    pub fn shared_memory(&self) -> &Arc<SharedMemory> {
        &self.shared_memory
    }

    /// The host process's doorbell word, shared by every instance in that host.
    pub fn host_shared(&self) -> &Arc<HostSharedMemory> {
        &self.host_shared
    }

    pub fn host_pid(&self) -> u32 {
        self.host.pid
    }

    /// The key of the host process this instance runs in.
    pub fn host_key(&self) -> &str {
        &self.host.host_key
    }
}

/// Plugin process manager: host key → host process, instance id → instance.
pub struct ProcessManager {
    hosts: Mutex<HashMap<String, Arc<PluginProcess>>>,
    instances: Mutex<HashMap<InstanceId, InstanceConnection>>,
    next_instance_id: AtomicU32,
    /// How instances are grouped into host processes (Phase 5).
    hosting: Mutex<HostingPolicy>,
    /// How hosts are launched (debugger wrapper, wait for a debugger), read from the env once.
    launch: HostLaunch,
}

impl ProcessManager {
    /// Create a new process manager
    pub fn new() -> Self {
        Self {
            hosts: Mutex::new(HashMap::new()),
            instances: Mutex::new(HashMap::new()),
            next_instance_id: AtomicU32::new(1),
            hosting: Mutex::new(HostingPolicy::default()),
            launch: HostLaunch::from_env(),
        }
    }

    /// Allocate an id for a new plugin instance.
    pub fn allocate_instance_id(&self) -> InstanceId {
        self.next_instance_id.fetch_add(1, Ordering::Relaxed)
    }

    /// Replace the hosting policy. Instances already loaded keep their host until they are moved
    /// (the command thread compares each one's assignment with `assign_host`).
    pub fn set_hosting_policy(&self, policy: HostingPolicy) {
        *lock(&self.hosting) = policy;
    }

    /// The host an instance of `plugin_id` from `vendor` belongs in under the current policy.
    pub fn assign_host(
        &self,
        plugin_id: &str,
        vendor: &str,
        instance_id: InstanceId,
    ) -> HostAssignment {
        lock(&self.hosting).assign(plugin_id, vendor, instance_id)
    }

    /// Locate the `plugin_host` binary, which must sit next to the running engine executable.
    /// Fails with an actionable message when it is missing (e.g. only `engine` was built).
    fn plugin_host_path() -> Result<PathBuf, String> {
        let exe_path = std::env::current_exe()
            .map_err(|e| format!("Failed to get current exe path: {}", e))?;
        let exe_dir = exe_path.parent().ok_or_else(|| {
            format!(
                "Engine executable has no parent dir: {}",
                exe_path.display()
            )
        })?;
        let plugin_host_path = exe_dir.join("plugin_host");

        if !plugin_host_path.is_file() {
            return Err(format!(
                "plugin_host binary not found at {}. Build all engine binaries with the same \
                 profile as the engine (e.g. `cargo build --release` in Engine/), or launch via \
                 Engine/run_release.sh",
                plugin_host_path.display()
            ));
        }

        Ok(plugin_host_path)
    }

    /// The live host for `host_key`, spawning one if there is none, with `instance_id`'s event
    /// route registered. Registering under the hosts lock keeps `release_host_if_unused` from
    /// shutting the host down between finding it and claiming it.
    fn host_for(
        &self,
        host_key: &str,
        instance_id: InstanceId,
        events: Sender<PluginEvent>,
    ) -> Result<Arc<PluginProcess>, String> {
        let mut hosts = lock(&self.hosts);
        let host = match hosts.get(host_key) {
            Some(host) if host.is_alive() => Arc::clone(host),
            existing => {
                if existing.is_some() {
                    warn!("Plugin host {} is dead; spawning a new one", host_key);
                }
                let host = Arc::new(PluginProcess::spawn(host_key.to_string(), &self.launch)?);
                hosts.insert(host_key.to_string(), Arc::clone(&host));
                host
            }
        };
        lock(&host.routing.events).insert(instance_id, events);
        Ok(host)
    }

    /// Load a plugin as instance `instance_id` in the host process for `host_key`. Blocks until
    /// the plugin is loaded; call it off the audio and command threads.
    pub fn spawn_instance(
        &self,
        instance_id: InstanceId,
        host_key: &str,
        plugin_path: PathBuf,
        plugin_id: String,
        sample_rate: f32,
        max_buffer_size: usize,
    ) -> Result<InstanceConnection, String> {
        info!(
            "Loading plugin {} as instance {} in host {}",
            plugin_id, instance_id, host_key
        );
        let (events_tx, events_rx) = channel::unbounded();
        let host = self.host_for(host_key, instance_id, events_tx)?;
        let connection_host_shared = Arc::clone(host.host_shared());

        let layout = SharedMemoryLayout::new(max_buffer_size);
        let shm_name = format!("sonara_plugin_{}_{}", host.pid, instance_id);
        let shared_memory = match SharedMemory::new(&shm_name, layout) {
            Ok(shm) => Arc::new(shm),
            Err(e) => {
                lock(&host.routing.events).remove(&instance_id);
                self.release_host_if_unused(&host);
                return Err(format!("Failed to create shared memory: {}", e));
            }
        };

        host.routing.initializing.fetch_add(1, Ordering::AcqRel);
        let result = host.request_with_fds(
            instance_id,
            PluginCommand::Initialize {
                plugin_path,
                plugin_id: plugin_id.clone(),
                sample_rate,
                max_buffer_size,
            },
            &[shared_memory.as_raw_fd()],
            INITIALIZE_TIMEOUT,
        );
        host.routing.initializing.fetch_sub(1, Ordering::AcqRel);
        let error = match result {
            Ok(PluginResponse::InitializeSuccess { .. }) => None,
            Ok(PluginResponse::InitializeError { error }) => {
                Some(format!("Plugin initialization failed: {}", error))
            }
            Ok(other) => Some(format!("Unexpected response to Initialize: {:?}", other)),
            Err(e) => Some(e),
        };
        if let Some(error) = error {
            lock(&host.routing.events).remove(&instance_id);
            self.release_host_if_unused(&host);
            return Err(error);
        }

        info!(
            "Plugin {} initialized as instance {} (host pid {})",
            plugin_id, instance_id, host.pid
        );
        let connection = InstanceConnection {
            instance_id,
            host,
            events: events_rx,
            shared_memory,
            host_shared: Arc::clone(&connection_host_shared),
        };
        lock(&self.instances).insert(instance_id, connection.clone());
        Ok(connection)
    }

    /// The connection to a loaded instance.
    pub fn instance(&self, instance_id: InstanceId) -> Option<InstanceConnection> {
        lock(&self.instances).get(&instance_id).cloned()
    }

    /// Forget an instance. A host other instances still use only unloads this one; otherwise the
    /// host shuts down. Blocking; call it off the audio thread and without the state lock.
    pub fn shutdown_instance(&self, instance_id: InstanceId) {
        let Some(connection) = lock(&self.instances).remove(&instance_id) else {
            return;
        };
        let host = &connection.host;
        let shared = {
            let mut events = lock(&host.routing.events);
            events.remove(&instance_id);
            !events.is_empty()
        };
        if shared && host.is_alive() {
            info!(
                "Unloading instance {} from shared plugin host {}",
                instance_id, host.host_key
            );
            match host.request_with_fds(instance_id, PluginCommand::Unload, &[], UNLOAD_TIMEOUT) {
                Ok(PluginResponse::Unloaded) => {}
                Ok(other) => warn!(
                    "Plugin host {} answered Unload of instance {} with {:?}",
                    host.host_key, instance_id, other
                ),
                Err(e) => warn!("{}", e),
            }
            return;
        }
        self.release_host_if_unused(host);
    }

    /// Shut `host` down if no instance lives in it. An instance counts from the moment its event
    /// route is registered, so one that is still loading keeps the host alive.
    fn release_host_if_unused(&self, host: &Arc<PluginProcess>) {
        {
            // Under the hosts lock, so `host_for` can't hand the host to a new instance while
            // it is being released.
            let mut hosts = lock(&self.hosts);
            if host.is_alive() && !lock(&host.routing.events).is_empty() {
                return;
            }
            if hosts
                .get(&host.host_key)
                .is_some_and(|registered| Arc::ptr_eq(registered, host))
            {
                hosts.remove(&host.host_key);
            }
        }
        host.shutdown();
    }

    /// Shutdown all plugin processes
    pub fn shutdown_all(&self) {
        lock(&self.instances).clear();
        let hosts: Vec<_> = lock(&self.hosts).drain().map(|(_, host)| host).collect();
        for host in hosts {
            host.shutdown();
        }
    }
}

/// A host key made safe for a memfd name.
fn sanitize_name(key: &str) -> String {
    key.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A host process stood in for by the test: returns the engine side and the host's socket.
    fn fake_host() -> (PluginProcess, UnixStream) {
        let (engine_socket, host_socket) = UnixStream::pair().unwrap();
        let host_shared =
            Arc::new(HostSharedMemory::new("sonara_test_fake_host").expect("doorbell"));
        let process =
            PluginProcess::connect("test".to_string(), 0, None, engine_socket, host_shared)
                .unwrap();
        (process, host_socket)
    }

    fn recv_request(host: &UnixStream) -> HostRequest {
        wire::recv_frame::<HostRequest>(host).unwrap().unwrap().0
    }

    fn reply(host: &UnixStream, request: &HostRequest, response: PluginResponse) {
        let msg = HostMessage::Response {
            instance_id: request.instance_id,
            request_id: request.request_id,
            response,
        };
        wire::send_frame(host, &msg, &[]).unwrap();
    }

    #[test]
    fn responses_complete_their_own_request_even_out_of_order() {
        let (process, host) = fake_host();
        let process = Arc::new(process);

        let first = {
            let process = Arc::clone(&process);
            thread::spawn(move || {
                process.request_with_fds(1, PluginCommand::HasGui, &[], REQUEST_TIMEOUT)
            })
        };
        let a = recv_request(&host);
        let second = {
            let process = Arc::clone(&process);
            thread::spawn(move || {
                process.request_with_fds(1, PluginCommand::GetParameterInfo, &[], REQUEST_TIMEOUT)
            })
        };
        let b = recv_request(&host);
        assert_ne!(a.request_id, b.request_id);

        // Answer the second request first
        reply(
            &host,
            &b,
            PluginResponse::ParameterInfo { params: Vec::new() },
        );
        reply(
            &host,
            &a,
            PluginResponse::HasGuiResponse { supported: true },
        );

        assert!(matches!(
            first.join().unwrap(),
            Ok(PluginResponse::HasGuiResponse { supported: true })
        ));
        assert!(matches!(
            second.join().unwrap(),
            Ok(PluginResponse::ParameterInfo { .. })
        ));
    }

    #[test]
    fn timeout_then_late_reply_is_dropped() {
        let (process, host) = fake_host();
        let result =
            process.request_with_fds(1, PluginCommand::HasGui, &[], Duration::from_millis(20));
        assert!(result.unwrap_err().contains("didn't answer"));

        // The late reply must not complete the next request
        let late = recv_request(&host);
        reply(
            &host,
            &late,
            PluginResponse::HasGuiResponse { supported: true },
        );

        let process = Arc::new(process);
        let next = {
            let process = Arc::clone(&process);
            thread::spawn(move || {
                process.request_with_fds(1, PluginCommand::CloseGui, &[], REQUEST_TIMEOUT)
            })
        };
        let request = recv_request(&host);
        reply(&host, &request, PluginResponse::GuiClosed);
        assert!(matches!(
            next.join().unwrap(),
            Ok(PluginResponse::GuiClosed)
        ));
    }

    #[test]
    fn events_go_to_their_instance() {
        let (process, host) = fake_host();
        let (tx1, rx1) = channel::unbounded();
        let (tx2, rx2) = channel::unbounded();
        lock(&process.routing.events).insert(1, tx1);
        lock(&process.routing.events).insert(2, tx2);

        let event = HostMessage::Event {
            instance_id: 2,
            event: PluginEvent::GuiResizeRequest {
                width: 640,
                height: 480,
            },
        };
        wire::send_frame(&host, &event, &[]).unwrap();

        let received = rx2.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(
            received,
            PluginEvent::GuiResizeRequest {
                width: 640,
                height: 480
            }
        ));
        assert!(rx1.try_recv().is_err());
    }

    #[test]
    fn host_exit_fails_pending_requests_and_later_sends() {
        let (process, host) = fake_host();
        let process = Arc::new(process);
        let waiting = {
            let process = Arc::clone(&process);
            thread::spawn(move || {
                process.request_with_fds(1, PluginCommand::HasGui, &[], REQUEST_TIMEOUT)
            })
        };
        recv_request(&host);
        let started = Instant::now();
        drop(host);

        assert!(waiting.join().unwrap().unwrap_err().contains("exited"));
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(!process.is_alive());
        assert!(process.send(1, PluginCommand::Reset).is_err());
    }

    #[test]
    fn request_timeout_marks_the_host_hung() {
        let (process, _host) = fake_host();
        assert!(!process.is_hung());
        let result =
            process.request_with_fds(1, PluginCommand::HasGui, &[], Duration::from_millis(20));
        assert!(result.unwrap_err().contains("didn't answer"));
        assert!(process.is_hung());
    }

    /// Loading a plugin can keep a shared host's main thread busy for many seconds; another
    /// instance's request timing out meanwhile doesn't make the host hung.
    #[test]
    fn a_timeout_while_another_instance_initializes_is_not_a_hang() {
        let (process, _host) = fake_host();
        process.routing.initializing.fetch_add(1, Ordering::AcqRel);
        let result =
            process.request_with_fds(2, PluginCommand::HasGui, &[], Duration::from_millis(20));
        assert!(result.unwrap_err().contains("didn't answer"));
        assert!(!process.is_hung());

        process.routing.initializing.fetch_sub(1, Ordering::AcqRel);
        let result =
            process.request_with_fds(2, PluginCommand::HasGui, &[], Duration::from_millis(20));
        assert!(result.is_err());
        assert!(process.is_hung());
    }

    /// Register `instance_id` as living in `process`, as `spawn_instance` would.
    fn register_instance(manager: &ProcessManager, process: &Arc<PluginProcess>, id: InstanceId) {
        let (tx, rx) = channel::unbounded();
        lock(&process.routing.events).insert(id, tx);
        let shared_memory = Arc::new(
            SharedMemory::new(
                &format!("sonara_test_shared_host_{}", id),
                SharedMemoryLayout::new(64),
            )
            .unwrap(),
        );
        lock(&manager.instances).insert(
            id,
            InstanceConnection {
                instance_id: id,
                host: Arc::clone(process),
                events: rx,
                shared_memory,
                host_shared: Arc::clone(process.host_shared()),
            },
        );
    }

    /// Removing one instance of a shared host unloads just that instance; removing the last one
    /// shuts the host down.
    #[test]
    fn a_shared_host_outlives_all_but_its_last_instance() {
        let manager = ProcessManager::new();
        let (process, host) = fake_host();
        let process = Arc::new(process);
        lock(&manager.hosts).insert(process.host_key.clone(), Arc::clone(&process));
        register_instance(&manager, &process, 1);
        register_instance(&manager, &process, 2);

        let responder = thread::spawn(move || {
            let request = recv_request(&host);
            assert!(matches!(request.command, PluginCommand::Unload));
            assert_eq!(request.instance_id, 1);
            reply(&host, &request, PluginResponse::Unloaded);
            host
        });
        manager.shutdown_instance(1);
        let host = responder.join().unwrap();
        assert!(manager.instance(1).is_none());
        assert!(manager.instance(2).is_some());
        assert!(
            lock(&manager.hosts).contains_key(&process.host_key),
            "host still in use"
        );

        manager.shutdown_instance(2);
        assert!(
            lock(&manager.hosts).is_empty(),
            "last instance releases the host"
        );
        let request = recv_request(&host);
        assert!(matches!(request.command, PluginCommand::Shutdown));
    }

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

    /// A host under a debugger may sit at a breakpoint: a timed-out request doesn't mark it hung.
    #[test]
    fn a_debugged_host_is_never_marked_hung() {
        let (mut process, _host) = fake_host();
        process.debugging = true;
        process.record_timeout(&PluginCommand::HasGui);
        process.record_timeout(&PluginCommand::Initialize {
            plugin_path: PathBuf::from("/x.clap"),
            plugin_id: "x".to_string(),
            sample_rate: 48_000.0,
            max_buffer_size: 64,
        });
        assert!(!process.is_hung());

        process.debugging = false;
        process.record_timeout(&PluginCommand::HasGui);
        assert!(process.is_hung());
    }

    #[test]
    fn forwarded_host_log_lines_are_not_routed_as_events() {
        let (process, host) = fake_host();
        let (tx, rx) = channel::unbounded();
        lock(&process.routing.events).insert(3, tx);
        let log = HostMessage::Log {
            instance_id: 3,
            plugin: "Test".to_string(),
            level: LogLevel::Warn,
            message: "careful".to_string(),
        };
        wire::send_frame(&host, &log, &[]).unwrap();
        // Follow with an event so we know the log line was dispatched first.
        let event = HostMessage::Event {
            instance_id: 3,
            event: PluginEvent::StateDirty,
        };
        wire::send_frame(&host, &event, &[]).unwrap();
        let received = rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(matches!(received, PluginEvent::StateDirty));
        assert!(rx.try_recv().is_err());
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
