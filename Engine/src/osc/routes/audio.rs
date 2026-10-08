//! Audio device routes: `/audio/devices/*` and `/audio/config/*`.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::OscType;
use tracing::warn;

use crate::audio::AudioCommand;
use crate::osc::server::OscServer;

impl OscServer {
    /// Handle audio device routes: `/audio/devices/*` and `/audio/config/*`. Returns false for an address this area doesn't
    /// know, so the caller can try the next area or report an unknown address.
    pub(super) fn route_audio(
        &self,
        parts: &[&str],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
    ) -> Result<bool> {
        match parts {
            // Audio device settings (Phase 7)
            ["audio", "devices", "request"] => {
                command_tx.send(AudioCommand::RequestAudioDevices)?;
            }
            ["audio", "config", "request"] => {
                command_tx.send(AudioCommand::RequestAudioConfig)?;
            }
            // /audio/config/set <device:s> <rate:i> <buffer:i> — device "" is the default.
            ["audio", "config", "set"] => match parse_audio_config(args) {
                Ok(command) => command_tx.send(command)?,
                Err(e) => warn!("Ignoring /audio/config/set: {}", e),
            },
            _ => return Ok(false),
        }
        Ok(true)
    }
}

/// Parse `/audio/config/set <device:s> <rate:i> <buffer:i>`.
fn parse_audio_config(args: &[OscType]) -> Result<AudioCommand, String> {
    match args {
        [OscType::String(device), OscType::Int(rate), OscType::Int(buffer), ..]
            if *rate >= 0 && *buffer > 0 =>
        {
            Ok(AudioCommand::SetAudioConfig {
                device: device.clone(),
                sample_rate: *rate as u32,
                period_frames: *buffer as u32,
            })
        }
        _ => Err(format!(
            "expected (device:s, rate:i, buffer:i), got {:?}",
            args
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::osc::parse::test_support::string;

    #[test]
    fn audio_config_set_parses_device_rate_and_buffer() {
        match parse_audio_config(&[
            string("hw:CARD=USB"),
            OscType::Int(44_100),
            OscType::Int(256),
        ]) {
            Ok(AudioCommand::SetAudioConfig {
                device,
                sample_rate,
                period_frames,
            }) => {
                assert_eq!(device, "hw:CARD=USB");
                assert_eq!(sample_rate, 44_100);
                assert_eq!(period_frames, 256);
            }
            other => panic!("unexpected {:?}", other),
        }
        assert!(parse_audio_config(&[string(""), OscType::Int(48_000)]).is_err());
        assert!(parse_audio_config(&[string(""), OscType::Int(48_000), OscType::Int(0)]).is_err());
        assert!(parse_audio_config(&[OscType::Int(1), OscType::Int(2), OscType::Int(3)]).is_err());
    }
}
