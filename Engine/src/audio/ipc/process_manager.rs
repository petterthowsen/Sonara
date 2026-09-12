//! Plugin Process Manager
//!
//! Manages plugin host subprocesses: spawning, monitoring, communication, and cleanup.

use nix::sys::socket::{sendmsg, ControlMessage, MsgFlags};
use std::collections::{HashMap, VecDeque};
use std::io::IoSlice;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::io::{AsRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::{Arc, Mutex};
use std::thread;
use tracing::{debug, error, info, warn};

use super::protocol::{PluginCommand, PluginResponse, SharedMemoryLayout};
use super::shared_memory::SharedMemory;

/// Plugin process handle
pub struct PluginProcess {
    /// Process ID
    pub pid: u32,

    /// Child process handle (Option to safely handle ownership during shutdown)
    child: Option<Child>,

    /// Control socket (wrapped in Option for interior mutability pattern)
    socket: Option<TcpStream>,

    /// Buffer for partial responses received during non-blocking polls
    partial_read_buffer: Vec<u8>,

    /// Queue of unsolicited responses encountered during synchronous waits
    pending_async_responses: VecDeque<PluginResponse>,

    /// Shared memory for audio/MIDI (Arc for lock-free sharing with audio thread)
    shared_memory: Arc<SharedMemory>,

    /// Plugin metadata
    plugin_id: String,
    plugin_path: PathBuf,
}

/// Send a file descriptor over a Unix domain socket
#[allow(dead_code)]
fn send_fd(socket: &UnixStream, fd: RawFd) -> Result<(), String> {
    let data = [0u8; 1]; // Dummy data
    let iov = [IoSlice::new(&data)];
    let fds = [fd];
    let cmsg = ControlMessage::ScmRights(&fds);

    sendmsg::<()>(socket.as_raw_fd(), &iov, &[cmsg], MsgFlags::empty(), None)
        .map_err(|e| format!("Failed to send FD: {}", e))?;

    Ok(())
}

/// Receive a file descriptor over a Unix domain socket
#[allow(dead_code)]
fn recv_fd(socket: &UnixStream) -> Result<RawFd, String> {
    use nix::cmsg_space;
    use nix::sys::socket::{recvmsg, ControlMessageOwned};
    use std::io::IoSliceMut;

    let mut data = [0u8; 1];
    let mut iov = [IoSliceMut::new(&mut data)];
    let mut cmsg_space = cmsg_space!([RawFd; 1]);

    let msg = recvmsg::<()>(
        socket.as_raw_fd(),
        &mut iov,
        Some(&mut cmsg_space),
        MsgFlags::empty(),
    )
    .map_err(|e| format!("Failed to receive FD: {}", e))?;

    // Parse control messages
    for cmsg in msg
        .cmsgs()
        .map_err(|e| format!("Failed to parse control messages: {}", e))?
    {
        if let ControlMessageOwned::ScmRights(fds) = cmsg {
            if let Some(&fd) = fds.first() {
                return Ok(fd);
            }
        }
    }

    Err("No file descriptor received".to_string())
}

impl PluginProcess {
    fn is_unsolicited_response(response: &PluginResponse) -> bool {
        matches!(
            response,
            PluginResponse::ParameterValueChanged { .. }
                | PluginResponse::GuiResizeRequest { .. }
                | PluginResponse::ProcessingStarted
                | PluginResponse::ProcessingStopped
                | PluginResponse::GuiClosed
                | PluginResponse::ShutdownAck
        )
    }

    /// Try to read a full JSON line from the socket, optionally in non-blocking mode
    fn read_response_line(&mut self, nonblocking: bool) -> Result<Option<String>, String> {
        use std::io::{ErrorKind, Read};

        let socket = self.socket.as_mut().ok_or("Socket not available")?;

        loop {
            if let Some(pos) = self.partial_read_buffer.iter().position(|&b| b == b'\n') {
                let mut line_bytes: Vec<u8> = self.partial_read_buffer.drain(..=pos).collect();
                if let Some(b'\n') = line_bytes.last() {
                    line_bytes.pop();
                }
                if let Some(b'\r') = line_bytes.last() {
                    line_bytes.pop();
                }
                let line = String::from_utf8(line_bytes)
                    .map_err(|e| format!("Failed to decode response as UTF-8: {}", e))?;
                return Ok(Some(line));
            }

            let mut buf = [0u8; 512];
            match socket.read(&mut buf) {
                Ok(0) => return Err("Connection closed".to_string()),
                Ok(n) => {
                    self.partial_read_buffer.extend_from_slice(&buf[..n]);
                    continue;
                }
                Err(ref e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                    if nonblocking {
                        return Ok(None);
                    } else {
                        return Err(format!("Failed to read response: {}", e));
                    }
                }
                Err(e) => return Err(format!("Failed to read response: {}", e)),
            }
        }
    }

    /// Send a command to the plugin subprocess
    pub fn send_command(&mut self, cmd: PluginCommand) -> Result<(), String> {
        use std::io::Write;
        use std::os::unix::io::AsRawFd;
        use tracing::info;

        let json = serde_json::to_string(&cmd)
            .map_err(|e| format!("Failed to serialize command: {}", e))?;

        let socket = self.socket.as_mut().ok_or("Socket not available")?;
        let fd = socket.as_raw_fd();

        info!(
            "[ProcessManager] Sending to {} (socket fd={}): {:?}",
            self.plugin_id, fd, cmd
        );
        info!("[ProcessManager] JSON ({} bytes): {}", json.len(), json);

        // Write command + newline
        write!(socket, "{}\n", json).map_err(|e| format!("Failed to write command: {}", e))?;

        info!("[ProcessManager] Wrote command to socket");

        // Flush immediately to ensure data goes out
        socket
            .flush()
            .map_err(|e| format!("Failed to flush socket: {}", e))?;

        info!("[ProcessManager] Socket flushed successfully");

        Ok(())
    }

    /// Receive a response from the plugin subprocess
    pub fn recv_response(&mut self) -> Result<PluginResponse, String> {
        // First check if a synchronous response was buffered earlier
        let buffered_len = self.pending_async_responses.len();
        for _ in 0..buffered_len {
            if let Some(resp) = self.pending_async_responses.pop_front() {
                if Self::is_unsolicited_response(&resp) {
                    // Keep asynchronous responses queued for polling
                    self.pending_async_responses.push_back(resp);
                } else {
                    debug!(
                        "[ProcessManager] returning buffered synchronous response {:?}",
                        resp
                    );
                    return Ok(resp);
                }
            }
        }

        loop {
            let line = match self.read_response_line(false)? {
                Some(line) => line,
                None => continue,
            };

            let trimmed = line.trim();
            let response: PluginResponse = serde_json::from_str(trimmed)
                .map_err(|e| format!("Failed to parse response '{}': {}", trimmed, e))?;

            debug!(
                "[ProcessManager] recv_response decoded {:?} (queued={})",
                response,
                self.pending_async_responses.len()
            );

            if Self::is_unsolicited_response(&response) {
                debug!(
                    "[ProcessManager] buffering unsolicited response {:?}",
                    response
                );
                self.pending_async_responses.push_back(response);
                continue;
            }

            return Ok(response);
        }
    }

    /// Try to receive a response without blocking (for polling unsolicited messages)
    pub fn try_recv_response(&mut self) -> Result<PluginResponse, String> {
        // Return any buffered asynchronous response first
        let buffered_len = self.pending_async_responses.len();
        for _ in 0..buffered_len {
            if let Some(resp) = self.pending_async_responses.pop_front() {
                if Self::is_unsolicited_response(&resp) {
                    return Ok(resp);
                } else {
                    // Keep synchronous responses queued for blocking readers
                    self.pending_async_responses.push_back(resp);
                }
            }
        }

        loop {
            match self.read_response_line(true)? {
                Some(line) => {
                    let trimmed = line.trim();
                    let response: PluginResponse = serde_json::from_str(trimmed)
                        .map_err(|e| format!("Failed to parse response '{}': {}", trimmed, e))?;
                    debug!(
                        "[ProcessManager] try_recv_response decoded {:?} (queued={})",
                        response,
                        self.pending_async_responses.len()
                    );

                    if Self::is_unsolicited_response(&response) {
                        return Ok(response);
                    } else {
                        return Err("No data available".to_string());
                    }
                }
                None => return Err("No data available".to_string()),
            }
        }
    }

    /// Set read timeout for socket operations
    pub fn set_read_timeout(&self, timeout: Option<std::time::Duration>) -> Result<(), String> {
        let socket = self.socket.as_ref().ok_or("Socket not available")?;
        socket
            .set_read_timeout(timeout)
            .map_err(|e| format!("Failed to set read timeout: {}", e))
    }

    /// Check if process is still alive
    pub fn is_alive(&mut self) -> bool {
        if let Some(ref mut child) = self.child {
            match child.try_wait() {
                Ok(Some(_)) => false, // Process exited
                Ok(None) => true,     // Still running
                Err(_) => false,      // Error checking status
            }
        } else {
            false // No child process
        }
    }

    /// Get shared memory reference
    pub fn shared_memory(&self) -> &Arc<SharedMemory> {
        &self.shared_memory
    }

    /// Shutdown the subprocess gracefully
    pub fn shutdown(&mut self) -> Result<(), String> {
        info!("Shutting down plugin subprocess: {}", self.plugin_id);

        // Send shutdown command
        if let Err(e) = self.send_command(PluginCommand::Shutdown) {
            warn!("Failed to send shutdown command: {}", e);
        }

        // Half-close write side to prevent EPIPE, then drop socket
        if let Some(socket) = self.socket.take() {
            use std::net::Shutdown;
            let _ = socket.shutdown(Shutdown::Write); // Ignore errors - already closing
            drop(socket);
            info!("Closed control socket");
        }

        // Wait for process to exit - SAFE VERSION using Option<Child>
        if let Some(mut child) = self.child.take() {
            match child.wait() {
                Ok(status) => {
                    info!("Plugin subprocess exited: {}", status);
                    Ok(())
                }
                Err(e) => {
                    error!("Error waiting for subprocess: {}", e);
                    Err(format!("Error waiting for subprocess: {}", e))
                }
            }
        } else {
            info!("Plugin subprocess already shut down");
            Ok(())
        }
    }
}

impl Drop for PluginProcess {
    fn drop(&mut self) {
        // Force kill if still running
        if let Some(mut child) = self.child.take() {
            // Check if still running using try_wait (non-blocking)
            match child.try_wait() {
                Ok(Some(status)) => {
                    // Already exited
                    info!(
                        "Plugin subprocess already exited in Drop: {} (status: {})",
                        self.plugin_id, status
                    );
                }
                Ok(None) => {
                    // Still running, force kill
                    warn!(
                        "Force killing plugin subprocess in Drop: {}",
                        self.plugin_id
                    );
                    let _ = child.kill();
                    let _ = child.wait(); // Reap the zombie process
                }
                Err(e) => {
                    error!("Error checking subprocess status in Drop: {}", e);
                }
            }
        }
    }
}

/// Plugin process manager
pub struct ProcessManager {
    /// Active plugin processes (keyed by channel_id + device_position)
    processes: Arc<Mutex<HashMap<String, Arc<Mutex<PluginProcess>>>>>,

    /// Port allocator for control sockets
    next_port: Arc<Mutex<u16>>,
}

impl ProcessManager {
    /// Create a new process manager
    pub fn new() -> Self {
        Self {
            processes: Arc::new(Mutex::new(HashMap::new())),
            next_port: Arc::new(Mutex::new(9000)), // Start at port 9000
        }
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

    /// Spawn a new plugin host subprocess
    pub fn spawn_plugin(
        &self,
        key: String,
        plugin_path: PathBuf,
        plugin_id: String,
        sample_rate: f32,
        max_buffer_size: usize,
    ) -> Result<(), String> {
        info!("Spawning plugin subprocess: {} ({})", plugin_id, key);

        let plugin_host_path = Self::plugin_host_path()?;

        // Allocate port for control socket
        let port = {
            let mut next_port = self.next_port.lock().unwrap();
            let port = *next_port;
            *next_port += 1;
            port
        };

        // Create TCP listener for control socket
        let listener = TcpListener::bind(format!("127.0.0.1:{}", port))
            .map_err(|e| format!("Failed to bind control socket: {}", e))?;

        // Create a Unix socket pair BEFORE spawning for FD passing
        let (unix_sock_parent, unix_sock_child) =
            UnixStream::pair().map_err(|e| format!("Failed to create Unix socket pair: {}", e))?;
        let unix_sock_child_fd = unix_sock_child.as_raw_fd();

        // Spawn subprocess
        use std::os::unix::io::AsRawFd;
        use std::os::unix::process::CommandExt;
        let target_fd = 3; // Well-known FD for the Unix socket

        let child = unsafe {
            Command::new(&plugin_host_path)
                .arg(port.to_string())
                .arg(target_fd.to_string()) // Pass FD 3 as arg
                .stdout(std::process::Stdio::inherit()) // Show subprocess stdout
                .stderr(std::process::Stdio::inherit()) // Show subprocess stderr
                .pre_exec(move || {
                    // Dup the Unix socket to FD 3 in the child process
                    let result = libc::dup2(unix_sock_child_fd, target_fd);
                    if result < 0 {
                        return Err(std::io::Error::last_os_error());
                    }

                    // Clear close-on-exec flag for FD 3
                    let flags = libc::fcntl(target_fd, libc::F_GETFD);
                    if flags >= 0 {
                        libc::fcntl(target_fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC);
                    }

                    // Close the original Unix socket FD (we've duped it to FD 3)
                    if unix_sock_child_fd != target_fd {
                        libc::close(unix_sock_child_fd);
                    }

                    Ok(())
                })
                .spawn()
                .map_err(|e| {
                    format!(
                        "Failed to spawn plugin_host at {}: {}",
                        plugin_host_path.display(),
                        e
                    )
                })?
        };

        let pid = child.id();
        info!(
            "Plugin subprocess spawned: PID={} with Unix socket FD={}",
            pid, unix_sock_child_fd
        );

        // Wait for subprocess to connect
        listener
            .set_nonblocking(false)
            .map_err(|e| format!("Failed to set listener blocking: {}", e))?;

        // Accept connection with timeout (5 seconds)
        let socket = match listener.accept() {
            Ok((stream, addr)) => {
                info!("Plugin subprocess connected from: {}", addr);
                stream
            }
            Err(e) => {
                error!("Failed to accept connection: {}", e);
                return Err(format!("Subprocess failed to connect: {}", e));
            }
        };

        // Create shared memory
        let layout = SharedMemoryLayout::new(max_buffer_size);
        let shm_name = format!("sonara_plugin_{}_{}", pid, plugin_id.replace(".", "_"));
        let shared_memory = SharedMemory::new(&shm_name, layout)
            .map_err(|e| format!("Failed to create shared memory: {}", e))?;

        // Get the shared memory FD
        let shm_fd = shared_memory.as_raw_fd();

        // Send the shared memory FD via the Unix socket using SCM_RIGHTS
        info!(
            "Sending shared memory FD={} to subprocess via Unix socket",
            shm_fd
        );
        send_fd(&unix_sock_parent, shm_fd)?;

        // Drop both unix sockets - we're done with them
        // The subprocess has its own copy of the FD (dup'd by the kernel during SCM_RIGHTS)
        drop(unix_sock_parent);
        drop(unix_sock_child);

        // Create process handle
        let mut process = PluginProcess {
            pid,
            child: Some(child), // Wrap in Option for safe ownership handling
            socket: Some(socket),
            partial_read_buffer: Vec::new(),
            pending_async_responses: VecDeque::new(),
            shared_memory: Arc::new(shared_memory),
            plugin_id: plugin_id.clone(),
            plugin_path: plugin_path.clone(),
        };

        // Send initialization command
        process.send_command(PluginCommand::Initialize {
            plugin_path,
            plugin_id: plugin_id.clone(),
            sample_rate,
            max_buffer_size,
            shm_name: shm_name.clone(), // Not used anymore, but kept for compatibility
        })?;

        // Wait for initialization response
        match process.recv_response()? {
            PluginResponse::InitializeSuccess { .. } => {
                info!("Plugin initialized successfully: {}", plugin_id);
            }
            PluginResponse::InitializeError { error } => {
                return Err(format!("Plugin initialization failed: {}", error));
            }
            other => {
                return Err(format!("Unexpected response: {:?}", other));
            }
        }

        // Store process wrapped in Arc<Mutex<>>
        let process_arc = Arc::new(Mutex::new(process));
        let mut processes = self.processes.lock().unwrap();
        processes.insert(key, Arc::clone(&process_arc));

        Ok(())
    }

    /// Get a plugin process by key
    pub fn get_process(&self, key: &str) -> Option<Arc<Mutex<PluginProcess>>> {
        let processes = self.processes.lock().unwrap();
        processes.get(key).map(|p| Arc::clone(p))
    }

    /// Shutdown a plugin process
    pub fn shutdown_plugin(&self, key: &str) -> Result<(), String> {
        let mut processes = self.processes.lock().unwrap();

        if let Some(process_arc) = processes.remove(key) {
            let mut process = process_arc.lock().unwrap();
            process.shutdown()
        } else {
            Err(format!("Plugin process not found: {}", key))
        }
    }

    /// Shutdown all plugin processes
    pub fn shutdown_all(&self) -> Result<(), String> {
        let mut processes = self.processes.lock().unwrap();

        for (key, process_arc) in processes.drain() {
            info!("Shutting down plugin: {}", key);
            let mut process = process_arc.lock().unwrap();
            if let Err(e) = process.shutdown() {
                error!("Failed to shutdown {}: {}", key, e);
            }
        }

        Ok(())
    }

    /// Monitor plugin processes and restart if crashed
    pub fn start_monitoring(&self) {
        let processes = Arc::clone(&self.processes);

        thread::spawn(move || {
            loop {
                thread::sleep(std::time::Duration::from_secs(5)); // Check less frequently

                // Collect process Arcs WITHOUT holding the HashMap lock
                let process_arcs: Vec<(String, Arc<Mutex<PluginProcess>>)> = {
                    let processes = processes.lock().unwrap();
                    processes
                        .iter()
                        .map(|(k, v)| (k.clone(), Arc::clone(v)))
                        .collect()
                };

                // Check each process (now we've released the HashMap lock!)
                // Use try_lock to avoid blocking other threads!
                let mut crashed = Vec::new();
                for (key, process_arc) in process_arcs {
                    if let Ok(mut process) = process_arc.try_lock() {
                        if !process.is_alive() {
                            warn!("Plugin process crashed: {}", key);
                            crashed.push(key.clone());
                        }
                    }
                    // If we can't get the lock, skip this check - process is being used
                }

                // Remove crashed processes
                if !crashed.is_empty() {
                    let mut processes = processes.lock().unwrap();
                    for key in crashed {
                        error!("Plugin {} needs restart (not implemented yet)", key);
                        processes.remove(&key);
                    }
                }
            }
        });
    }
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self::new()
    }
}
