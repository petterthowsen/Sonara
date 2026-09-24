//! Framing for the plugin host control channel (a Unix socketpair).
//!
//! A frame is a little-endian `u32` payload length followed by the bincode-encoded message.
//! File descriptors travel with a frame as `SCM_RIGHTS`, attached to its first bytes, so every
//! read goes through `recvmsg` and must not read past the frame it is on: no read-ahead buffering.
//!
//! Set `SONARA_IPC_TRACE=1` to log every message sent and received, decoded as `Debug`.

use nix::errno::Errno;
use nix::sys::socket::{recvmsg, sendmsg, ControlMessage, ControlMessageOwned, MsgFlags};
use serde::de::DeserializeOwned;
use serde::Serialize;
use std::fmt::Debug;
use std::io::{self, IoSlice, IoSliceMut};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::net::UnixStream;
use std::sync::OnceLock;
use tracing::info;

/// Largest payload accepted. Plugin state blobs are the biggest messages.
const MAX_FRAME_LEN: usize = 256 << 20;

/// Most file descriptors one frame can carry.
const MAX_FDS: usize = 4;

/// Whether `SONARA_IPC_TRACE=1` is set. Read once.
fn trace_enabled() -> bool {
    static TRACE: OnceLock<bool> = OnceLock::new();
    *TRACE.get_or_init(|| std::env::var("SONARA_IPC_TRACE").is_ok_and(|v| v == "1"))
}

/// Encode `msg` as one frame and send it, with `fds` attached. Blocks until it is all written.
pub fn send_frame<T: Serialize + Debug>(
    socket: &UnixStream,
    msg: &T,
    fds: &[RawFd],
) -> io::Result<()> {
    let payload_len = bincode::serialized_size(msg).map_err(invalid_data)? as usize;
    if payload_len > MAX_FRAME_LEN {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("IPC frame of {payload_len} bytes exceeds the {MAX_FRAME_LEN} byte limit"),
        ));
    }
    let mut frame = Vec::with_capacity(4 + payload_len);
    frame.extend_from_slice(&(payload_len as u32).to_le_bytes());
    bincode::serialize_into(&mut frame, msg).map_err(invalid_data)?;

    if trace_enabled() {
        info!(
            "[ipc] send ({} bytes, {} fds): {:?}",
            payload_len,
            fds.len(),
            msg
        );
    }

    let rights = [ControlMessage::ScmRights(fds)];
    let mut sent = 0;
    while sent < frame.len() {
        // Attach the descriptors to the first chunk only.
        let cmsgs: &[ControlMessage] = if sent == 0 && !fds.is_empty() {
            &rights
        } else {
            &[]
        };
        let iov = [IoSlice::new(&frame[sent..])];
        match sendmsg::<()>(
            socket.as_raw_fd(),
            &iov,
            cmsgs,
            MsgFlags::MSG_NOSIGNAL,
            None,
        ) {
            Ok(n) => sent += n,
            Err(Errno::EINTR) => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(())
}

/// Receive one frame and decode it. Returns `Ok(None)` when the peer closed the socket cleanly
/// between frames. Blocks until a whole frame has arrived.
pub fn recv_frame<T: DeserializeOwned + Debug>(
    socket: &UnixStream,
) -> io::Result<Option<(T, Vec<OwnedFd>)>> {
    let mut fds = Vec::new();

    let mut header = [0u8; 4];
    if !recv_exact(socket, &mut header, &mut fds, true)? {
        return Ok(None);
    }
    let payload_len = u32::from_le_bytes(header) as usize;
    if payload_len > MAX_FRAME_LEN {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("IPC frame of {payload_len} bytes exceeds the {MAX_FRAME_LEN} byte limit"),
        ));
    }

    let mut payload = vec![0u8; payload_len];
    recv_exact(socket, &mut payload, &mut fds, false)?;
    let msg: T = bincode::deserialize(&payload).map_err(invalid_data)?;

    if trace_enabled() {
        info!(
            "[ipc] recv ({} bytes, {} fds): {:?}",
            payload_len,
            fds.len(),
            msg
        );
    }
    Ok(Some((msg, fds)))
}

/// Fill `buf` from the socket, collecting any descriptors that arrive. Returns false on a clean
/// end of stream before the first byte when `eof_ok`; an end of stream anywhere else is an error.
fn recv_exact(
    socket: &UnixStream,
    buf: &mut [u8],
    fds: &mut Vec<OwnedFd>,
    eof_ok: bool,
) -> io::Result<bool> {
    let mut filled = 0;
    let mut cmsg_buffer = nix::cmsg_space!([RawFd; MAX_FDS]);
    while filled < buf.len() {
        let mut iov = [IoSliceMut::new(&mut buf[filled..])];
        let (bytes, truncated) = match recvmsg::<()>(
            socket.as_raw_fd(),
            &mut iov,
            Some(&mut cmsg_buffer),
            MsgFlags::MSG_CMSG_CLOEXEC,
        ) {
            Ok(msg) => {
                for cmsg in msg.cmsgs()? {
                    if let ControlMessageOwned::ScmRights(received) = cmsg {
                        // SAFETY: the kernel just installed these descriptors in this process and
                        // nothing else refers to them.
                        fds.extend(
                            received
                                .into_iter()
                                .map(|fd| unsafe { OwnedFd::from_raw_fd(fd) }),
                        );
                    }
                }
                (msg.bytes, msg.flags.contains(MsgFlags::MSG_CTRUNC))
            }
            Err(Errno::EINTR) => continue,
            Err(e) => return Err(e.into()),
        };
        if truncated {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("IPC frame carried more than {MAX_FDS} file descriptors"),
            ));
        }
        if bytes == 0 {
            if filled == 0 && eof_ok {
                return Ok(false);
            }
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        filled += bytes;
    }
    Ok(true)
}

fn invalid_data(e: bincode::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, e)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::ipc::protocol::{HostRequest, PluginCommand};
    use std::io::{Read, Seek, SeekFrom, Write};
    use std::path::PathBuf;

    fn request(request_id: u32, command: PluginCommand) -> HostRequest {
        HostRequest {
            instance_id: 7,
            request_id,
            command,
        }
    }

    #[test]
    fn frames_round_trip_in_order() {
        let (a, b) = UnixStream::pair().unwrap();
        send_frame(
            &a,
            &request(
                1,
                PluginCommand::Activate {
                    sample_rate: 48000.0,
                },
            ),
            &[],
        )
        .unwrap();
        send_frame(
            &a,
            &request(
                2,
                PluginCommand::SetParameter {
                    param_id: 3,
                    value: 0.25,
                },
            ),
            &[],
        )
        .unwrap();

        let (first, fds) = recv_frame::<HostRequest>(&b).unwrap().unwrap();
        assert!(fds.is_empty());
        assert_eq!((first.instance_id, first.request_id), (7, 1));
        assert!(matches!(
            first.command,
            PluginCommand::Activate { sample_rate } if sample_rate == 48000.0
        ));

        let (second, _) = recv_frame::<HostRequest>(&b).unwrap().unwrap();
        assert!(matches!(
            second.command,
            PluginCommand::SetParameter { param_id: 3, value } if value == 0.25
        ));
    }

    #[test]
    fn large_frame_round_trips() {
        let (a, b) = UnixStream::pair().unwrap();
        // Bigger than the socket buffer, so it is written and read in several chunks.
        let state: Vec<u8> = (0..4_000_000u32).map(|i| i as u8).collect();
        let sender = std::thread::spawn(move || {
            send_frame(&a, &request(9, PluginCommand::LoadState { state }), &[]).unwrap();
        });
        let (msg, _) = recv_frame::<HostRequest>(&b).unwrap().unwrap();
        sender.join().unwrap();
        match msg.command {
            PluginCommand::LoadState { state } => {
                assert_eq!(state.len(), 4_000_000);
                assert_eq!(state[1_000_001], (1_000_001u32) as u8);
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn file_descriptor_travels_with_its_frame() {
        let (a, b) = UnixStream::pair().unwrap();
        let mut file = tempfile::tempfile().unwrap();
        file.write_all(b"shared").unwrap();

        let init = PluginCommand::Initialize {
            plugin_path: PathBuf::from("/tmp/x.clap"),
            plugin_id: "x".to_string(),
            sample_rate: 48000.0,
            max_buffer_size: 1024,
        };
        send_frame(&a, &request(1, init), &[file.as_raw_fd()]).unwrap();
        send_frame(
            &a,
            &request(
                2,
                PluginCommand::Activate {
                    sample_rate: 48000.0,
                },
            ),
            &[],
        )
        .unwrap();

        let (_, mut fds) = recv_frame::<HostRequest>(&b).unwrap().unwrap();
        assert_eq!(fds.len(), 1);
        let mut received = std::fs::File::from(fds.remove(0));
        received.seek(SeekFrom::Start(0)).unwrap();
        let mut contents = String::new();
        received.read_to_string(&mut contents).unwrap();
        assert_eq!(contents, "shared");

        // The descriptor doesn't leak into the next frame, and the stream stays aligned.
        let (next, fds) = recv_frame::<HostRequest>(&b).unwrap().unwrap();
        assert!(fds.is_empty());
        assert_eq!(next.request_id, 2);
    }

    #[test]
    fn clean_close_between_frames_is_none() {
        let (a, b) = UnixStream::pair().unwrap();
        drop(a);
        assert!(recv_frame::<HostRequest>(&b).unwrap().is_none());
    }

    #[test]
    fn close_mid_frame_is_an_error() {
        let (mut a, b) = UnixStream::pair().unwrap();
        a.write_all(&100u32.to_le_bytes()).unwrap();
        a.write_all(&[1, 2, 3]).unwrap();
        drop(a);
        let err = recv_frame::<HostRequest>(&b).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
    }
}
