//! IPC utilities for Unix domain socket communication
//!
//! Provides low-level utilities for receiving file descriptors
//! via Unix domain sockets using SCM_RIGHTS.

use nix::sys::socket::{recvmsg, ControlMessageOwned, MsgFlags};
use nix::cmsg_space;
use std::io::IoSliceMut;
use tracing::info;

/// Receive a file descriptor from a Unix domain socket using raw FD
/// This avoids wrapping the socket in UnixStream which can cause IO safety issues
pub fn recv_fd_from_socket_raw(socket_fd: i32) -> Result<i32, String> {
    let mut data = [0u8; 1];
    let mut iov = [IoSliceMut::new(&mut data)];
    let mut cmsg_space = cmsg_space!([i32; 1]);

    let msg = recvmsg::<()>(
        socket_fd,
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
                // CRITICAL: Duplicate the FD immediately before ControlMessageOwned drops
                // ControlMessageOwned::ScmRights owns the FDs and will close them when dropped!
                info!("📨 Received FD={} via SCM_RIGHTS, duplicating it...", fd);
                let duped_fd = unsafe {
                    let dup = libc::dup(fd);
                    if dup < 0 {
                        return Err(format!(
                            "Failed to dup received FD: {}",
                            std::io::Error::last_os_error()
                        ));
                    }
                    dup
                };
                info!(
                    "✅ Duplicated FD {} -> {}, original will be closed by ControlMessageOwned",
                    fd, duped_fd
                );
                // Let the original FD be closed by ControlMessageOwned drop
                // We return our duplicated copy
                return Ok(duped_fd);
            }
        }
    }

    Err("No file descriptor received".to_string())
}
