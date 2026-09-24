//! Shared memory for the plugin block handshake.
//!
//! Two mappings per plugin host:
//! - `SharedMemory`: one per plugin instance. Planar input/output audio, input/output event
//!   arrays and the `BlockControl` sequence numbers.
//! - `HostSharedMemory`: one per host process, holding the doorbell word the engine and the host
//!   use to wake each other.
//!
//! Each mapping is touched by exactly one thread in each process, so the accessors hand out raw
//! slices without a lock. Ordering between the engine's writes and the host's reads is carried by
//! `BlockControl::request_seq` / `done_seq` (`Release`/`Acquire`).

use super::platform_shm::PlatformSharedMemory;
use super::protocol::{BlockControl, BlockEvent, Doorbell, SharedMemoryLayout};
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicU32, Ordering};

/// Bytes reserved for a host's doorbell mapping.
const HOST_SHARED_MEMORY_SIZE: usize = 4096;

/// One plugin instance's shared block.
pub struct SharedMemory {
    layout: SharedMemoryLayout,
    memory: PlatformSharedMemory,
}

impl SharedMemory {
    /// Create the region (engine side). The mapping starts zeroed, minus the written defaults.
    pub fn new(name: &str, layout: SharedMemoryLayout) -> Result<Self, String> {
        let mut memory = PlatformSharedMemory::new(name, layout.total_size())?;

        let control = BlockControl::default();
        // SAFETY: fresh mapping of at least `size_of::<BlockControl>()` bytes past `control_offset`.
        let bytes = unsafe {
            std::slice::from_raw_parts(
                &control as *const BlockControl as *const u8,
                std::mem::size_of::<BlockControl>(),
            )
        };
        memory.as_mut_slice()[layout.control_offset..layout.control_offset + bytes.len()]
            .copy_from_slice(bytes);

        Ok(Self { layout, memory })
    }

    /// Map an existing region (host side, from the FD sent with `Initialize`).
    pub fn from_fd(fd: RawFd, layout: SharedMemoryLayout) -> Result<Self, String> {
        let memory = PlatformSharedMemory::from_fd(fd, layout.total_size())?;
        Ok(Self { layout, memory })
    }

    pub fn as_raw_fd(&self) -> RawFd {
        self.memory.as_raw_fd()
    }

    pub fn layout(&self) -> &SharedMemoryLayout {
        &self.layout
    }

    /// The block handshake control block.
    pub fn control(&self) -> &BlockControl {
        unsafe {
            let ptr = self.memory.as_ptr().add(self.layout.control_offset) as *const BlockControl;
            &*ptr
        }
    }

    /// Planar input audio, `max_frames × max_channels` (engine writes, host reads).
    pub fn input(&self) -> &mut [f32] {
        self.plane(self.layout.input_offset)
    }

    /// Planar output audio, `max_frames × max_channels` (host writes, engine reads).
    pub fn output(&self) -> &mut [f32] {
        self.plane(self.layout.output_offset)
    }

    /// Input events for the current block (engine writes, host reads).
    pub fn input_events(&self) -> &mut [BlockEvent] {
        self.events(self.layout.input_events_offset)
    }

    /// Output events for the current block (host writes, engine reads).
    pub fn output_events(&self) -> &mut [BlockEvent] {
        self.events(self.layout.output_events_offset)
    }

    fn plane(&self, offset: usize) -> &mut [f32] {
        let len = self.layout.max_frames * self.layout.max_channels;
        // SAFETY: `offset` is page-aligned and the layout reserves `len` f32 past it. Exactly one
        // thread per process touches this plane, and the block handshake orders it against the
        // other process.
        unsafe {
            let ptr = self.memory.as_ptr().add(offset) as *mut f32;
            std::slice::from_raw_parts_mut(ptr, len)
        }
    }

    fn events(&self, offset: usize) -> &mut [BlockEvent] {
        let len = self.layout.max_events;
        // SAFETY: same as `plane`.
        unsafe {
            let ptr = self.memory.as_ptr().add(offset) as *mut BlockEvent;
            std::slice::from_raw_parts_mut(ptr, len)
        }
    }
}

/// One host process's doorbell word.
pub struct HostSharedMemory {
    memory: PlatformSharedMemory,
}

impl HostSharedMemory {
    /// Create the region (engine side, before spawning the host).
    pub fn new(name: &str) -> Result<Self, String> {
        let mut memory = PlatformSharedMemory::new(name, HOST_SHARED_MEMORY_SIZE)?;
        let doorbell = Doorbell::default();
        // SAFETY: fresh mapping of at least `size_of::<Doorbell>()` bytes.
        let bytes = unsafe {
            std::slice::from_raw_parts(
                &doorbell as *const Doorbell as *const u8,
                std::mem::size_of::<Doorbell>(),
            )
        };
        memory.as_mut_slice()[..bytes.len()].copy_from_slice(bytes);
        Ok(Self { memory })
    }

    /// Map the region the engine passed at spawn time.
    pub fn from_fd(fd: RawFd) -> Result<Self, String> {
        let memory = PlatformSharedMemory::from_fd(fd, HOST_SHARED_MEMORY_SIZE)?;
        Ok(Self { memory })
    }

    pub fn as_raw_fd(&self) -> RawFd {
        self.memory.as_raw_fd()
    }

    /// The doorbell word both sides ring.
    pub fn doorbell(&self) -> &AtomicU32 {
        // SAFETY: the mapping is at least `size_of::<Doorbell>()` bytes and its first field is
        // the word.
        unsafe { &*(self.memory.as_ptr() as *const AtomicU32) }
    }

    /// Bump the doorbell and wake anyone waiting on it.
    pub fn ring(&self) {
        super::futex::ring(self.doorbell());
    }
}

impl Default for HostSharedMemory {
    fn default() -> Self {
        Self::new("sonara_host_doorbell").expect("host doorbell shared memory")
    }
}

/// Read a `BlockEvent` count from a `Relaxed` counter, bounded by the array length.
pub fn clamped_count(count: &std::sync::atomic::AtomicU32, len: usize) -> usize {
    (count.load(Ordering::Relaxed) as usize).min(len)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::ipc::protocol::{EVENT_NOTE_ON, EVENT_PARAM};

    #[test]
    fn planes_and_events_are_independent() {
        let layout = SharedMemoryLayout::new(128);
        let shm = SharedMemory::new("sonara_test_block", layout).unwrap();

        shm.input()[0] = 1.5;
        shm.output()[0] = -2.0;
        assert_eq!(shm.input()[0], 1.5);
        assert_eq!(shm.output()[0], -2.0);

        shm.input_events()[0] = BlockEvent::note(3, 60, 0.5, true);
        shm.output_events()[0] = BlockEvent::param(1, 7, 0.25);
        assert_eq!(shm.input_events()[0].kind, EVENT_NOTE_ON);
        assert_eq!(shm.output_events()[0].kind, EVENT_PARAM);
        assert_eq!(shm.output_events()[0].id, 7);
    }

    #[test]
    fn control_starts_zeroed() {
        let layout = SharedMemoryLayout::new(64);
        let shm = SharedMemory::new("sonara_test_control", layout).unwrap();
        let control = shm.control();
        assert_eq!(control.request_seq.load(Ordering::Relaxed), 0);
        assert_eq!(control.done_seq.load(Ordering::Relaxed), 0);
        assert_eq!(control.input_frames.load(Ordering::Relaxed), 0);
    }

    #[test]
    fn doorbell_rings() {
        let bell = HostSharedMemory::new("sonara_test_doorbell").unwrap();
        assert_eq!(bell.doorbell().load(Ordering::Relaxed), 0);
        bell.ring();
        assert_eq!(bell.doorbell().load(Ordering::Relaxed), 1);
    }

    #[test]
    fn layout_is_64_byte_aligned() {
        let layout = SharedMemoryLayout::new(1024);
        assert_eq!(layout.input_offset % 64, 0);
        assert_eq!(layout.output_offset % 64, 0);
        assert_eq!(layout.input_events_offset % 64, 0);
        assert_eq!(layout.output_events_offset % 64, 0);
        assert_eq!(layout.control_offset % 64, 0);
    }
}
