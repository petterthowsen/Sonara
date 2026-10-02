//! The render loop: take over the engine, render the range and its tail block by block, hand the
//! engine back.

use crossbeam::channel::Sender;
use std::fmt;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tracing::{info, warn};

use super::wav::WavOutput;
use super::{RenderJob, RenderTail};
use crate::audio::block_clock::{BlockClock, OFFLINE_BLOCK_TIMEOUT};
use crate::audio::commands::{EngineState, EngineStatus};
use crate::audio::devices::clap_host::subprocess_adapter::PluginIpcHandle;
use crate::audio::devices::clap_host::SubprocessClapAdapter;
use crate::audio::devices::container;
use crate::audio::mixing::mix_and_output;
use crate::audio::processing::{frames_before_tick, process_audio};
use crate::audio::types::{ChannelId, ClipLoadState, ClipType, Tick};

/// Master channel ID.
const MASTER_CHANNEL_ID: ChannelId = 1;

/// How long to wait for plugins, SFZ files and audio clips to finish loading.
const READY_TIMEOUT: Duration = Duration::from_secs(60);

/// How often the readiness wait checks again.
const READY_POLL: Duration = Duration::from_millis(20);

/// How often progress is reported.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(100);

/// An until-silent tail ends after the master has stayed below `SILENCE_LEVEL` this long.
pub const SILENCE_HOLD: Duration = Duration::from_secs(1);

/// Peak level (−90 dBFS) below which the master counts as silent.
const SILENCE_LEVEL: f32 = 3.162e-5;

/// Why a render didn't produce its files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RenderError {
    Cancelled,
    Failed(String),
}

impl fmt::Display for RenderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RenderError::Cancelled => f.write_str("cancelled"),
            RenderError::Failed(message) => f.write_str(message),
        }
    }
}

impl From<String> for RenderError {
    fn from(message: String) -> Self {
        RenderError::Failed(message)
    }
}

/// Render `job` on this thread and return the files written (master first, then stems).
///
/// The live callback outputs silence from the start until the engine is handed back; the
/// transport is stopped first and its playhead restored afterwards, whether the render
/// succeeded, failed or was cancelled. The caller reports the outcome.
pub fn run_render(
    job: &RenderJob,
    state: &Mutex<EngineState>,
    status_tx: &Sender<EngineStatus>,
) -> Result<Vec<PathBuf>, RenderError> {
    let sample_rate = lock(state).device_sample_rate;
    job.validate(sample_rate.round() as u32)?;

    let started = Instant::now();
    let mut render = Render::begin(job, state, status_tx, sample_rate);
    let result = render.run();
    render.end();
    if let Ok(outputs) = &result {
        let seconds = render.frames_written as f64 / sample_rate as f64;
        let elapsed = started.elapsed().as_secs_f64();
        info!(
            "Render {} done: {:.1} s of audio in {:.1} s ({:.0}x real time), {} file(s)",
            job.job_id,
            seconds,
            elapsed,
            seconds / elapsed.max(1e-6),
            outputs.len()
        );
    }
    result
}

/// Lock the engine state, recovering it if a command panicked while holding it.
fn lock(state: &Mutex<EngineState>) -> MutexGuard<'_, EngineState> {
    state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Audio of one channel to write, copied out of the state each block.
struct Tap {
    channel_id: ChannelId,
    output: WavOutput,
    interleaved: Vec<f32>,
}

/// A render in progress. `begin` takes the engine over; `end` must run to hand it back.
struct Render<'a> {
    job: &'a RenderJob,
    state: &'a Mutex<EngineState>,
    status_tx: &'a Sender<EngineStatus>,
    sample_rate: f32,
    /// The engine's plugin clock, in offline mode while blocks render.
    block_clock: Arc<BlockClock>,
    /// Playhead before the render, restored at the end.
    saved_tick: Tick,
    /// Plugins switched to offline mode, switched back at the end.
    plugins: Vec<PluginIpcHandle>,
    frames_written: u64,
    /// Estimated frames in the range plus the longest tail, for progress.
    frames_expected: u64,
    last_progress: Instant,
    /// Tick-crossing scratch for `frames_before_tick`.
    rates: Vec<f64>,
    tick_events: Vec<(Tick, usize)>,
    /// `mix_and_output` writes the hardware buffer here; the render reads channels directly.
    hardware_scratch: Vec<f32>,
    /// Device events (sleep, data streams) during the render go nowhere: devices are kept
    /// awake, and Godot doesn't need spectrum frames at render speed.
    device_events: Sender<EngineStatus>,
}

impl<'a> Render<'a> {
    /// Take the engine over: silence the live callback and stop the transport.
    fn begin(
        job: &'a RenderJob,
        state: &'a Mutex<EngineState>,
        status_tx: &'a Sender<EngineStatus>,
        sample_rate: f32,
    ) -> Self {
        let (saved_tick, was_playing, frames_expected, block_clock) = {
            let state = lock(state);
            state.rendering.store(true, Ordering::Release);
            let was_playing = state.get_is_playing();
            state.set_is_playing(false);
            let settings = &state.settings;
            let seconds_at = |tick: Tick| {
                state
                    .tempo_map
                    .seconds_at(tick as f64, settings.tempo as f64, settings.ppq as f64)
            };
            let range_seconds = seconds_at(job.end_tick) - seconds_at(job.start_tick);
            let tail_seconds = job.tail.max_seconds() as f64;
            let expected = ((range_seconds + tail_seconds) * sample_rate as f64).max(1.0);
            (
                state.get_current_tick(),
                was_playing,
                expected as u64,
                state.block_clock.clone(),
            )
        };
        if was_playing {
            let _ = status_tx.send(EngineStatus::PlayingStateChanged(false));
        }
        info!(
            "Render {} started: ticks {}..{}, tail {:?}, {} block",
            job.job_id, job.start_tick, job.end_tick, job.tail, job.block_frames
        );
        let (device_events, _) = crossbeam::channel::bounded(1);
        Self {
            job,
            state,
            status_tx,
            sample_rate,
            block_clock,
            saved_tick,
            plugins: Vec::new(),
            frames_written: 0,
            frames_expected,
            last_progress: Instant::now(),
            rates: Vec::with_capacity(job.block_frames),
            tick_events: Vec::with_capacity(job.block_frames + 1),
            hardware_scratch: vec![0.0; job.block_frames * 2],
            device_events,
        }
    }

    /// Wait for the devices, rewind them, render the range and the tail, and finish the files.
    fn run(&mut self) -> Result<Vec<PathBuf>, RenderError> {
        let mut taps = self.open_outputs()?;
        self.wait_until_ready()?;
        self.prepare_devices()?;
        self.render_range(&mut taps)?;
        self.render_tail(&mut taps)?;

        let mut paths = Vec::with_capacity(taps.len());
        for tap in taps {
            paths.push(tap.output.finish()?);
        }
        let _ = self.status_tx.try_send(EngineStatus::RenderProgress {
            job_id: self.job.job_id.clone(),
            fraction: 1.0,
        });
        Ok(paths)
    }

    /// Create the WAV files (as `.part` until they're complete), master first.
    fn open_outputs(&self) -> Result<Vec<Tap>, RenderError> {
        let outputs = &self.job.outputs;
        let channels: Vec<ChannelId> = {
            let state = lock(self.state);
            if let Some(&(missing, _)) = outputs
                .stems
                .iter()
                .find(|(id, _)| !state.channels.contains_key(id))
            {
                return Err(format!("channel {} doesn't exist", missing).into());
            }
            outputs
                .master
                .iter()
                .map(|_| MASTER_CHANNEL_ID)
                .chain(outputs.stems.iter().map(|&(id, _)| id))
                .collect()
        };
        let rate = self.sample_rate.round() as u32;
        channels
            .into_iter()
            .zip(outputs.paths())
            .map(|(channel_id, path)| {
                Ok(Tap {
                    channel_id,
                    output: WavOutput::create(&path, rate, outputs.format)?,
                    interleaved: Vec::with_capacity(self.job.block_frames * 2),
                })
            })
            .collect()
    }

    fn check_cancelled(&self) -> Result<(), RenderError> {
        if self.job.is_cancelled() {
            Err(RenderError::Cancelled)
        } else {
            Ok(())
        }
    }

    /// Wait until no plugin or SFZ file is still loading and every audio clip in the range is
    /// decoded. Fails when a device failed or crashed, or after `READY_TIMEOUT`.
    fn wait_until_ready(&self) -> Result<(), RenderError> {
        let deadline = Instant::now() + READY_TIMEOUT;
        let mut logged = String::new();
        loop {
            self.check_cancelled()?;
            let Some(pending) = find_unready(&mut lock(self.state), self.job)? else {
                return Ok(());
            };
            if Instant::now() >= deadline {
                return Err(format!("timed out waiting for {} to load", pending).into());
            }
            if pending != logged {
                info!("Render {} waiting for {} to load", self.job.job_id, pending);
                logged = pending;
            }
            std::thread::sleep(READY_POLL);
        }
    }

    /// Reset every device so nothing from live playback leaks in, switch plugins to offline
    /// rendering, and put the playhead at the start of the range, playing.
    fn prepare_devices(&mut self) -> Result<(), RenderError> {
        {
            let mut state = lock(self.state);
            reset_engine_devices(&mut state);
            for channel in state.channels.values_mut() {
                container::visit_devices_mut(&mut channel.devices, &mut |_, device| {
                    if let Some(plugin) =
                        device.as_any_mut().downcast_mut::<SubprocessClapAdapter>()
                    {
                        if plugin.load().is_ready() {
                            self.plugins.push(plugin.ipc_handle());
                        }
                    }
                });
            }
        }

        // Blocking round trips, with the state lock released. The reset reply means the host
        // queued it on its audio thread, which applies it before the first render block.
        for plugin in &self.plugins {
            match plugin.set_render_mode(true) {
                Ok(true) => info!("Plugin {} renders in offline mode", plugin.device_name()),
                Ok(false) => {}
                Err(e) => warn!(
                    "Couldn't switch plugin {} to offline rendering: {}",
                    plugin.device_name(),
                    e
                ),
            }
            plugin
                .reset()
                .map_err(|e| format!("couldn't reset plugin {}: {}", plugin.device_name(), e))?;
        }

        let state = lock(self.state);
        state.set_current_tick(self.job.start_tick);
        state.set_fractional_tick_accumulator(0.0);
        state.request_playhead_midi_dispatch();
        state.set_is_playing(true);
        self.block_clock.begin_offline();
        Ok(())
    }

    /// Render from the start tick up to the frame before the end tick's MIDI would play.
    fn render_range(&mut self, taps: &mut [Tap]) -> Result<(), RenderError> {
        // The range can't take longer than its tempo-map length; the slack covers rounding.
        let limit = self.frames_expected + self.sample_rate as u64;
        loop {
            self.check_cancelled()?;
            let rendered = {
                let mut state = lock(self.state);
                self.check_rate(&state)?;
                let frames = frames_before_tick(
                    &state,
                    self.job.end_tick,
                    self.job.block_frames,
                    self.sample_rate,
                    &mut self.rates,
                    &mut self.tick_events,
                );
                if frames > 0 {
                    self.render_block(&mut state, frames, taps);
                }
                frames
            };
            if rendered == 0 {
                break;
            }
            self.after_block(taps, rendered)?;
            if self.frames_written > limit {
                return Err("the playhead didn't reach the end of the range"
                    .to_string()
                    .into());
            }
        }

        // Stop like the transport does: release held clip notes and let devices ring on.
        let mut state = lock(self.state);
        state.set_is_playing(false);
        for channel in state.channels.values_mut() {
            channel.release_clip_notes();
        }
        Ok(())
    }

    /// Render the tail with the transport stopped.
    fn render_tail(&mut self, taps: &mut [Tap]) -> Result<(), RenderError> {
        let max_frames =
            (self.job.tail.max_seconds() as f64 * self.sample_rate as f64).round() as u64;
        let hold_frames = (SILENCE_HOLD.as_secs_f64() * self.sample_rate as f64) as u64;
        let until_silent = matches!(self.job.tail, RenderTail::UntilSilent { .. });
        let mut rendered = 0;
        let mut silent_frames = 0;
        while rendered < max_frames {
            self.check_cancelled()?;
            let frames = (max_frames - rendered).min(self.job.block_frames as u64) as usize;
            let peak = {
                let mut state = lock(self.state);
                self.check_rate(&state)?;
                self.render_block(&mut state, frames, taps);
                master_peak(&state, frames)
            };
            self.after_block(taps, frames)?;
            rendered += frames as u64;
            if until_silent {
                silent_frames = if peak < SILENCE_LEVEL {
                    silent_frames + frames as u64
                } else {
                    0
                };
                if silent_frames >= hold_frames {
                    break;
                }
            }
        }
        Ok(())
    }

    /// A device-rate change would leave devices prepared for another rate than the file's.
    fn check_rate(&self, state: &EngineState) -> Result<(), RenderError> {
        if state.device_sample_rate != self.sample_rate {
            return Err(format!(
                "the engine's sample rate changed to {} Hz during the render",
                state.device_sample_rate
            )
            .into());
        }
        Ok(())
    }

    /// Render one block under the lock and copy the tapped channels out.
    fn render_block(&mut self, state: &mut EngineState, frames: usize, taps: &mut [Tap]) {
        // Live MIDI played during a render must not end up in it.
        for channel in state.channels.values_mut() {
            while channel.midi_queue.pop().is_some() {}
            // Devices that sleep on wall-clock time would sleep at different points in two
            // renders of the same range; keeping them awake makes renders repeatable and
            // keeps quiet tails in.
            container::visit_devices_mut(&mut channel.devices, &mut |_, device| {
                device.mark_activity()
            });
            channel.clear_buffers();
        }

        self.block_clock.publish_offline_block();
        process_audio(state, frames, self.sample_rate, Instant::now());
        mix_and_output(
            state,
            &mut self.hardware_scratch[..frames * 2],
            2,
            frames,
            &self.device_events,
        );

        // After mixing, every channel buffer holds that channel's post-fader, post-pan output.
        for tap in taps.iter_mut() {
            tap.interleaved.clear();
            match state.channels.get(&tap.channel_id) {
                Some(channel) => tap.interleaved.extend(
                    channel.buffer_left[..frames]
                        .iter()
                        .zip(&channel.buffer_right[..frames])
                        .flat_map(|(&l, &r)| [l, r]),
                ),
                // Removed during the render: the rest of its stem is silence.
                None => tap.interleaved.resize(frames * 2, 0.0),
            }
        }
    }

    /// With the lock released: fail on a plugin that missed its block, write the block, report
    /// progress.
    fn after_block(&mut self, taps: &mut [Tap], frames: usize) -> Result<(), RenderError> {
        if self.block_clock.take_offline_misses() > 0 {
            return Err(format!(
                "a plugin didn't finish a block within {} s (or its host crashed); the render would have a gap",
                OFFLINE_BLOCK_TIMEOUT.as_secs()
            )
            .into());
        }
        for tap in taps.iter_mut() {
            tap.output.write(&tap.interleaved)?;
        }
        self.frames_written += frames as u64;
        if self.last_progress.elapsed() >= PROGRESS_INTERVAL {
            self.last_progress = Instant::now();
            let fraction = (self.frames_written as f64 / self.frames_expected as f64).min(0.99);
            let _ = self.status_tx.try_send(EngineStatus::RenderProgress {
                job_id: self.job.job_id.clone(),
                fraction: fraction as f32,
            });
        }
        Ok(())
    }

    /// Hand the engine back: silence and reset the devices, return plugins to realtime, restore
    /// the playhead, then let the live callback run again.
    fn end(&mut self) {
        {
            let mut state = lock(self.state);
            self.block_clock.end_offline();
            state.set_is_playing(false);
            reset_engine_devices(&mut state);
            state.set_current_tick(self.saved_tick);
            state.set_fractional_tick_accumulator(0.0);
            state.dispatch_playhead_tick.store(false, Ordering::Release);
        }
        for plugin in &self.plugins {
            if let Err(e) = plugin.set_render_mode(false) {
                warn!(
                    "Couldn't switch plugin {} back to realtime rendering: {}",
                    plugin.device_name(),
                    e
                );
            }
            if let Err(e) = plugin.reset() {
                warn!(
                    "Couldn't reset plugin {} after rendering: {}",
                    plugin.device_name(),
                    e
                );
            }
        }
        lock(self.state).rendering.store(false, Ordering::Release);
        let _ = self
            .status_tx
            .send(EngineStatus::PlayheadUpdate(self.saved_tick));
    }
}

/// Release held clip notes, reset every device (nested ones included), and forget clip playback
/// positions and scheduled MIDI. Plugins get a fire-and-forget reset here; the render also waits
/// for one.
fn reset_engine_devices(state: &mut EngineState) {
    for channel in state.channels.values_mut() {
        channel.release_clip_notes();
        while channel.midi_queue.pop().is_some() {}
        channel.scheduled_midi_events.clear();
        container::visit_devices_mut(&mut channel.devices, &mut |_, device| device.reset());
    }
    for track in state.tracks.values_mut() {
        for instance in &mut track.clip_instances {
            instance.playback_position = None;
        }
    }
}

/// Peak of the master over the block's first `frames` frames.
fn master_peak(state: &EngineState, frames: usize) -> f32 {
    state
        .channels
        .get(&MASTER_CHANNEL_ID)
        .map_or(0.0, |master| {
            master.buffer_left[..frames]
                .iter()
                .chain(&master.buffer_right[..frames])
                .fold(0.0f32, |peak, &s| peak.max(s.abs()))
        })
}

/// The first thing still loading, or None when the job can start. A device that failed to load
/// or crashed fails the job; bypassed and deactivated devices are ignored.
fn find_unready(state: &mut EngineState, job: &RenderJob) -> Result<Option<String>, String> {
    let mut pending = None;
    let mut failure = None;
    for channel in state.channels.values_mut() {
        let channel_name = &channel.name;
        container::visit_devices_mut(&mut channel.devices, &mut |_, device| {
            if failure.is_some() || !device.is_enabled() || !device.is_active() {
                return;
            }
            let Some(label) = device.loading_state() else {
                return;
            };
            let what = format!("{} on channel '{}'", device.device_name(), channel_name);
            if label == "loading" {
                pending.get_or_insert(what);
            } else if let Some(reason) = label.strip_prefix("failed:") {
                failure = Some(format!("{} failed to load: {}", what, reason));
            } else if let Some(reason) = label.strip_prefix("crashed:") {
                failure = Some(format!("{} crashed: {}", what, reason));
            }
        });
    }
    if let Some(failure) = failure {
        return Err(failure);
    }

    for track in state.tracks.values() {
        for instance in &track.clip_instances {
            let in_range =
                instance.start_tick < job.end_tick && instance.end_tick() > job.start_tick;
            if instance.muted || !in_range {
                continue;
            }
            let Some(clip) = state.clips.get(&instance.clip_id) else {
                continue;
            };
            if clip.clip_type != ClipType::Audio {
                continue;
            }
            match &clip.load_state {
                ClipLoadState::Loading { .. } => {
                    pending.get_or_insert_with(|| format!("audio clip '{}'", clip.name));
                }
                ClipLoadState::Failed { message, .. } => {
                    return Err(format!(
                        "audio clip '{}' failed to load: {}",
                        clip.name, message
                    ));
                }
                ClipLoadState::Unloaded | ClipLoadState::Ready { .. } => {}
            }
        }
    }
    Ok(pending)
}

#[cfg(test)]
mod tests {
    use super::super::RenderJob;
    use super::*;
    use crate::audio::devices::{
        AudioDevice, DeviceCategory, DeviceVariant, ParamId, ParamInfo, ParamValue, PolySynthDevice,
    };
    use crate::audio::stream::MAX_BLOCK_FRAMES;
    use crate::audio::types::{Channel, Clip, ClipInstance, ClipNote, Track};
    use std::path::Path;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    const SR: f32 = 48_000.0;
    /// One bar of 4/4 at 960 PPQ; two seconds (96 000 frames) at the default 120 BPM.
    const BAR: Tick = 3840;

    /// A project with a polysynth on channel 2 playing `notes` as (start tick, length, pitch)
    /// from a clip placed at tick 0 and lasting `length` ticks.
    fn project(notes: &[(Tick, Tick, u8)], length: Tick) -> Mutex<EngineState> {
        let mut state = EngineState::default();
        state.device_sample_rate = SR;
        state.ensure_master_channel(MAX_BLOCK_FRAMES);

        let mut channel = Channel::new(2, "Synth".to_string(), MAX_BLOCK_FRAMES, SR);
        let mut synth = PolySynthDevice::new(SR);
        synth.prepare(SR, MAX_BLOCK_FRAMES);
        channel.devices.push(Box::new(synth));
        state.channels.insert(2, channel);

        let mut clip = Clip::new("c".to_string(), "Clip".to_string(), ClipType::Midi);
        for (i, &(start_tick, duration_ticks, note)) in notes.iter().enumerate() {
            clip.midi_notes.push(ClipNote {
                id: i as _,
                note,
                velocity: 100,
                start_tick,
                duration_ticks,
            });
        }
        clip.content_length_ticks = length;
        state.clips.insert("c".to_string(), clip);
        let mut track = Track::new(1, 2);
        track.clip_instances.push(ClipInstance::new(
            "i".to_string(),
            "c".to_string(),
            0,
            length,
        ));
        state.tracks.insert(1, track);
        Mutex::new(state)
    }

    fn master_job(dir: &Path, name: &str, start: Tick, end: Tick, tail: RenderTail) -> RenderJob {
        let mut job = RenderJob::new(name, start, end);
        job.tail = tail;
        job.outputs.master = Some(dir.join(format!("{}.wav", name)));
        job
    }

    fn read_wav(path: &Path) -> Vec<f32> {
        hound::WavReader::open(path)
            .unwrap()
            .samples::<f32>()
            .map(Result::unwrap)
            .collect()
    }

    fn render(state: &Mutex<EngineState>, job: &RenderJob) -> Result<Vec<PathBuf>, RenderError> {
        let (status_tx, _status_rx) = crossbeam::channel::unbounded();
        run_render(job, state, &status_tx)
    }

    #[test]
    fn render_covers_the_range_plus_the_tail() {
        let dir = tempfile::tempdir().unwrap();
        let state = project(&[(0, 960, 60), (1920, 960, 64)], BAR);
        let job = master_job(dir.path(), "mix", 0, BAR, RenderTail::Seconds(0.5));

        let outputs = render(&state, &job).unwrap();
        assert_eq!(outputs, vec![dir.path().join("mix.wav")]);
        let samples = read_wav(&outputs[0]);
        let frames = samples.len() as i64 / 2;
        // Two seconds of range plus half a second of tail; the range stops on the frame
        // before the end tick would fire, which can be one short of the exact length.
        assert!((frames - 120_000).abs() <= 1, "{frames} frames");
        assert!(
            samples.iter().any(|s| s.abs() > 0.01),
            "the synth is audible"
        );
        assert!(!dir.path().join("mix.wav.part").exists());
    }

    #[test]
    fn two_renders_of_a_range_are_identical() {
        let dir = tempfile::tempdir().unwrap();
        let state = project(&[(0, 1440, 48), (960, 1920, 55), (2880, 960, 67)], BAR);
        let first = master_job(dir.path(), "a", 960, BAR, RenderTail::Seconds(1.0));
        let second = master_job(dir.path(), "b", 960, BAR, RenderTail::Seconds(1.0));

        let a = read_wav(&render(&state, &first).unwrap()[0]);
        // Live playback between the renders, still sounding when the second one starts, must
        // not change it.
        {
            let (status_tx, _status_rx) = crossbeam::channel::unbounded();
            let mut state = state.lock().unwrap();
            state.set_current_tick(480);
            state.set_is_playing(true);
            state.request_playhead_midi_dispatch();
            let mut out = vec![0.0; 1024];
            for _ in 0..40 {
                for channel in state.channels.values_mut() {
                    channel.clear_buffers();
                }
                process_audio(&mut state, 512, SR, Instant::now());
                mix_and_output(&mut state, &mut out, 2, 512, &status_tx);
            }
            assert!(
                out.iter().any(|s| s.abs() > 0.01),
                "live playback is sounding"
            );
        }
        let b = read_wav(&render(&state, &second).unwrap()[0]);
        assert_eq!(a.len(), b.len());
        assert!(a == b, "renders differ");
    }

    #[test]
    fn a_note_on_the_end_tick_is_not_rendered() {
        let dir = tempfile::tempdir().unwrap();
        let state = project(&[(BAR, 960, 60)], 2 * BAR);
        let job = master_job(dir.path(), "mix", 0, BAR, RenderTail::Seconds(0.5));

        let samples = read_wav(&render(&state, &job).unwrap()[0]);
        assert!(
            samples.iter().all(|&s| s == 0.0),
            "the next bar's note leaked in"
        );
    }

    #[test]
    fn until_silent_tail_stops_after_the_release() {
        let dir = tempfile::tempdir().unwrap();
        let state = project(&[(0, 960, 60)], BAR);
        let job = master_job(
            dir.path(),
            "mix",
            0,
            BAR,
            RenderTail::UntilSilent { max_seconds: 20.0 },
        );

        let frames = read_wav(&render(&state, &job).unwrap()[0]).len() / 2;
        let hold = (SILENCE_HOLD.as_secs_f32() * SR) as usize;
        assert!(frames >= 96_000 + hold - 1, "{frames} frames");
        assert!(
            frames < 96_000 + 10 * SR as usize,
            "{frames} frames: never went silent"
        );
    }

    #[test]
    fn stems_have_the_same_length_as_the_master() {
        let dir = tempfile::tempdir().unwrap();
        let state = project(&[(0, 960, 60)], BAR);
        let mut job = master_job(dir.path(), "mix", 0, BAR, RenderTail::Seconds(0.25));
        job.outputs.stems.push((2, dir.path().join("synth.wav")));

        let outputs = render(&state, &job).unwrap();
        assert_eq!(outputs.len(), 2);
        let master = read_wav(&outputs[0]);
        let stem = read_wav(&outputs[1]);
        assert_eq!(master.len(), stem.len());
        assert!(stem.iter().any(|s| s.abs() > 0.01));

        job.outputs.stems[0].0 = 42;
        let error = render(&state, &job).unwrap_err();
        assert_eq!(
            error,
            RenderError::Failed("channel 42 doesn't exist".into())
        );
    }

    /// Effect that requests cancellation of the job after it has processed `after` blocks.
    struct Canceller {
        cancel: Arc<AtomicBool>,
        blocks: usize,
        after: usize,
    }

    impl AudioDevice for Canceller {
        fn process_block(&mut self, inputs: &[f32], outputs: &mut [f32], sample_count: usize) {
            outputs[..sample_count * 2].copy_from_slice(&inputs[..sample_count * 2]);
            self.blocks += 1;
            if self.blocks == self.after {
                self.cancel.store(true, Ordering::Release);
            }
        }
        fn send_midi_event(&mut self, _: u8, _: u8, _: bool, _: usize) {}
        fn set_parameter(&mut self, _: ParamId, _: ParamValue) {}
        fn get_parameter(&self, _: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.canceller"
        }
        fn device_name(&self) -> &str {
            "Canceller"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Effect
        }
        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }
        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }
        fn reset(&mut self) {}
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    #[test]
    fn cancelling_stops_and_hands_the_engine_back() {
        let dir = tempfile::tempdir().unwrap();
        let state = project(&[(0, 960, 60)], BAR);
        let job = master_job(dir.path(), "mix", 0, BAR, RenderTail::Seconds(1.0));
        {
            let mut state = state.lock().unwrap();
            state.set_current_tick(1234);
            state.set_is_playing(true);
            state
                .channels
                .get_mut(&2)
                .unwrap()
                .devices
                .push(Box::new(Canceller {
                    cancel: Arc::clone(&job.cancel),
                    blocks: 0,
                    after: 3,
                }));
        }

        assert_eq!(render(&state, &job), Err(RenderError::Cancelled));
        let state = state.lock().unwrap();
        assert_eq!(state.get_current_tick(), 1234, "playhead restored");
        assert!(!state.get_is_playing(), "the transport stays stopped");
        assert!(!state.is_rendering());
        assert!(!state.block_clock.is_offline());
        assert!(!dir.path().join("mix.wav").exists());
        assert!(!dir.path().join("mix.wav.part").exists());
    }

    /// Instrument stuck in a load state.
    struct Loading {
        label: &'static str,
        enabled: bool,
    }

    impl AudioDevice for Loading {
        fn process_block(&mut self, _: &[f32], _: &mut [f32], _: usize) {}
        fn send_midi_event(&mut self, _: u8, _: u8, _: bool, _: usize) {}
        fn set_parameter(&mut self, _: ParamId, _: ParamValue) {}
        fn get_parameter(&self, _: ParamId) -> Option<ParamValue> {
            None
        }
        fn device_id(&self) -> &str {
            "test.loading"
        }
        fn device_name(&self) -> &str {
            "Sampler"
        }
        fn device_category(&self) -> DeviceCategory {
            DeviceCategory::Instrument
        }
        fn device_variant(&self) -> DeviceVariant {
            DeviceVariant::BuiltIn
        }
        fn parameters(&self) -> Vec<ParamInfo> {
            Vec::new()
        }
        fn loading_state(&self) -> Option<String> {
            Some(self.label.to_string())
        }
        fn is_enabled(&self) -> bool {
            self.enabled
        }
        fn set_enabled(&mut self, enabled: bool) {
            self.enabled = enabled;
        }
        fn reset(&mut self) {}
        fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
            self
        }
    }

    #[test]
    fn a_failed_device_fails_the_render() {
        let dir = tempfile::tempdir().unwrap();
        let state = project(&[(0, 960, 60)], BAR);
        let mut channel = Channel::new(3, "Keys".to_string(), MAX_BLOCK_FRAMES, SR);
        channel.devices.push(Box::new(Loading {
            label: "failed:no such file",
            enabled: true,
        }));
        state.lock().unwrap().channels.insert(3, channel);

        let job = master_job(dir.path(), "mix", 0, BAR, RenderTail::Seconds(0.0));
        let error = render(&state, &job).unwrap_err().to_string();
        assert_eq!(
            error,
            "Sampler on channel 'Keys' failed to load: no such file"
        );
        assert!(!state.lock().unwrap().is_rendering());

        // Bypassed, it doesn't matter.
        state.lock().unwrap().channels.get_mut(&3).unwrap().devices[0].set_enabled(false);
        assert!(render(&state, &job).is_ok());
    }

    #[test]
    fn transport_commands_are_ignored_while_rendering() {
        use crate::audio::commands::{process_command, AudioCommand};
        let (status_tx, _status_rx) = crossbeam::channel::unbounded();
        let mut state = EngineState::default();
        state.rendering.store(true, Ordering::Release);
        assert!(process_command(&mut state, AudioCommand::Play, 64, &status_tx).is_none());
        assert!(!state.get_is_playing());
        process_command(&mut state, AudioCommand::Seek(960), 64, &status_tx);
        assert_eq!(state.get_current_tick(), 0);
    }
}
