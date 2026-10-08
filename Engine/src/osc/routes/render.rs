//! Render routes: `/render/*`.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::OscType;
use tracing::warn;

use crate::audio::AudioCommand;
use crate::audio::EngineStatus;
use crate::osc::server::OscServer;

impl OscServer {
    /// Handle render routes: `/render/*`. Returns false for an address this area doesn't
    /// know, so the caller can try the next area or report an unknown address.
    pub(super) fn route_render(
        &self,
        parts: &[&str],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
    ) -> Result<bool> {
        match parts {
            ["render", "start"] => match parse_render_start(args) {
                Ok(job) => command_tx.send(AudioCommand::StartRender(job))?,
                Err(e) => {
                    warn!("Rejecting /render/start: {}", e);
                    let job_id = match args.first() {
                        Some(OscType::String(id)) => id.clone(),
                        _ => String::new(),
                    };
                    Self::send_status_update(
                        &self.socket,
                        self.client_port,
                        EngineStatus::RenderFailed {
                            job_id,
                            error: format!("invalid /render/start: {}", e),
                        },
                    );
                }
            },
            ["render", "analyze"] => match parse_render_analyze(args) {
                Ok(job) => command_tx.send(AudioCommand::StartRender(job))?,
                Err(e) => {
                    warn!("Rejecting /render/analyze: {}", e);
                    let job_id = match args.first() {
                        Some(OscType::String(id)) => id.clone(),
                        _ => String::new(),
                    };
                    Self::send_status_update(
                        &self.socket,
                        self.client_port,
                        EngineStatus::RenderFailed {
                            job_id,
                            error: format!("invalid /render/analyze: {}", e),
                        },
                    );
                }
            },
            ["render", "cancel"] => match args.first() {
                Some(OscType::String(job_id)) => command_tx.send(AudioCommand::CancelRender {
                    job_id: job_id.clone(),
                })?,
                _ => warn!("Ignoring /render/cancel without a job id"),
            },
            _ => return Ok(false),
        }
        Ok(true)
    }
}

/// Parse `/render/start <job_id:s> <start_tick:i> <end_tick:i> <tail_seconds:f>
/// <until_silent:i> <master_path:s> <bit_depth:i> <sample_rate:i> <block_frames:i>
/// [<channel_id:i> <stem_path:s>]*`. An empty master path writes no master; a sample rate or
/// block size of 0 uses the default. The job itself is validated by the render worker.
fn parse_render_start(args: &[OscType]) -> Result<crate::audio::render::RenderJob, String> {
    use crate::audio::render::{RenderJob, RenderTail, WavFormat, DEFAULT_BLOCK_FRAMES};

    let tick = |arg: &OscType| match arg {
        OscType::Int(value) => Some(*value as i64),
        OscType::Long(value) => Some(*value),
        _ => None,
    };
    let [OscType::String(job_id), start, end, OscType::Float(tail_seconds), OscType::Int(until_silent), OscType::String(master), OscType::Int(bit_depth), OscType::Int(sample_rate), OscType::Int(block_frames), stems @ ..] =
        args
    else {
        return Err(format!(
            "expected (job_id:s, start_tick:i, end_tick:i, tail_seconds:f, until_silent:i, \
             master_path:s, bit_depth:i, sample_rate:i, block_frames:i, [channel_id:i, \
             stem_path:s]*), got {:?}",
            args
        ));
    };
    let (Some(start_tick), Some(end_tick)) = (tick(start), tick(end)) else {
        return Err("start_tick and end_tick must be integers".to_string());
    };
    if job_id.is_empty() {
        return Err("the job id is empty".to_string());
    }
    let mut job = RenderJob::new(job_id.clone(), start_tick, end_tick);
    job.tail = if *until_silent != 0 {
        RenderTail::UntilSilent {
            max_seconds: *tail_seconds,
        }
    } else {
        RenderTail::Seconds(*tail_seconds)
    };
    job.outputs.format = WavFormat::from_bits(*bit_depth)
        .ok_or_else(|| format!("bit depth {} isn't 16, 24 or 32", bit_depth))?;
    job.outputs.master = (!master.is_empty()).then(|| master.into());
    job.sample_rate = (*sample_rate).max(0) as u32;
    job.block_frames = if *block_frames > 0 {
        *block_frames as usize
    } else {
        DEFAULT_BLOCK_FRAMES
    };
    for pair in stems.chunks(2) {
        let [OscType::Int(channel_id), OscType::String(path)] = pair else {
            return Err("stems must be (channel_id:i, stem_path:s) pairs".to_string());
        };
        if *channel_id <= 0 {
            return Err(format!("invalid stem channel {}", channel_id));
        }
        job.outputs.stems.push((*channel_id as usize, path.into()));
    }
    Ok(job)
}

/// Parse `/render/analyze <job_id:s> <start_tick:i> <end_tick:i> <resolution:s> <pre_roll_ticks:i>
/// <result_path:s> <all_channels:i> [<channel_id:i>]*`. Resolution is "bar" or "beat"; a
/// negative pre-roll renders from tick 0. The master is always analyzed, plus every channel when
/// `all_channels` is non-zero, else the listed ones. Writes no WAV; `/render/done` carries the
/// result path.
fn parse_render_analyze(args: &[OscType]) -> Result<crate::audio::render::RenderJob, String> {
    use crate::audio::analysis::Resolution;
    use crate::audio::render::{AnalysisSpec, AnalysisTaps, PreRoll, RenderJob};

    let tick = |arg: &OscType| match arg {
        OscType::Int(value) => Some(*value as i64),
        OscType::Long(value) => Some(*value),
        _ => None,
    };
    let [OscType::String(job_id), start, end, OscType::String(resolution), pre_roll, OscType::String(path), OscType::Int(all), channels @ ..] =
        args
    else {
        return Err(format!(
            "expected (job_id:s, start_tick:i, end_tick:i, resolution:s, pre_roll_ticks:i, \
             result_path:s, all_channels:i, [channel_id:i]*), got {:?}",
            args
        ));
    };
    let (Some(start_tick), Some(end_tick), Some(pre_roll)) =
        (tick(start), tick(end), tick(pre_roll))
    else {
        return Err("start_tick, end_tick and pre_roll_ticks must be integers".to_string());
    };
    if job_id.is_empty() {
        return Err("the job id is empty".to_string());
    }
    let resolution = match resolution.as_str() {
        "bar" => Resolution::Bar,
        "beat" => Resolution::Beat,
        other => return Err(format!("resolution '{}' isn't bar or beat", other)),
    };
    let taps = if *all != 0 {
        AnalysisTaps::All
    } else {
        let mut ids = Vec::with_capacity(channels.len());
        for arg in channels {
            match arg {
                OscType::Int(id) if *id > 0 => ids.push(*id as usize),
                other => return Err(format!("invalid channel id {:?}", other)),
            }
        }
        AnalysisTaps::Channels(ids)
    };
    let mut job = RenderJob::new(job_id.clone(), start_tick, end_tick);
    job.analysis = Some(AnalysisSpec {
        taps,
        resolution,
        pre_roll: if pre_roll < 0 {
            PreRoll::FromStart
        } else {
            PreRoll::Ticks(pre_roll)
        },
        path: path.into(),
    });
    Ok(job)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::parse::test_support::string;

    #[test]
    fn render_analyze_parses() {
        use crate::audio::analysis::Resolution;
        use crate::audio::render::{AnalysisTaps, PreRoll};
        let mut args = vec![
            string("a1"),
            OscType::Int(3840),
            OscType::Int(7680),
            string("beat"),
            OscType::Int(-1),
            string("/tmp/a.json"),
            OscType::Int(0),
            OscType::Int(3),
            OscType::Int(4),
        ];
        let job = parse_render_analyze(&args).unwrap();
        let spec = job.analysis.as_ref().unwrap();
        assert_eq!((job.start_tick, job.end_tick), (3840, 7680));
        assert_eq!(spec.resolution, Resolution::Beat);
        assert_eq!(spec.pre_roll, PreRoll::FromStart);
        assert_eq!(spec.taps, AnalysisTaps::Channels(vec![3, 4]));
        assert_eq!(spec.path, std::path::PathBuf::from("/tmp/a.json"));
        assert_eq!(job.render_start_tick(), 0);
        assert!(job.validate(48_000).is_ok());

        args[4] = OscType::Int(960);
        args[6] = OscType::Int(1);
        let job = parse_render_analyze(&args).unwrap();
        assert_eq!(job.analysis.as_ref().unwrap().taps, AnalysisTaps::All);
        assert_eq!(job.render_start_tick(), 2880);

        args[3] = string("minute");
        assert!(parse_render_analyze(&args).is_err());
        assert!(parse_render_analyze(&args[..5]).is_err());
    }

    #[test]
    fn render_start_parses() {
        use crate::audio::render::{RenderTail, WavFormat};
        let mut args = vec![
            string("job1"),
            OscType::Int(0),
            OscType::Long(7680),
            OscType::Float(4.0),
            OscType::Int(1),
            string("/tmp/mix.wav"),
            OscType::Int(24),
            OscType::Int(0),
            OscType::Int(0),
            OscType::Int(3),
            string("/tmp/bass.wav"),
        ];
        let job = parse_render_start(&args).unwrap();
        assert_eq!(job.job_id, "job1");
        assert_eq!((job.start_tick, job.end_tick), (0, 7680));
        assert_eq!(job.tail, RenderTail::UntilSilent { max_seconds: 4.0 });
        assert_eq!(job.outputs.format, WavFormat::Int24);
        assert_eq!(job.outputs.master.as_deref(), Some("/tmp/mix.wav".as_ref()));
        assert_eq!(job.outputs.stems, vec![(3, "/tmp/bass.wav".into())]);
        assert_eq!(job.block_frames, crate::audio::render::DEFAULT_BLOCK_FRAMES);

        // No master, fixed tail
        args[4] = OscType::Int(0);
        args[5] = string("");
        let job = parse_render_start(&args).unwrap();
        assert_eq!(job.tail, RenderTail::Seconds(4.0));
        assert!(job.outputs.master.is_none());

        args[6] = OscType::Int(8);
        assert!(parse_render_start(&args).unwrap_err().contains("bit depth"));
        args[6] = OscType::Int(16);
        args.pop();
        assert!(parse_render_start(&args).unwrap_err().contains("pairs"));
        assert!(parse_render_start(&args[..4]).is_err());
    }
}
