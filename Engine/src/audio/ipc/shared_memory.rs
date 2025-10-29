//! Shared Memory Ring Buffers for Audio and MIDI Data
//!
//! Provides lock-free, single-producer single-consumer ring buffers for
//! low-latency audio and MIDI communication between engine and plugin subprocess.

use super::platform_shm::PlatformSharedMemory;
use super::protocol::{ControlData, MidiEvent, RingBufferStats, SharedMemoryLayout};
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Audio ring buffer (single-producer, single-consumer, lock-free)
pub struct AudioRingBuffer<'a> {
    buffer: &'a mut [f32],
    write_pos: &'a AtomicUsize,
    read_pos: &'a AtomicUsize,
}

impl<'a> AudioRingBuffer<'a> {
    /// Create ring buffer from shared memory slice
    pub fn new(
        buffer: &'a mut [f32],
        write_pos: &'a AtomicUsize,
        read_pos: &'a AtomicUsize,
    ) -> Self {
        Self {
            buffer,
            write_pos,
            read_pos,
        }
    }

    /// Get number of samples available to read
    pub fn available(&self) -> usize {
        let write = self.write_pos.load(Ordering::Acquire);
        let read = self.read_pos.load(Ordering::Acquire);

        if write >= read {
            write - read
        } else {
            // Wrapped around
            self.buffer.len() - read + write
        }
    }

    /// Get free space for writing
    pub fn free_space(&self) -> usize {
        // Leave one sample gap to distinguish full from empty
        self.buffer.len() - self.available() - 1
    }

    /// Write samples to ring buffer (producer side)
    pub fn write(&mut self, samples: &[f32]) -> usize {
        let free = self.free_space();
        let to_write = samples.len().min(free);

        if to_write == 0 {
            return 0;
        }

        let write_pos = self.write_pos.load(Ordering::Relaxed);
        let capacity = self.buffer.len();

        // Write in two parts if we wrap around
        let first_chunk = (capacity - write_pos).min(to_write);
        self.buffer[write_pos..write_pos + first_chunk].copy_from_slice(&samples[..first_chunk]);

        if first_chunk < to_write {
            let second_chunk = to_write - first_chunk;
            self.buffer[..second_chunk].copy_from_slice(&samples[first_chunk..to_write]);
        }

        // Update write position
        let new_write_pos = (write_pos + to_write) % capacity;
        self.write_pos.store(new_write_pos, Ordering::Release);

        to_write
    }

    /// Read samples from ring buffer (consumer side)
    pub fn read(&mut self, samples: &mut [f32]) -> usize {
        let available = self.available();
        let to_read = samples.len().min(available);

        if to_read == 0 {
            return 0;
        }

        let read_pos = self.read_pos.load(Ordering::Relaxed);
        let capacity = self.buffer.len();

        // Read in two parts if we wrap around
        let first_chunk = (capacity - read_pos).min(to_read);
        samples[..first_chunk].copy_from_slice(&self.buffer[read_pos..read_pos + first_chunk]);

        if first_chunk < to_read {
            let second_chunk = to_read - first_chunk;
            samples[first_chunk..to_read].copy_from_slice(&self.buffer[..second_chunk]);
        }

        // Update read position
        let new_read_pos = (read_pos + to_read) % capacity;
        self.read_pos.store(new_read_pos, Ordering::Release);

        to_read
    }

    /// Get buffer statistics
    pub fn stats(&self) -> RingBufferStats {
        let available = self.available();
        let capacity = self.buffer.len();
        RingBufferStats {
            available_samples: available,
            capacity,
            utilization_percent: (available as f32 / capacity as f32) * 100.0,
        }
    }
}

/// MIDI event queue (single-producer, single-consumer, lock-free)
pub struct MidiEventQueue<'a> {
    events: &'a mut [MidiEvent],
    write_pos: &'a AtomicUsize,
    read_pos: &'a AtomicUsize,
}

impl<'a> MidiEventQueue<'a> {
    /// Create MIDI queue from shared memory slice
    pub fn new(
        events: &'a mut [MidiEvent],
        write_pos: &'a AtomicUsize,
        read_pos: &'a AtomicUsize,
    ) -> Self {
        Self {
            events,
            write_pos,
            read_pos,
        }
    }

    /// Get number of events available to read
    pub fn available(&self) -> usize {
        let write = self.write_pos.load(Ordering::Acquire);
        let read = self.read_pos.load(Ordering::Acquire);

        if write >= read {
            write - read
        } else {
            self.events.len() - read + write
        }
    }

    /// Get free space for writing
    pub fn free_space(&self) -> usize {
        self.events.len() - self.available() - 1
    }

    /// Write MIDI event (producer side)
    pub fn write(&mut self, event: MidiEvent) -> bool {
        if self.free_space() == 0 {
            return false;
        }

        let write_pos = self.write_pos.load(Ordering::Relaxed);
        self.events[write_pos] = event;

        let new_write_pos = (write_pos + 1) % self.events.len();
        self.write_pos.store(new_write_pos, Ordering::Release);

        true
    }

    /// Read MIDI event (consumer side)
    pub fn read(&mut self) -> Option<MidiEvent> {
        if self.available() == 0 {
            return None;
        }

        let read_pos = self.read_pos.load(Ordering::Relaxed);
        let event = self.events[read_pos];

        let new_read_pos = (read_pos + 1) % self.events.len();
        self.read_pos.store(new_read_pos, Ordering::Release);

        Some(event)
    }

    /// Clear all events
    pub fn clear(&mut self) {
        let write_pos = self.write_pos.load(Ordering::Relaxed);
        self.read_pos.store(write_pos, Ordering::Release);
    }
}

/// Shared memory manager for plugin subprocess communication
pub struct SharedMemory {
    layout: SharedMemoryLayout,
    /// Platform-specific shared memory (using memfd_create on Linux)
    memory: PlatformSharedMemory,
}

impl SharedMemory {
    /// Create new shared memory region (for engine process)
    pub fn new(name: &str, layout: SharedMemoryLayout) -> Result<Self, String> {
        let total_size = layout.total_size();
        let mut memory = PlatformSharedMemory::new(name, total_size)?;

        // Initialize control data
        let control_data = ControlData::default();
        let control_bytes = unsafe {
            std::slice::from_raw_parts(
                &control_data as *const _ as *const u8,
                std::mem::size_of::<ControlData>(),
            )
        };

        let mem_slice = memory.as_mut_slice();
        mem_slice[layout.control_offset..layout.control_offset + control_bytes.len()]
            .copy_from_slice(control_bytes);

        Ok(Self { layout, memory })
    }

    /// Create shared memory from existing file descriptor (for plugin subprocess)
    /// The FD is received via SCM_RIGHTS over a Unix domain socket
    pub fn from_fd(fd: RawFd, layout: SharedMemoryLayout) -> Result<Self, String> {
        let total_size = layout.total_size();
        let memory = PlatformSharedMemory::from_fd(fd, total_size)?;

        Ok(Self { layout, memory })
    }

    /// Get the raw file descriptor (for passing to subprocess)
    pub fn as_raw_fd(&self) -> RawFd {
        self.memory.as_raw_fd()
    }

    /// Get the memory layout
    pub fn layout(&self) -> &SharedMemoryLayout {
        &self.layout
    }

    /// Get input audio ring buffer (engine writes, plugin reads)
    /// Safe to call with &self - ring buffer uses atomic operations internally
    pub fn input_buffer(&self) -> AudioRingBuffer<'_> {
        let buffer_slice = unsafe {
            let ptr = self.memory.as_ptr().add(self.layout.input_offset) as *mut f32;
            std::slice::from_raw_parts_mut(ptr, self.layout.input_buffer_size)
        };

        let control = self.control_data_atomic();
        AudioRingBuffer::new(
            buffer_slice,
            &control.input_write_pos,
            &control.input_read_pos,
        )
    }

    /// Get output audio ring buffer (plugin writes, engine reads)
    /// Safe to call with &self - ring buffer uses atomic operations internally
    pub fn output_buffer(&self) -> AudioRingBuffer<'_> {
        let buffer_slice = unsafe {
            let ptr = self.memory.as_ptr().add(self.layout.output_offset) as *mut f32;
            std::slice::from_raw_parts_mut(ptr, self.layout.output_buffer_size)
        };

        let control = self.control_data_atomic();
        AudioRingBuffer::new(
            buffer_slice,
            &control.output_write_pos,
            &control.output_read_pos,
        )
    }

    /// Get MIDI event queue (engine writes, plugin reads)
    /// Safe to call with &self - ring buffer uses atomic operations internally
    pub fn midi_queue(&self) -> MidiEventQueue<'_> {
        let event_slice = unsafe {
            let ptr = self.memory.as_ptr().add(self.layout.midi_offset) as *mut MidiEvent;
            std::slice::from_raw_parts_mut(ptr, self.layout.midi_queue_size)
        };

        let control = self.control_data_atomic();
        MidiEventQueue::new(event_slice, &control.midi_write_pos, &control.midi_read_pos)
    }

    /// Get control data reference
    pub fn control_data(&self) -> &ControlData {
        unsafe {
            let ptr = self.memory.as_ptr().add(self.layout.control_offset) as *const ControlData;
            &*ptr
        }
    }

    /// Get mutable control data reference
    pub fn control_data_mut(&mut self) -> &mut ControlData {
        unsafe {
            let ptr = self.memory.as_mut_ptr().add(self.layout.control_offset) as *mut ControlData;
            &mut *ptr
        }
    }

    /// Get atomic control data reference (safe for lock-free access)
    /// Used by ring buffer accessors that need atomic positions
    fn control_data_atomic(&self) -> &ControlData {
        unsafe {
            let ptr = self.memory.as_ptr().add(self.layout.control_offset) as *const ControlData;
            &*ptr
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_audio_ring_buffer() {
        let layout = SharedMemoryLayout::new(1024);
        let mut shm = SharedMemory::new("test_audio", layout).unwrap();

        // Write some samples
        let samples = vec![1.0, 2.0, 3.0, 4.0];
        let mut input = shm.input_buffer();
        let written = input.write(&samples);
        assert_eq!(written, 4);

        // Read them back
        let mut read_samples = vec![0.0; 4];
        let read = input.read(&mut read_samples);
        assert_eq!(read, 4);
        assert_eq!(read_samples, samples);
    }

    #[test]
    fn test_midi_queue() {
        let layout = SharedMemoryLayout::new(1024);
        let mut shm = SharedMemory::new("test_midi", layout).unwrap();

        let event = MidiEvent {
            sample_offset: 0,
            note: 60,
            velocity: 100,
            is_note_on: 1,
            _padding: 0,
        };

        let mut queue = shm.midi_queue();
        assert!(queue.write(event));

        let read_event = queue.read().unwrap();
        assert_eq!(read_event.note, 60);
        assert_eq!(read_event.velocity, 100);
    }
}
