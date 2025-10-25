# IO Safety Violation Bug Analysis

**Date**: 2025-10-25
**Error**: `fatal runtime error: IO Safety violation: owned file descriptor already closed, aborting`
**Subsystem**: Plugin subprocess hosting system (IPC communication)

---

## Executive Summary

The IO safety violation occurs during plugin shutdown when Rust's runtime detects that an `OwnedFd` is being dropped for a file descriptor (FD) that has already been closed. This happens in the subprocess or engine process after sending/receiving the Shutdown command. The root cause is likely a combination of unsafe memory operations, complex FD lifecycle management, and race conditions during cleanup.

---

## Error Context

### Timeline (from logs)
```
2025-10-25T00:32:06.365071Z  INFO engine: Shutting down plugin subprocess
2025-10-25T00:32:06.365093Z  INFO engine: Sending Shutdown command (socket fd=17)
2025-10-25T00:32:06.365212Z  INFO engine: Closed control socket
2025-10-25T00:32:06.365694Z  INFO subprocess: Raw data received (10 bytes): '"Shutdown"'
fatal runtime error: IO Safety violation: owned file descriptor already closed, aborting
```

### Key Observation
The error occurs in the **subprocess** (based on stderr output) between:
1. Receiving and parsing the Shutdown command
2. Calling `libc::_exit(0)` to terminate

The subprocess uses `_exit(0)` specifically to avoid normal Drop cleanup, yet the error still occurs, suggesting the violation happens **before** the exit call.

---

## Critical Code Paths and File Descriptor Lifecycle

### 1. Shared Memory FD Transfer (SCM_RIGHTS)

**Engine Side** (`process_manager.rs`):
```rust
// Line 301: Create Unix socket pair for FD passing
let (unix_sock_parent, unix_sock_child) = UnixStream::pair()?;

// Line 360-363: Create shared memory with OwnedFd
let shared_memory = SharedMemory::new(&shm_name, layout)?;
// ↳ Contains PlatformSharedMemory { fd: OwnedFd, ... }

// Line 366: Get raw FD (borrows, doesn't transfer ownership)
let shm_fd = shared_memory.as_raw_fd();

// Line 370: Send FD via SCM_RIGHTS (kernel dups the FD)
send_fd(&unix_sock_parent, shm_fd)?;

// Line 372-375: Drop Unix sockets (POTENTIAL ISSUE #1)
drop(unix_sock_parent);
drop(unix_sock_child);  // Child process has dup'd copy at FD 3

// Line 382: Store shared_memory in Arc<Mutex<PluginProcess>>
// The OwnedFd remains alive until plugin shutdown
```

**Subprocess Side** (`plugin_host.rs`):
```rust
// Line 779: Receive shared memory FD
let shm_fd = recv_fd_from_socket_raw(unix_socket_fd)?;

// Inside recv_fd_from_socket_raw (lines 275-305):
let msg = recvmsg(socket_fd, &mut iov, Some(&mut cmsg_space), ...)?;
for cmsg in msg.cmsgs()? {
    if let ControlMessageOwned::ScmRights(fds) = cmsg {
        let fd = fds[0];
        // Line 289-295: Duplicate received FD BEFORE ControlMessageOwned drops
        let duped_fd = libc::dup(fd);
        // ControlMessageOwned will close 'fd' when it drops
        return Ok(duped_fd);  // Return our dup'd copy
    }
}

// Line 785-788: Explicitly close Unix socket FD 3 (POTENTIAL ISSUE #2)
unsafe { libc::close(unix_socket_fd); }

// Line 790: Wrap duped FD in OwnedFd via SharedMemory::from_fd
let shared_memory = SharedMemory::from_fd(shm_fd, layout)?;
// ↳ platform_shm.rs:84: OwnedFd::from_raw_fd(fd)
```

### 2. Subprocess Shutdown Sequence

**Engine Side** (`process_manager.rs:200-240`):
```rust
pub fn shutdown(&mut self) -> Result<(), String> {
    // Send shutdown command
    self.send_command(PluginCommand::Shutdown)?;

    // Line 209-214: Close TCP control socket
    if let Some(socket) = self.socket.take() {
        socket.shutdown(Shutdown::Write)?;
        drop(socket);  // FD closed here
    }

    // Line 217-224: CRITICAL BUG - Creates zeroed Child struct
    let wait_result = thread::spawn({
        let mut child = std::mem::replace(&mut self.child, unsafe {
            std::mem::zeroed()  // ← DANGEROUS! Creates invalid Child with zeroed FDs
        });
        move || child.wait()
    }).join();
}
```

**Subprocess Side** (`plugin_host.rs:582-586`):
```rust
// Check for shutdown BEFORE logging to avoid IO safety issues
if matches!(cmd, PluginCommand::Shutdown) {
    // Exit immediately using libc::_exit without any logging or drops
    unsafe { libc::_exit(0); }  // ← Should prevent Drop from running
}
```

### 3. Plugin Process Drop Implementation

**`process_manager.rs:243-250`:**
```rust
impl Drop for PluginProcess {
    fn drop(&mut self) {
        if self.is_alive() {
            warn!("Force killing plugin subprocess");
            let _ = self.child.kill();  // ← Operates on potentially zeroed Child!
        }
    }
}
```

---

## Identified Issues (Ranked by Severity)

### 🔴 CRITICAL: Unsafe `std::mem::zeroed::<Child>()` Usage

**Location**: `process_manager.rs:218-222`

**Problem**:
```rust
let mut child = std::mem::replace(&mut self.child, unsafe {
    std::mem::zeroed()  // Creates Child with all bytes = 0
});
```

This creates a `Child` struct with:
- Zeroed file descriptors (invalid FD numbers, potentially FD 0)
- Zeroed internal state
- Invalid handles for stdin/stdout/stderr

**When Unsafe**:
1. If the thread panics or returns an error, the zeroed `Child` remains in `self.child`
2. When `PluginProcess` drops (line 243-250), it calls `is_alive()` and potentially `kill()` on the zeroed `Child`
3. The zeroed `Child` may try to close FD 0 or other invalid/already-closed FDs in its Drop impl
4. **This triggers the IO safety violation**: "owned file descriptor already closed"

**Why This Happens**:
- `std::process::Child` contains `OwnedFd` handles for stdin/stdout/stderr
- Zeroing these creates "owned" FDs pointing to FD 0 (or other invalid values)
- When the zeroed `Child` drops, Rust tries to close these FDs
- If FD 0 is already closed or invalid, we get: `IO Safety violation`

**Evidence**:
The error occurs in the engine process after "Closed control socket" is logged, suggesting the zeroed Child is being dropped during cleanup.

---

### 🟠 HIGH: Unix Socket FD Double-Close Potential

**Location**: `plugin_host.rs:785-788`

**Problem**:
```rust
// CRITICAL: Close the Unix socket FD immediately
unsafe {
    libc::close(unix_socket_fd);  // Explicitly closes FD 3
}
```

After this explicit close, FD 3 becomes available for reuse. If:
1. A new file/socket is opened and gets FD 3
2. Something still has a reference to "the Unix socket at FD 3" and tries to close it
3. We'd close the wrong FD or get a double-close error

**However**: Code review shows `unix_socket_fd` is only used once (line 779) before being closed, so this is less likely unless there's a race condition.

---

### 🟠 HIGH: Shared Memory FD Lifecycle Complexity

**Location**: Multiple files (`platform_shm.rs`, `shared_memory.rs`, `process_manager.rs`)

**Problem**: The shared memory FD undergoes multiple ownership transfers:

1. **Engine creates**: `PlatformSharedMemory::new()` → `OwnedFd::from_raw_fd(memfd_create())`
2. **Engine sends**: `send_fd()` via SCM_RIGHTS → Kernel dups FD for subprocess
3. **Subprocess receives**: `recvmsg()` → `ControlMessageOwned::ScmRights` owns received FD
4. **Subprocess dups**: `libc::dup()` → Creates independent copy before ControlMessageOwned drops
5. **Subprocess wraps**: `OwnedFd::from_raw_fd(duped_fd)` → New ownership in subprocess

**Risk Points**:
- If the dup at step 4 fails, the original FD gets closed by ControlMessageOwned, but we might still try to use it
- If ControlMessageOwned closes the FD before we dup it (race condition), we'd dup a closed FD
- If the FD is closed externally while OwnedFd still owns it, we get IO safety violation

**Code Review**: The dup happens at `plugin_host.rs:289-295`, which should occur before ControlMessageOwned drops at line 302. This appears correct but is timing-sensitive.

---

### 🟡 MEDIUM: Process Cleanup Race Condition

**Scenario**:
1. Engine sends Shutdown command
2. Engine closes TCP control socket (process_manager.rs:209-214)
3. Subprocess receives Shutdown and calls `_exit(0)` (plugin_host.rs:585)
4. Engine waits for subprocess to exit (process_manager.rs:217-229)
5. **Race**: Engine's PluginProcess drops while subprocess is still exiting

**If subprocess hasn't fully exited**:
- Shared memory FD is still mapped in subprocess
- Engine drops `shared_memory` Arc → `PlatformSharedMemory` drops → `OwnedFd` drops → closes FD
- Subprocess tries to unmap or access memory → error

**However**: The subprocess uses `_exit(0)`, which should prevent Drop from running, so this is less likely.

---

### 🟡 MEDIUM: TCP Control Socket Lifecycle

**Location**: `process_manager.rs:99-118`, `plugin_host.rs:539-744`

The TCP socket is:
- Wrapped in `Option<TcpStream>` in PluginProcess (line 30)
- Taken and dropped during shutdown (line 209-214)
- Used for non-blocking I/O in subprocess (line 541)

**Potential Issue**: If the socket is closed on one end while the other end is performing I/O, we might get unexpected FD behavior. However, TcpStream is properly wrapped and shouldn't cause IO safety violations.

---

## Root Cause Analysis

### Most Likely Cause: `std::mem::zeroed::<Child>()`

The error occurs **in the subprocess** based on the stderr output. However, the `std::mem::zeroed` issue is in the **engine process**. Let me reconsider...

Actually, looking at the logs again:
```
2025-10-25T00:32:06.365212Z  INFO engine::audio::ipc::process_manager: Closed control socket
2025-10-25T00:32:06.366831Z  INFO engine::audio::ipc::process_manager: Plugin subprocess exited: exit status: 0
```

The subprocess **successfully exits** with status 0. So the error must happen **after** the subprocess exits, in the **engine process** during cleanup!

### Revised Theory:

1. Subprocess receives Shutdown, calls `_exit(0)`, exits cleanly (exit status 0)
2. Engine's `wait_result` thread completes (line 217-229)
3. Control returns from `shutdown()` method
4. Engine's `shutdown_plugin()` drops the `PluginProcess` (via Arc)
5. **`PluginProcess::drop()` is called** (line 243-250)
6. `is_alive()` returns false (subprocess already exited)
7. The **zeroed `Child`** is still in `self.child`
8. When `PluginProcess` goes out of scope, the zeroed `Child` drops
9. **Zeroed `Child` tries to close invalid FDs** → IO safety violation!

This explains why the error happens **after** the subprocess exits successfully.

---

## Recommended Fixes

### 1. Fix the `std::mem::zeroed` Issue (CRITICAL)

**Replace** `process_manager.rs:200-240`:

```rust
pub fn shutdown(&mut self) -> Result<(), String> {
    info!("Shutting down plugin subprocess: {}", self.plugin_id);

    // Send shutdown command
    if let Err(e) = self.send_command(PluginCommand::Shutdown) {
        warn!("Failed to send shutdown command: {}", e);
    }

    // Close socket
    if let Some(socket) = self.socket.take() {
        use std::net::Shutdown;
        let _ = socket.shutdown(Shutdown::Write);
        drop(socket);
        info!("Closed control socket");
    }

    // Wait for process to exit - SAFE VERSION
    // Take ownership of child to prevent Drop issues
    // Use Option<Child> to avoid unsafe zeroing
    if let Ok(status) = self.child.wait() {
        info!("Plugin subprocess exited: {}", status);
        Ok(())
    } else {
        Err("Failed to wait for subprocess".to_string())
    }
}
```

**Better**: Change `PluginProcess` struct to use `Option<Child>`:

```rust
pub struct PluginProcess {
    pub pid: u32,
    child: Option<Child>,  // ← Use Option instead of Child
    socket: Option<TcpStream>,
    shared_memory: Arc<SharedMemory>,
    plugin_id: String,
    plugin_path: PathBuf,
}
```

Then update shutdown:
```rust
pub fn shutdown(&mut self) -> Result<(), String> {
    // ... send shutdown, close socket ...

    if let Some(mut child) = self.child.take() {
        match child.wait() {
            Ok(status) => {
                info!("Plugin subprocess exited: {}", status);
                Ok(())
            }
            Err(e) => Err(format!("Error waiting for subprocess: {}", e))
        }
    } else {
        Ok(()) // Already shut down
    }
}
```

And update Drop:
```rust
impl Drop for PluginProcess {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            if let Ok(None) = child.try_wait() {
                // Still running, force kill
                warn!("Force killing plugin subprocess: {}", self.plugin_id);
                let _ = child.kill();
            }
        }
    }
}
```

---

### 2. Improve Unix Socket FD Handling

**Don't close the Unix socket FD manually** in the subprocess. Instead, let Rust manage it:

```rust
// Option A: Wrap in OwnedFd immediately (if you need to close it)
let unix_socket_owned = unsafe { OwnedFd::from_raw_fd(unix_socket_fd) };
let shm_fd = recv_fd_from_socket_raw(unix_socket_owned.as_raw_fd())?;
drop(unix_socket_owned);  // Proper RAII cleanup

// Option B: Don't close it at all - let OS clean up on exit
// (This is fine since we're exiting via _exit anyway)
```

---

### 3. Add Defensive FD Validation

**In `PlatformSharedMemory::from_fd`** (`platform_shm.rs:80-109`):

```rust
pub fn from_fd(fd: RawFd, size: usize) -> Result<Self, String> {
    info!("🗺️  Mapping shared memory from fd={} ({} bytes)", fd, size);

    // VALIDATE FD BEFORE WRAPPING IN OwnedFd
    // Check if FD is valid using fcntl
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        let err = std::io::Error::last_os_error();
        return Err(format!("Invalid FD {}: {}", fd, err));
    }

    // Wrap in OwnedFd - this takes ownership
    let owned_fd = unsafe { OwnedFd::from_raw_fd(fd) };

    // ... rest of function ...
}
```

---

### 4. Add Better Logging and Diagnostics

**Track FD lifecycle**:

```rust
// In platform_shm.rs Drop impl
impl Drop for PlatformSharedMemory {
    fn drop(&mut self) {
        let fd_num = self.fd.as_raw_fd();
        info!("🔍 Dropping PlatformSharedMemory with FD {}", fd_num);

        // CHECK IF FD IS STILL VALID before dropping
        let flags = unsafe { libc::fcntl(fd_num, libc::F_GETFD) };
        if flags < 0 {
            error!("⚠️  FD {} already invalid/closed before Drop!", fd_num);
        }

        // Unmap memory
        if let Err(e) = unsafe {
            munmap(...)
        } {
            error!("Failed to munmap: {}", e);
        }

        // OwnedFd will close the FD
        info!("✅ About to drop OwnedFd for FD {}", fd_num);
    }
}
```

---

### 5. Add Integration Tests

**Test subprocess shutdown**:

```rust
#[test]
fn test_plugin_shutdown_safety() {
    let manager = ProcessManager::new();

    // Spawn plugin
    manager.spawn_plugin(...)?;

    // Shutdown plugin
    manager.shutdown_plugin("test_key")?;

    // Verify no IO safety violations
    // (test should not panic)
}

#[test]
fn test_rapid_spawn_shutdown() {
    let manager = ProcessManager::new();

    // Spawn and shutdown 100 times rapidly
    for i in 0..100 {
        manager.spawn_plugin(format!("test_{}", i), ...)?;
        manager.shutdown_plugin(&format!("test_{}", i))?;
    }
}
```

---

## Additional Recommendations

### 1. Consider Using `pidfd` (Linux 5.3+)

Instead of `std::process::Child`, use `pidfd_open()` for safer process management:
- No risk of zeroed structs
- Better race condition handling
- Native support for waiting without threads

### 2. Use RAII Wrappers for All FDs

Create a consistent FD management pattern:
- All raw FDs should be wrapped in `OwnedFd` immediately after creation
- Never use `std::mem::zeroed` on types containing file descriptors
- Use `Option<T>` for optional ownership instead of unsafe tricks

### 3. Implement Graceful Shutdown Timeout

```rust
pub fn shutdown(&mut self) -> Result<(), String> {
    // Send shutdown
    self.send_command(PluginCommand::Shutdown)?;

    // Wait with timeout (5 seconds)
    let timeout = Duration::from_secs(5);
    let start = Instant::now();

    while start.elapsed() < timeout {
        match self.child.try_wait()? {
            Some(status) => {
                info!("Subprocess exited: {}", status);
                return Ok(());
            }
            None => thread::sleep(Duration::from_millis(100)),
        }
    }

    // Timeout - force kill
    warn!("Subprocess didn't exit, force killing");
    self.child.kill()?;
    Ok(())
}
```

---

## Testing Plan

1. **Unit Tests**: Test FD lifecycle in isolation
2. **Integration Tests**: Test full subprocess spawn/shutdown cycle
3. **Stress Tests**: Rapid spawn/shutdown to expose race conditions
4. **Valgrind/Sanitizers**: Run with AddressSanitizer and LeakSanitizer
5. **Manual Testing**: Use `lsof` to track FD leaks during shutdown

---

## Conclusion

The **primary root cause** is the unsafe `std::mem::zeroed::<Child>()` usage in `process_manager.rs:218-222`. This creates an invalid `Child` struct with zeroed file descriptors that, when dropped, attempts to close invalid or already-closed FDs, triggering Rust's IO safety violation.

**Immediate Action**: Replace `std::mem::zeroed()` with `Option<Child>` pattern throughout the codebase.

**Secondary Issues**: Unix socket FD management and shared memory FD lifecycle complexity add additional risk and should be addressed for long-term stability.

---

## References

- Rust IO Safety: https://doc.rust-lang.org/std/os/unix/io/index.html
- SCM_RIGHTS: https://man7.org/linux/man-pages/man3/cmsg.3.html
- OwnedFd Drop behavior: https://doc.rust-lang.org/std/os/unix/io/struct.OwnedFd.html
- Process management best practices: https://doc.rust-lang.org/std/process/struct.Child.html
