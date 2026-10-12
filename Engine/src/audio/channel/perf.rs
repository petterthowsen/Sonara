//! Per-channel and per-device processing timers (spec 042 part A).
//!
//! The audio callback adds to them only while `EngineState::perf_timing` is on (a perf
//! subscriber is listening); the command thread reads and resets them under the state lock every
//! report interval. Plain fields, no heap: they live inline in `Channel` and `MixBuffers`.

/// Top-level devices per channel that get a timer. Devices past this run untimed.
pub const MAX_TIMED_DEVICES: usize = 64;

/// One top-level device's time over the current report interval.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct DeviceTimer {
    pub total_ns: u64,
    /// Longest single block.
    pub peak_ns: u32,
    /// Blocks the device ran in. A sleeping device doesn't run, so it adds no time and no block.
    pub blocks: u32,
}

impl DeviceTimer {
    pub fn add(&mut self, ns: u64) {
        self.total_ns += ns;
        self.peak_ns = self.peak_ns.max(ns.min(u32::MAX as u64) as u32);
        self.blocks += 1;
    }

    /// The interval's figures, leaving the timer reset.
    pub fn take(&mut self) -> Self {
        std::mem::take(self)
    }
}

/// One channel's own work (chain begin and resume, fader and pan, routing) over the current
/// report interval. Time a parked chain spends waiting while other channels run is not added.
#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct ChannelTimer {
    /// Time added in the block in progress.
    pub current_ns: u64,
    /// Time in the finished blocks of the interval.
    pub total_ns: u64,
    /// Duration of the finished blocks of the interval, so averages are shares of real time.
    pub block_ns: u64,
    /// Largest single-block share of the block time.
    pub peak_load: f32,
    /// Finished blocks.
    pub blocks: u32,
}

impl ChannelTimer {
    pub fn add(&mut self, ns: u64) {
        self.current_ns += ns;
    }

    /// Close the block in progress, which lasted `block_ns` of audio.
    pub fn end_block(&mut self, block_ns: u64) {
        if block_ns > 0 {
            self.total_ns += self.current_ns;
            self.block_ns += block_ns;
            self.peak_load = self.peak_load.max(self.current_ns as f32 / block_ns as f32);
            self.blocks += 1;
        }
        self.current_ns = 0;
    }

    /// Average share of the block time over the interval (0 before any block finished).
    pub fn load_avg(&self) -> f32 {
        if self.block_ns == 0 {
            0.0
        } else {
            self.total_ns as f32 / self.block_ns as f32
        }
    }

    /// The interval's figures, leaving the timer reset.
    pub fn take(&mut self) -> Self {
        std::mem::take(self)
    }
}

/// Nanoseconds since `started`, for the `timing.then(Instant::now)` pattern.
pub fn elapsed_ns(started: std::time::Instant) -> u64 {
    started.elapsed().as_nanos() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_timer_tracks_total_peak_and_blocks() {
        let mut timer = DeviceTimer::default();
        timer.add(100);
        timer.add(300);
        assert_eq!(
            timer.take(),
            DeviceTimer {
                total_ns: 400,
                peak_ns: 300,
                blocks: 2
            }
        );
        assert_eq!(timer, DeviceTimer::default());
    }

    #[test]
    fn channel_timer_loads_are_shares_of_the_block_time() {
        let mut timer = ChannelTimer::default();
        timer.add(1_000);
        timer.add(1_000);
        timer.end_block(10_000); // 20%
        timer.end_block(10_000); // idle block: 0%
        assert_eq!(timer.blocks, 2);
        assert!((timer.load_avg() - 0.1).abs() < 1e-6);
        assert!((timer.peak_load - 0.2).abs() < 1e-6);
        timer.take();
        assert_eq!(timer.load_avg(), 0.0);
    }
}
