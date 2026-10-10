use anyhow::{Context, Result};
use crossbeam::channel::{Receiver, Sender};
use rosc::{OscMessage, OscPacket, OscType};
use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use std::os::fd::AsRawFd;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tracing::{info, warn};

use super::audio_files::{PendingClip, PendingDevice};
use super::status;
use crate::audio::devices::DevicePath;
use crate::audio::io::AudioFileService;
use crate::audio::{AudioCommand, EngineStatus};
use crate::logging::LogWriters;
use crate::window_manager::WindowManager;

/// Kernel receive buffer requested for the OSC socket. Loading a kit sends several hundred
/// messages in one burst; the default (~200 KB, and datagrams are accounted at their full
/// buffer size) holds only a few hundred of them.
const RECV_BUFFER_BYTES: i32 = 4 * 1024 * 1024;

/// How long the receiver thread blocks in `recv_from` before it retries (a read timeout keeps
/// the thread from sitting in the syscall forever).
const RECV_POLL: Duration = Duration::from_millis(50);

/// Ask the kernel for a larger receive buffer and return the size it granted (Linux reports
/// double the request and caps it at `net.core.rmem_max`).
fn grow_recv_buffer(socket: &UdpSocket) -> Option<i32> {
    let fd = socket.as_raw_fd();
    let size = RECV_BUFFER_BYTES;
    // SAFETY: `fd` is a live socket owned by `socket`, and the option value is a plain i32.
    let set = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            &size as *const i32 as *const libc::c_void,
            std::mem::size_of::<i32>() as libc::socklen_t,
        )
    };
    if set != 0 {
        return None;
    }
    let mut granted: i32 = 0;
    let mut len = std::mem::size_of::<i32>() as libc::socklen_t;
    // SAFETY: as above; `granted` and `len` outlive the call.
    let got = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            &mut granted as *mut i32 as *mut libc::c_void,
            &mut len,
        )
    };
    (got == 0).then_some(granted)
}

/// Read datagrams off `socket` on a thread of their own and queue them in arrival order.
///
/// Handling a packet can be slow (sample loads, decode completions, plugin windows). If the
/// handler is also the thread that reads the socket, a burst from Godot overflows the kernel
/// buffer and the datagrams are dropped silently: a pad's `add_device` goes missing and every
/// later pad lands one slot too low. Reading here keeps the kernel buffer empty; the queue is
/// unbounded and the packets are small.
///
/// The thread ends on the first datagram after the returned receiver is dropped.
fn spawn_receiver(socket: UdpSocket) -> Result<Receiver<(Vec<u8>, SocketAddr)>> {
    // The flag is shared with the sending clones, which is fine: UDP sends don't block.
    socket.set_nonblocking(false)?;
    socket.set_read_timeout(Some(RECV_POLL))?;
    let (tx, rx) = crossbeam::channel::unbounded();
    thread::Builder::new()
        .name("osc-recv".into())
        .spawn(move || {
            let mut buf = [0u8; 2048];
            loop {
                match socket.recv_from(&mut buf) {
                    Ok((size, addr)) => {
                        if tx.send((buf[..size].to_vec(), addr)).is_err() {
                            break;
                        }
                    }
                    Err(e)
                        if matches!(
                            e.kind(),
                            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                        ) => {}
                    Err(e) => {
                        warn!("Error receiving OSC message: {}", e);
                        thread::sleep(Duration::from_millis(1));
                    }
                }
            }
        })
        .context("Failed to spawn OSC receiver thread")?;
    Ok(rx)
}

/// OSC server that receives messages from Godot UI and sends status updates
pub struct OscServer {
    pub(super) socket: UdpSocket,
    client_addr: Option<SocketAddr>,
    pub(super) client_port: u16,
    pub(super) audio_file_service: Arc<Mutex<AudioFileService>>,
    pub(super) pending_clip_loads: Arc<Mutex<HashMap<String, PendingClip>>>,
    pub(super) pending_device_loads: Arc<Mutex<HashMap<String, PendingDevice>>>,
}

impl OscServer {
    /// Create a new OSC server listening on the specified port
    pub fn new(port: u16, audio_file_service: Arc<Mutex<AudioFileService>>) -> Result<Self> {
        let addr = format!("127.0.0.1:{}", port);
        let socket =
            UdpSocket::bind(&addr).context(format!("Failed to bind OSC server to {}", addr))?;

        socket.set_nonblocking(true)?;

        info!("OSC server listening on {}", addr);

        Ok(Self {
            socket,
            client_addr: None,
            client_port: 7001, // Godot listens on 7001
            audio_file_service,
            pending_clip_loads: Arc::new(Mutex::new(HashMap::new())),
            pending_device_loads: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    /// Start the OSC server and process incoming messages
    pub fn run(
        mut self,
        command_tx: Sender<AudioCommand>,
        status_rx: Receiver<EngineStatus>,
        log_writers: LogWriters,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        match grow_recv_buffer(&self.socket) {
            Some(bytes) => info!("OSC receive buffer: {} KB", bytes / 1024),
            None => warn!("Could not enlarge the OSC receive buffer"),
        }
        let packets = spawn_receiver(self.socket.try_clone()?)?;

        // Tell Godot this is a new engine process so it can resync even if heartbeats never
        // timed out (a restart is often faster than HEARTBEAT_TIMEOUT_SEC).
        match self.send_message("/status/connected", vec![OscType::Int(1)]) {
            Ok(_) => info!("Sent /status/connected (engine ready)"),
            Err(e) => warn!("Failed to send /status/connected: {}", e),
        }

        // Channel for forwarding GUI events from status thread to main loop
        let (gui_event_tx, gui_event_rx) = std::sync::mpsc::channel();

        // Spawn status sender thread
        let socket_clone = self.socket.try_clone()?;
        let client_port = self.client_port;
        let decode_rate = self.audio_file_service.lock().unwrap().sample_rate_handle();
        status::spawn(
            socket_clone,
            client_port,
            decode_rate,
            status_rx,
            gui_event_tx,
        );

        // Main receive loop
        loop {
            // Check for GUI events
            while let Ok(event) = gui_event_rx.try_recv() {
                event.apply(window_manager);
            }

            // Check for AudioFileService events
            let events = {
                let service = self.audio_file_service.lock().unwrap();
                service.poll_events()
            };
            for event in events {
                self.handle_afs_event(event, &command_tx);
            }

            // Check for window close events (user clicked X)
            while let Ok(process_key) = window_manager.close_event_rx.try_recv() {
                info!("🗑️  Window close requested by user: {}", process_key);
                if let Some((channel_id, device_path)) = DevicePath::from_window_key(&process_key) {
                    let _ = command_tx.send(AudioCommand::ClosePluginGui {
                        channel_id,
                        device_path,
                    });
                }
            }

            match packets.recv_timeout(Duration::from_millis(1)) {
                Ok((packet_bytes, addr)) => {
                    // Remember client address for sending status updates
                    if self.client_addr.is_none() {
                        info!("OSC client connected from {}", addr);
                        self.client_addr = Some(addr);

                        // Send connection confirmation
                        let _ = self.send_message("/status/playing", vec![OscType::Int(0)]);
                    }

                    // Parse OSC packet
                    match rosc::decoder::decode_udp(&packet_bytes) {
                        Ok((_, packet)) => {
                            if let Err(e) = self.handle_packet(
                                packet,
                                &command_tx,
                                &log_writers,
                                window_manager,
                            ) {
                                warn!("Error handling OSC packet: {}", e);
                            }
                        }
                        Err(e) => warn!(
                            "Dropped undecodable OSC packet ({} bytes): {:?}",
                            packet_bytes.len(),
                            e
                        ),
                    }
                }
                Err(crossbeam::channel::RecvTimeoutError::Timeout) => {
                    // No data available, process window events
                    window_manager.pump_events();
                }
                Err(crossbeam::channel::RecvTimeoutError::Disconnected) => {
                    warn!("OSC receiver thread stopped; the OSC server is shutting down");
                    return Ok(());
                }
            }
        }
    }

    /// Send a message to the client
    pub(super) fn send_message(&self, addr: &str, args: Vec<OscType>) -> Result<()> {
        let msg = OscMessage {
            addr: addr.to_string(),
            args,
        };

        let packet = OscPacket::Message(msg);
        let buf = rosc::encoder::encode(&packet)?;

        let client_addr = format!("127.0.0.1:{}", self.client_port);
        let addr = client_addr.parse::<SocketAddr>()?;
        self.socket.send_to(&buf, addr)?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A burst sent while nothing handles packets must arrive whole, in order. Before the
    /// receiver thread this overflowed the kernel buffer and datagrams vanished.
    #[test]
    fn receiver_keeps_a_burst_in_order() {
        let server = UdpSocket::bind("127.0.0.1:0").unwrap();
        let addr = server.local_addr().unwrap();
        let _ = grow_recv_buffer(&server);
        let packets = spawn_receiver(server).unwrap();

        let client = UdpSocket::bind("127.0.0.1:0").unwrap();
        const COUNT: u32 = 20_000;
        for i in 0..COUNT {
            client.send_to(&i.to_be_bytes(), addr).unwrap();
        }
        for i in 0..COUNT {
            let (bytes, _) = packets
                .recv_timeout(Duration::from_secs(2))
                .unwrap_or_else(|_| panic!("packet {i} of {COUNT} never arrived"));
            assert_eq!(bytes, i.to_be_bytes(), "packet {i} out of order");
        }
    }

    /// rosc 0.10 demanded 4 padding bytes after a blob already on a 4-byte boundary, so every
    /// 16-byte Drum Machine choke mask was dropped as undecodable.
    #[test]
    fn decodes_word_aligned_blob() {
        use rosc::{OscPacket, OscType};
        let mut packet = b"/b\0\0,b\0\0".to_vec();
        packet.extend_from_slice(&16u32.to_be_bytes());
        packet.extend_from_slice(&[7u8; 16]);
        let (_, decoded) = rosc::decoder::decode_udp(&packet).expect("blob decodes");
        let OscPacket::Message(msg) = decoded else {
            panic!("expected a message");
        };
        assert_eq!(msg.args, vec![OscType::Blob(vec![7u8; 16])]);
    }
}
