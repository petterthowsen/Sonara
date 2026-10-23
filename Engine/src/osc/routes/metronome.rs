//! Metronome routes (spec 053): `/metronome/*`. Nothing goes back to Godot.
//!
//! - `/metronome/enabled i:on`
//! - `/metronome/sound i:sound f:tune_hz f:decay_s f:tone f:level_db f:emphasis_volume_db f:emphasis_pitch_st`
//! - `/metronome/pattern i:num i:den i:resolution i:level...` (no levels removes the pattern)
//! - `/metronome/clear`
//! - `/metronome/audition i:level`

use anyhow::Result;
use rosc::OscType;

use super::RouteCtx;
use crate::audio::metronome::pattern::{MAX_LEVEL, MAX_STEPS};
use crate::audio::metronome::{MetronomeSound, SoundKind};
use crate::audio::AudioCommand;
use crate::osc::parse::{ArgError, Args};

/// Arguments of `/metronome/sound`.
const SOUND_ARGS: usize = 7;
/// Arguments of `/metronome/pattern` before the levels: numerator, denominator, resolution.
const PATTERN_HEAD: usize = 3;

/// Handle metronome routes. Returns false for an address this area doesn't know, so the caller
/// can report it as unknown.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        ["metronome", "enabled"] => {
            cx.commands
                .send(AudioCommand::SetMetronomeEnabled(a.bool(0)?))?;
        }
        ["metronome", "sound"] => {
            a.exactly(SOUND_ARGS)?;
            let sound = MetronomeSound {
                kind: SoundKind::from_index(a.int(0)?),
                tune_hz: a.float_or_int(1)?,
                decay_s: a.float_or_int(2)?,
                tone: a.float_or_int(3)?,
                level_db: a.float_or_int(4)?,
                emphasis_volume_db: a.float_or_int(5)?,
                emphasis_pitch_st: a.float_or_int(6)?,
            };
            cx.commands.send(AudioCommand::SetMetronomeSound(sound))?;
        }
        ["metronome", "pattern"] => {
            let cmd = parse_pattern(&a)?;
            cx.commands.send(cmd)?;
        }
        ["metronome", "clear"] => {
            cx.commands.send(AudioCommand::ClearMetronomePatterns)?;
        }
        ["metronome", "audition"] => {
            let level = a.int(0)?;
            if !(1..=MAX_LEVEL as i32).contains(&level) {
                return Err(ArgError::invalid(
                    a.addr(),
                    format!("level {level} is not 1 to {MAX_LEVEL}"),
                )
                .into());
            }
            cx.commands
                .send(AudioCommand::MetronomeAudition(level as u8))?;
        }
        _ => return Ok(false),
    }
    Ok(true)
}

/// Read a `/metronome/pattern` message. The step count is checked against the signature when the
/// command is applied (the engine warns and ignores a mismatch); here only the shape and the
/// value ranges are.
fn parse_pattern(a: &Args) -> Result<AudioCommand, ArgError> {
    if a.len() < PATTERN_HEAD || a.len() > PATTERN_HEAD + MAX_STEPS {
        return Err(ArgError::invalid(
            a.addr(),
            format!(
                "expected {PATTERN_HEAD} to {} arguments, got {}",
                PATTERN_HEAD + MAX_STEPS,
                a.len()
            ),
        ));
    }
    let num = a.int(0)?;
    let den = a.int(1)?;
    let resolution = a.int(2)?;
    if !(1..=u16::MAX as i32).contains(&num) || !(1..=u16::MAX as i32).contains(&den) {
        return Err(ArgError::invalid(
            a.addr(),
            format!("signature {num}/{den} is out of range"),
        ));
    }
    if !(1..=u8::MAX as i32).contains(&resolution) {
        return Err(ArgError::invalid(
            a.addr(),
            format!("resolution {resolution} is out of range"),
        ));
    }
    let mut levels = Vec::with_capacity(a.len() - PATTERN_HEAD);
    for i in PATTERN_HEAD..a.len() {
        let level = a.int(i)?;
        if !(0..=MAX_LEVEL as i32).contains(&level) {
            return Err(ArgError::invalid(
                a.addr(),
                format!("argument {i}: level {level} is not 0 to {MAX_LEVEL}"),
            ));
        }
        levels.push(level as u8);
    }
    Ok(AudioCommand::SetMetronomePattern {
        num: num as u16,
        den: den as u16,
        resolution: resolution as u8,
        levels,
    })
}
