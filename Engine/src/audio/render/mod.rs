//! Offline rendering: export and stems now, mix analysis later (`docs/analyze-plan.md`).
//!
//! `process_audio` and `mix_and_output` only need a state, a buffer and a frame count, so the
//! audio callback is one caller and the render worker is another, with its own clock. A render
//! owns the devices and the transport while it runs: the live callback outputs silence and
//! transport commands are ignored, so device state is never shared between two clocks. The
//! worker locks the state for one block at a time, so the command thread stays responsive, and
//! writes files with the lock released.

mod wav;
mod worker;

use crossbeam::channel::Sender;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use tracing::{error, info};

use super::analysis::Resolution;
use super::commands::{EngineState, EngineStatus};
use super::stream::MAX_BLOCK_FRAMES;
use super::types::{ChannelId, Tick};

pub use worker::{run_render, RenderError};

/// Frames rendered per block when the job doesn't say.
pub const DEFAULT_BLOCK_FRAMES: usize = 512;

/// Smallest block a job may ask for.
pub const MIN_BLOCK_FRAMES: usize = 32;

/// Longest tail a job may ask for, in seconds.
pub const MAX_TAIL_SECONDS: f32 = 600.0;

/// What to render after the range ends, with the transport stopped and devices still running.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RenderTail {
    /// Exactly this many seconds.
    Seconds(f32),
    /// Until the master has been silent for `worker::SILENCE_HOLD`, at most `max_seconds`.
    UntilSilent { max_seconds: f32 },
}

impl RenderTail {
    /// The longest the tail can be, in seconds.
    pub fn max_seconds(&self) -> f32 {
        match *self {
            RenderTail::Seconds(seconds) => seconds,
            RenderTail::UntilSilent { max_seconds } => max_seconds,
        }
    }
}

/// Sample format of the WAV files a render writes. Integer formats are clipped to ±1.0 without
/// dither; float keeps overs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WavFormat {
    Int16,
    Int24,
    #[default]
    Float32,
}

impl WavFormat {
    /// The format for a bit depth: 16, 24, or 32 (float).
    pub fn from_bits(bits: i32) -> Option<Self> {
        match bits {
            16 => Some(WavFormat::Int16),
            24 => Some(WavFormat::Int24),
            32 => Some(WavFormat::Float32),
            _ => None,
        }
    }
}

/// Files a render writes. Stems are each channel's post-fader, post-pan output, the same audio
/// that channel sends on to its output (a muted channel, or one silenced by solo, is silent).
#[derive(Debug, Clone, Default)]
pub struct RenderOutputs {
    pub master: Option<PathBuf>,
    pub stems: Vec<(ChannelId, PathBuf)>,
    pub format: WavFormat,
}

impl RenderOutputs {
    /// Every path, master first, in the order `RenderDone` reports them.
    pub fn paths(&self) -> Vec<PathBuf> {
        self.master
            .iter()
            .cloned()
            .chain(self.stems.iter().map(|(_, path)| path.clone()))
            .collect()
    }
}

/// Where an analysis render starts relative to the analyzed range. Everything before the range
/// is rendered but not accumulated, so held notes, tails, LFO phase and compressor state are
/// right when the range begins.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PreRoll {
    /// From tick 0.
    #[default]
    FromStart,
    /// This many ticks before the range (clamped at tick 0).
    Ticks(Tick),
}

/// Which channels an analysis covers. The master is always analyzed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AnalysisTaps {
    /// Master only, plus these channels.
    Channels(Vec<ChannelId>),
    /// Master plus every channel that exists when the render starts.
    All,
}

/// Plain data for an analysis output, turned into an `Analyzer` by the worker. The job's
/// `[start_tick, end_tick)` is the analyzed range; the result is written as JSON to `path`.
#[derive(Debug, Clone)]
pub struct AnalysisSpec {
    pub taps: AnalysisTaps,
    pub resolution: Resolution,
    pub pre_roll: PreRoll,
    pub path: PathBuf,
}

/// One offline render: the range `[start_tick, end_tick)`, then the tail.
#[derive(Debug, Clone)]
pub struct RenderJob {
    /// Chosen by Godot; every status about the job carries it.
    pub job_id: String,
    pub start_tick: Tick,
    pub end_tick: Tick,
    pub tail: RenderTail,
    /// 0 renders at the engine's rate, the only rate supported so far.
    pub sample_rate: u32,
    pub block_frames: usize,
    pub outputs: RenderOutputs,
    /// Analyze the range as it renders; the result goes to `AnalysisSpec::path`.
    pub analysis: Option<AnalysisSpec>,
    /// Set by `CancelRender`; the worker checks it between blocks.
    pub cancel: Arc<AtomicBool>,
}

impl RenderJob {
    /// A job with no tail, at the engine rate and the default block size.
    pub fn new(job_id: impl Into<String>, start_tick: Tick, end_tick: Tick) -> Self {
        Self {
            job_id: job_id.into(),
            start_tick,
            end_tick,
            tail: RenderTail::Seconds(0.0),
            sample_rate: 0,
            block_frames: DEFAULT_BLOCK_FRAMES,
            outputs: RenderOutputs::default(),
            analysis: None,
            cancel: Arc::new(AtomicBool::new(false)),
        }
    }

    /// The tick rendering starts at: the range start, or earlier for an analysis pre-roll.
    pub fn render_start_tick(&self) -> Tick {
        match self.analysis.as_ref().map(|a| a.pre_roll) {
            Some(PreRoll::FromStart) => 0,
            Some(PreRoll::Ticks(ticks)) => (self.start_tick - ticks.max(0)).max(0),
            None => self.start_tick,
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Acquire)
    }

    /// Check the job against the engine running at `device_rate` Hz.
    pub fn validate(&self, device_rate: u32) -> Result<(), String> {
        if self.start_tick < 0 || self.end_tick <= self.start_tick {
            return Err(format!(
                "invalid range {}..{}: the end must come after the start",
                self.start_tick, self.end_tick
            ));
        }
        if self.sample_rate != 0 && self.sample_rate != device_rate {
            return Err(format!(
                "rendering at {} Hz isn't supported yet; the engine runs at {} Hz",
                self.sample_rate, device_rate
            ));
        }
        if !(MIN_BLOCK_FRAMES..=MAX_BLOCK_FRAMES).contains(&self.block_frames) {
            return Err(format!(
                "block size {} is outside {}–{}",
                self.block_frames, MIN_BLOCK_FRAMES, MAX_BLOCK_FRAMES
            ));
        }
        let tail = self.tail.max_seconds();
        if !tail.is_finite() || !(0.0..=MAX_TAIL_SECONDS).contains(&tail) {
            return Err(format!(
                "tail of {} s is outside 0–{} s",
                tail, MAX_TAIL_SECONDS
            ));
        }
        if self.outputs.master.is_none() && self.outputs.stems.is_empty() && self.analysis.is_none()
        {
            return Err("the job has no outputs".to_string());
        }
        let mut paths = self.outputs.paths();
        paths.extend(self.analysis.iter().map(|a| a.path.clone()));
        for (i, path) in paths.iter().enumerate() {
            if path.as_os_str().is_empty() {
                return Err("an output path is empty".to_string());
            }
            if paths[..i].contains(path) {
                return Err(format!("{} is used for two outputs", path.display()));
            }
        }
        Ok(())
    }
}

/// The running render, owned by the command thread. The worker thread reports the outcome
/// itself (`RenderDone` or `RenderFailed`).
pub struct RenderHandle {
    job_id: String,
    cancel: Arc<AtomicBool>,
    thread: JoinHandle<()>,
}

impl RenderHandle {
    /// Start rendering `job` on a new thread.
    pub fn spawn(
        job: RenderJob,
        state: Arc<Mutex<EngineState>>,
        status_tx: Sender<EngineStatus>,
    ) -> std::io::Result<Self> {
        let job_id = job.job_id.clone();
        let cancel = Arc::clone(&job.cancel);
        let thread = thread::Builder::new()
            .name("engine-render".to_string())
            .spawn(move || {
                let job_id = job.job_id.clone();
                let status = match run_render(&job, &state, &status_tx) {
                    Ok(outputs) => EngineStatus::RenderDone { job_id, outputs },
                    Err(e) => {
                        match &e {
                            RenderError::Cancelled => info!("Render {} cancelled", job_id),
                            RenderError::Failed(message) => {
                                error!("Render {} failed: {}", job_id, message)
                            }
                        }
                        EngineStatus::RenderFailed {
                            job_id,
                            error: e.to_string(),
                        }
                    }
                };
                let _ = status_tx.send(status);
            })?;
        Ok(Self {
            job_id,
            cancel,
            thread,
        })
    }

    pub fn job_id(&self) -> &str {
        &self.job_id
    }

    /// Ask the worker to stop after the current block.
    pub fn cancel(&self) {
        self.cancel.store(true, Ordering::Release);
    }

    /// True once the worker has restored the engine and reported the outcome.
    pub fn is_finished(&self) -> bool {
        self.thread.is_finished()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job_with_master() -> RenderJob {
        let mut job = RenderJob::new("j", 0, 3840);
        job.outputs.master = Some(PathBuf::from("/tmp/mix.wav"));
        job
    }

    #[test]
    fn validation_rejects_bad_jobs() {
        assert!(job_with_master().validate(48_000).is_ok());

        let mut job = job_with_master();
        job.end_tick = 0;
        assert!(job.validate(48_000).unwrap_err().contains("range"));

        let mut job = job_with_master();
        job.sample_rate = 44_100;
        assert!(job.validate(48_000).unwrap_err().contains("44100"));
        job.sample_rate = 48_000;
        assert!(job.validate(48_000).is_ok());

        let mut job = job_with_master();
        job.block_frames = 16;
        assert!(job.validate(48_000).is_err());

        let mut job = job_with_master();
        job.tail = RenderTail::UntilSilent {
            max_seconds: f32::NAN,
        };
        assert!(job.validate(48_000).is_err());

        let mut job = job_with_master();
        job.outputs.master = None;
        assert!(job.validate(48_000).unwrap_err().contains("no outputs"));

        let mut job = job_with_master();
        job.outputs.stems.push((2, PathBuf::from("/tmp/mix.wav")));
        assert!(job.validate(48_000).unwrap_err().contains("two outputs"));
    }
}
