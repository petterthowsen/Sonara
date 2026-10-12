//! Channel worker pool (spec 042 part C): processing threads that run independent channels'
//! device chains while the callback thread runs others.
//!
//! The unit of work is a channel's chain. The mixer hands `run_jobs` the channels of one pass
//! that can't depend on each other (the pre-pass, or one routing sweep). The callback publishes
//! them, claims jobs itself through the same counter as the workers, and waits only for jobs a
//! thread has started: a job no worker reached is claimed by the callback (REQ-012). A chain that
//! parks at a plugin goes into the claiming thread's own park queue and is drained once no jobs
//! are left, so plugins on different channels still overlap.
//!
//! Everything order-dependent (device events, fader and pan, routing and summing) stays on the
//! callback thread, outside the pool.

use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use tracing::{error, info, warn};

use super::routing::chain_start;
use crate::audio::channel::Channel;
use crate::audio::devices::container::ChainStep;
use crate::audio::ipc::futex;
use crate::audio::realtime::{self, RealtimeState};
use crate::audio::rt_debug;

/// Most jobs one pass can publish. A pass with more runs on the callback thread alone.
pub const MAX_JOBS: usize = 1024;

/// How long a thread spins before it sleeps on a futex, while waiting for work (workers) or for
/// started jobs to finish (callback).
const SPIN: Duration = Duration::from_micros(20);

/// How long `ChannelPool::new` waits for the workers to report their realtime request.
const PROMOTION_WAIT: Duration = Duration::from_secs(2);

/// The claim word packs the generation (high 32 bits), the job count (16 bits) and the next job
/// index (low 16 bits), so a thread can only claim jobs of the generation it woke for.
const COUNT_SHIFT: u32 = 16;
const INDEX_MASK: u64 = 0xFFFF;

fn pack_claim(generation: u32, count: usize, index: usize) -> u64 {
    ((generation as u64) << 32) | ((count as u64) << COUNT_SHIFT) | index as u64
}

/// State shared by the callback and the workers.
///
/// # Safety invariant
///
/// `jobs` holds addresses of distinct `Channel`s in the engine's channel map. A thread may
/// dereference one only after claiming its index for the current generation, and only until it
/// adds that job to `done_count`. The callback publishes a generation only while it holds the
/// state lock, doesn't touch the channel map until `done_count` reaches the job count, and
/// publishes the next generation only after that. So each channel is reached by exactly one
/// thread at a time, and never after the pass that published it has returned.
pub struct PoolShared {
    jobs: Box<[AtomicUsize]>,
    /// See `pack_claim`.
    claim: AtomicU64,
    /// Finished jobs of the current generation. Futex word the callback waits on.
    done_count: AtomicU32,
    /// Bumped once per published pass. Futex word the workers wait on.
    generation: AtomicU32,
    /// Frames of the current pass.
    frames: AtomicUsize,
    shutdown: AtomicBool,
    /// Per worker: 0 until it asked for realtime, then `RealtimeState::as_u32`.
    realtime: Box<[AtomicU8]>,
    /// Test hook: workers don't claim while set, so the callback must run every job.
    #[cfg(test)]
    paused: AtomicBool,
}

impl PoolShared {
    fn new(workers: usize) -> Self {
        Self {
            jobs: (0..MAX_JOBS).map(|_| AtomicUsize::new(0)).collect(),
            claim: AtomicU64::new(0),
            done_count: AtomicU32::new(0),
            generation: AtomicU32::new(0),
            frames: AtomicUsize::new(0),
            shutdown: AtomicBool::new(false),
            realtime: (0..workers).map(|_| AtomicU8::new(0)).collect(),
            #[cfg(test)]
            paused: AtomicBool::new(false),
        }
    }

    /// Claim the next job of `generation`: its index and the generation's job count.
    fn claim(&self, generation: u32) -> Option<(usize, usize)> {
        let mut current = self.claim.load(Ordering::Acquire);
        loop {
            let count = ((current >> COUNT_SHIFT) & INDEX_MASK) as usize;
            let index = (current & INDEX_MASK) as usize;
            if (current >> 32) as u32 != generation || index >= count {
                return None;
            }
            match self.claim.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Some((index, count)),
                Err(actual) => current = actual,
            }
        }
    }

    /// Count one finished job; the last one wakes the callback.
    fn finish_one(&self, count: usize) {
        if self.done_count.fetch_add(1, Ordering::AcqRel) + 1 == count as u32 {
            futex::wake(&self.done_count, i32::MAX);
        }
    }

    /// Claim and run jobs of `generation` until none are left, then drain the chains that parked
    /// on this thread. `parked` holds job indices and is empty on return.
    ///
    /// On a worker a panicking job still counts as finished, so the callback isn't left waiting.
    fn work(&self, generation: u32, parked: &mut VecDeque<usize>, catch: bool) {
        let mut job_count = 0;
        let mut frames = 0;
        while let Some((index, count)) = self.claim(generation) {
            // The claim's acquire makes this generation's frames visible.
            job_count = count;
            frames = self.frames.load(Ordering::Relaxed);
            if self.step(index, frames, false, catch) {
                parked.push_back(index);
            } else {
                self.finish_one(count);
            }
        }
        while let Some(index) = parked.pop_front() {
            if self.step(index, frames, true, catch) {
                parked.push_back(index);
            } else {
                self.finish_one(job_count);
            }
        }
    }

    /// Begin (or resume) job `index`'s chain. True when it parked at a plugin.
    fn step(&self, index: usize, frames: usize, resume: bool, catch: bool) -> bool {
        let address = self.jobs[index].load(Ordering::Relaxed);
        // SAFETY: this thread claimed `index` for the current generation and hasn't finished it
        // (see the invariant on `PoolShared`).
        let channel = unsafe { &mut *(address as *mut Channel) };
        let mut run = || {
            let step = if resume {
                channel.resume_device_chain(frames)
            } else {
                channel.begin_device_chain(chain_start(channel), frames)
            };
            matches!(step, ChainStep::Parked)
        };
        if !catch {
            return run();
        }
        match catch_unwind(AssertUnwindSafe(run)) {
            Ok(parked) => parked,
            Err(_) => {
                error!("A device chain panicked on a processing thread; its block is dropped");
                false
            }
        }
    }
}

/// The processing threads. Created and dropped by the command thread, outside the state lock;
/// the callback uses it through `EngineState` under the lock.
pub struct ChannelPool {
    shared: Arc<PoolShared>,
    workers: Vec<JoinHandle<()>>,
}

impl ChannelPool {
    /// Start `threads` worker threads, each promoted to realtime for a period of `frames_hint`
    /// frames at `rate`. Waits briefly until each has its realtime answer. 0 threads means every
    /// pass runs on the callback thread.
    pub fn new(threads: usize, frames_hint: u32, rate: u32) -> Self {
        let pool = Self::spawn(threads, Some((frames_hint, rate)));
        let deadline = Instant::now() + PROMOTION_WAIT;
        while Instant::now() < deadline
            && pool
                .shared
                .realtime
                .iter()
                .any(|state| state.load(Ordering::Acquire) == 0)
        {
            std::thread::sleep(Duration::from_millis(1));
        }
        if threads > 0 {
            info!(
                "Channel pool: {} processing threads, realtime {}",
                threads,
                pool.realtime_summary()
            );
        }
        pool
    }

    /// `promote`: the period to ask realtime for, or `None` to leave the workers unpromoted
    /// (tests).
    fn spawn(threads: usize, promote: Option<(u32, u32)>) -> Self {
        let shared = Arc::new(PoolShared::new(threads));
        let workers = (0..threads)
            .filter_map(|index| {
                let shared = Arc::clone(&shared);
                std::thread::Builder::new()
                    .name(format!("sonara-worker-{}", index + 1))
                    .spawn(move || worker_loop(&shared, index, promote))
                    .map_err(|e| warn!("Can't start processing thread {}: {}", index + 1, e))
                    .ok()
            })
            .collect();
        Self { shared, workers }
    }

    /// Worker threads running (the callback thread not included).
    pub fn threads(&self) -> usize {
        self.workers.len()
    }

    /// `none` (no workers), `granted`, `denied`, or `partial` when only some got realtime.
    pub fn realtime_summary(&self) -> &'static str {
        let states = &self.shared.realtime[..self.workers.len().min(self.shared.realtime.len())];
        let granted = states
            .iter()
            .filter(|state| state.load(Ordering::Acquire) == RealtimeState::Granted.as_u32() as u8)
            .count();
        match granted {
            _ if states.is_empty() => "none",
            0 => "denied",
            n if n == states.len() => "granted",
            _ => "partial",
        }
    }

    /// Run the chains of `jobs` (addresses of distinct channels, all safe to process in
    /// parallel) for `frames`, on the workers and this thread. Returns when every chain is done.
    /// `parked` is preallocated scratch for this thread's parked jobs.
    ///
    /// Callback thread only, under the state lock, and the caller doesn't touch the channels
    /// until it returns. Device events are left for the caller to forward.
    pub fn run_jobs(&self, jobs: &[usize], parked: &mut VecDeque<usize>, frames: usize) {
        debug_assert!(
            jobs.iter()
                .enumerate()
                .all(|(i, job)| !jobs[i + 1..].contains(job)),
            "a channel appears twice in one pool pass"
        );
        parked.clear();
        if jobs.is_empty() {
            return;
        }
        let shared = &*self.shared;
        if self.workers.is_empty() || jobs.len() > MAX_JOBS {
            // Same steps through the claim counter, all on this thread.
            for chunk in jobs.chunks(MAX_JOBS) {
                let generation = Self::publish(shared, chunk, frames, false);
                shared.work(generation, parked, false);
            }
            return;
        }
        let generation = Self::publish(shared, jobs, frames, true);
        shared.work(generation, parked, false);

        // Wait for jobs the workers started.
        let count = jobs.len() as u32;
        let spin_until = Instant::now() + SPIN;
        loop {
            let done = shared.done_count.load(Ordering::Acquire);
            if done >= count {
                break;
            }
            if Instant::now() < spin_until {
                std::hint::spin_loop();
            } else {
                futex::wait(&shared.done_count, done, Some(Duration::from_millis(1)));
            }
        }
    }

    /// Store a pass's jobs and open its generation. Returns the generation.
    fn publish(shared: &PoolShared, jobs: &[usize], frames: usize, wake: bool) -> u32 {
        let count = jobs.len();
        debug_assert!(count <= MAX_JOBS);
        for (slot, &job) in shared.jobs.iter().zip(jobs) {
            slot.store(job, Ordering::Relaxed);
        }
        shared.done_count.store(0, Ordering::Relaxed);
        shared.frames.store(frames, Ordering::Relaxed);
        let generation = shared.generation.load(Ordering::Relaxed).wrapping_add(1);
        // Release: a thread that claims through this word sees the jobs and frames above.
        shared
            .claim
            .store(pack_claim(generation, count, 0), Ordering::Release);
        shared.generation.store(generation, Ordering::Release);
        if wake {
            futex::wake(&shared.generation, i32::MAX);
        }
        generation
    }

    #[cfg(test)]
    fn set_paused(&self, paused: bool) {
        self.shared.paused.store(paused, Ordering::Release);
    }
}

impl Drop for ChannelPool {
    /// Stop and join the workers. Command thread only: joining blocks.
    fn drop(&mut self) {
        self.shared.shutdown.store(true, Ordering::Release);
        futex::ring(&self.shared.generation);
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

/// A processing thread: ask for realtime once, then wait for a generation, work it, repeat.
fn worker_loop(shared: &PoolShared, index: usize, promote: Option<(u32, u32)>) {
    // Held until the thread exits, which keeps the promotion.
    let (state, _realtime) = match promote {
        Some((frames, rate)) => {
            let label = format!("processing thread {}", index + 1);
            realtime::promote_current_thread(&label, frames, rate)
        }
        None => (RealtimeState::Denied, None),
    };
    shared.realtime[index].store(state.as_u32() as u8, Ordering::Release);

    let mut parked = VecDeque::with_capacity(MAX_JOBS);
    let mut seen = shared.generation.load(Ordering::Acquire);
    loop {
        seen = wait_for_generation(shared, seen);
        if shared.shutdown.load(Ordering::Acquire) {
            break;
        }
        #[cfg(test)]
        if shared.paused.load(Ordering::Acquire) {
            continue;
        }
        rt_debug::check_callback(|| shared.work(seen, &mut parked, true));
        rt_debug::report_violations();
    }
}

/// Spin briefly, then sleep, until the generation moves past `seen` or the pool shuts down.
/// Returns the new generation.
fn wait_for_generation(shared: &PoolShared, seen: u32) -> u32 {
    let spin_until = Instant::now() + SPIN;
    loop {
        let generation = shared.generation.load(Ordering::Acquire);
        if generation != seen || shared.shutdown.load(Ordering::Acquire) {
            return generation;
        }
        if Instant::now() < spin_until {
            std::hint::spin_loop();
        } else {
            futex::wait(&shared.generation, seen, None);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::mixing::test_support::*;
    use crate::audio::types::ChannelId;
    use std::sync::atomic::AtomicUsize as Counter;

    /// Channels with a test device each, every other one also with a fake plugin that parks.
    fn channels(n: usize) -> (Vec<Channel>, Vec<Arc<Counter>>, AsyncLog) {
        let log = AsyncLog::default();
        let mut calls = Vec::new();
        let channels = (0..n)
            .map(|i| {
                let id = 2 + i as ChannelId;
                let mut channel = test_channel(id, Some(1), 0.0);
                channel.buffer_left.fill(i as f32);
                channel.buffer_right.fill(-(i as f32));
                calls.push(add_test_device(&mut channel, 0.25));
                if i % 2 == 0 {
                    channel
                        .devices
                        .push(Box::new(FakePlugin::new(id, 2.0, &log)));
                }
                channel
            })
            .collect();
        (channels, calls, log)
    }

    fn addresses(channels: &mut [Channel]) -> Vec<usize> {
        channels
            .iter_mut()
            .map(|c| c as *mut Channel as usize)
            .collect()
    }

    fn expected(i: usize) -> (f32, f32) {
        let gain = if i % 2 == 0 { 2.0 } else { 1.0 };
        ((i as f32 + 0.25) * gain, (-(i as f32) + 0.25) * gain)
    }

    fn check_outputs(channels: &[Channel], calls: &[Arc<Counter>], runs: usize) {
        for (i, channel) in channels.iter().enumerate() {
            assert_eq!(
                calls[i].load(Ordering::Relaxed),
                runs,
                "channel {i} ran once a pass"
            );
            let (left, right) = expected(i);
            assert!(channel.buffer_left[..BUFFER_SIZE]
                .iter()
                .all(|&s| s == left));
            assert!(channel.buffer_right[..BUFFER_SIZE]
                .iter()
                .all(|&s| s == right));
        }
    }

    fn reset_inputs(channels: &mut [Channel]) {
        for (i, channel) in channels.iter_mut().enumerate() {
            channel.buffer_left.fill(i as f32);
            channel.buffer_right.fill(-(i as f32));
        }
    }

    #[test]
    fn pool_runs_every_job_once() {
        let pool = ChannelPool::spawn(3, None);
        let (mut channels, calls, _log) = channels(40);
        let jobs = addresses(&mut channels);
        let mut parked = VecDeque::with_capacity(MAX_JOBS);
        for pass in 1..=50 {
            reset_inputs(&mut channels);
            pool.run_jobs(&jobs, &mut parked, BUFFER_SIZE);
            check_outputs(&channels, &calls, pass);
        }
    }

    #[test]
    fn pool_completes_with_paused_workers() {
        let pool = ChannelPool::spawn(4, None);
        pool.set_paused(true);
        let (mut channels, calls, _log) = channels(9);
        let jobs = addresses(&mut channels);
        let mut parked = VecDeque::with_capacity(MAX_JOBS);
        pool.run_jobs(&jobs, &mut parked, BUFFER_SIZE);
        check_outputs(&channels, &calls, 1);

        // Unpaused, the workers pick up the next pass as usual.
        pool.set_paused(false);
        reset_inputs(&mut channels);
        pool.run_jobs(&jobs, &mut parked, BUFFER_SIZE);
        check_outputs(&channels, &calls, 2);
    }

    #[test]
    fn pool_without_workers_runs_on_the_caller() {
        let pool = ChannelPool::spawn(0, None);
        assert_eq!(pool.realtime_summary(), "none");
        let (mut channels, calls, _log) = channels(5);
        let jobs = addresses(&mut channels);
        let mut parked = VecDeque::with_capacity(MAX_JOBS);
        pool.run_jobs(&jobs, &mut parked, BUFFER_SIZE);
        check_outputs(&channels, &calls, 1);
    }

    #[test]
    fn pool_drop_joins_workers() {
        let pool = ChannelPool::spawn(4, None);
        assert_eq!(pool.threads(), 4);
        assert_eq!(pool.realtime_summary(), "denied");
        let shared = Arc::downgrade(&pool.shared);
        drop(pool);
        assert!(
            shared.upgrade().is_none(),
            "every worker exited and released the shared state"
        );
    }

    #[test]
    #[cfg(debug_assertions)]
    #[should_panic(expected = "appears twice")]
    fn pool_rejects_a_duplicate_job() {
        let pool = ChannelPool::spawn(0, None);
        let (mut channels, _calls, _log) = channels(2);
        let address = &mut channels[0] as *mut Channel as usize;
        let mut parked = VecDeque::new();
        pool.run_jobs(&[address, address], &mut parked, BUFFER_SIZE);
    }
}
