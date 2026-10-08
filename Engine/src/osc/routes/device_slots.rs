//! Device sub-routes for the Sampler (zones, groups, focus, audition), Layer slots and Drum
//! Machine slots.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::OscType;
use tracing::warn;

use crate::audio::devices::sampler_zones::{GroupPlayMode, ZoneRanges, ZoneSettings};
use crate::audio::devices::DevicePath;
use crate::audio::AudioCommand;
use crate::osc::audio_files::{generate_device_request_id, is_audio_sample_path};
use crate::osc::parse::{osc_float, osc_int};
use crate::osc::server::OscServer;

impl OscServer {
    /// Handle the Sampler, Layer and Drum Machine sub-routes of a device address. Returns false
    /// for an action this area doesn't know.
    pub(super) fn route_device_slots(
        &self,
        channel_id: usize,
        device_path: DevicePath,
        action: &[&str],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
    ) -> Result<bool> {
        match action {
            // Sampler multisample (spec 023)
            ["multisample"] => match args.first().and_then(osc_int) {
                Some(on) => command_tx.send(AudioCommand::SetSamplerMode {
                    channel_id,
                    device_path,
                    multisample: on != 0,
                })?,
                None => warn!("multisample needs an int, got {:?}", args),
            },
            ["zone", zid, "set"] => match (zid.parse::<u32>(), parse_zone_set(args)) {
                (Ok(zone_id), Ok(settings)) => command_tx.send(AudioCommand::SetSamplerZone {
                    channel_id,
                    device_path,
                    zone_id,
                    settings,
                })?,
                (zone_id, settings) => warn!(
                    "Bad zone/{}/set on channel {} path {}: {:?} {:?}",
                    zid,
                    channel_id,
                    device_path,
                    zone_id.err(),
                    settings.err()
                ),
            },
            ["zone", zid, "load_file"] => match (zid.parse::<u32>(), args.first()) {
                (Ok(zone_id), Some(OscType::String(file_path)))
                    if is_audio_sample_path(file_path) =>
                {
                    let req_id = match args.get(1) {
                        Some(OscType::String(id)) if !id.is_empty() => id.clone(),
                        _ => generate_device_request_id(channel_id, &device_path),
                    };
                    self.begin_device_sample_load(
                        channel_id,
                        device_path,
                        Some(zone_id),
                        file_path.clone(),
                        req_id,
                        command_tx,
                    )?;
                }
                _ => warn!(
                    "Bad zone/{}/load_file on channel {} path {}: {:?}",
                    zid, channel_id, device_path, args
                ),
            },
            ["zone", zid, "remove"] => match zid.parse::<u32>() {
                Ok(zone_id) => command_tx.send(AudioCommand::RemoveSamplerZone {
                    channel_id,
                    device_path,
                    zone_id,
                })?,
                Err(_) => warn!("Bad zone id in zone/{}/remove", zid),
            },
            ["zone_group", gid, "set"] => match (gid.parse::<u32>(), parse_zone_group_set(args)) {
                (Ok(group_id), Ok((gain, mute, solo, play_mode))) => {
                    command_tx.send(AudioCommand::SetSamplerZoneGroup {
                        channel_id,
                        device_path,
                        group_id,
                        gain,
                        mute,
                        solo,
                        play_mode,
                    })?
                }
                (group_id, group) => warn!(
                    "Bad zone_group/{}/set on channel {} path {}: {:?} {:?}",
                    gid,
                    channel_id,
                    device_path,
                    group_id.err(),
                    group.err()
                ),
            },
            ["zone_group", gid, "remove"] => match gid.parse::<u32>() {
                Ok(group_id) => command_tx.send(AudioCommand::RemoveSamplerZoneGroup {
                    channel_id,
                    device_path,
                    group_id,
                })?,
                Err(_) => warn!("Bad group id in zone_group/{}/remove", gid),
            },
            ["focus_zone"] => match args.first().and_then(osc_int) {
                Some(zone_id) => command_tx.send(AudioCommand::SetSamplerFocus {
                    channel_id,
                    device_path,
                    zone_id: zone_id.clamp(0, u32::MAX as i64) as u32,
                })?,
                None => warn!("focus_zone needs an int, got {:?}", args),
            },
            ["audition"] => match (
                args.first().and_then(osc_int),
                args.get(1).and_then(osc_int),
                args.get(2).and_then(osc_int),
            ) {
                (Some(note), Some(velocity), Some(on)) => {
                    command_tx.send(AudioCommand::AuditionDevice {
                        channel_id,
                        device_path,
                        note: note.clamp(0, 127) as u8,
                        velocity: velocity.clamp(0, 127) as u8,
                        is_note_on: on != 0,
                    })?
                }
                _ => warn!("audition needs note velocity on, got {:?}", args),
            },
            ["slot", slot_str, "volume"] => {
                if let (Ok(slot), Some(OscType::Float(volume))) =
                    (slot_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetLayerSlotVolume {
                        channel_id,
                        device_path,
                        slot,
                        volume: *volume,
                    })?;
                }
            }
            ["slot", slot_str, "mute"] => {
                if let (Ok(slot), Some(OscType::Int(mute))) =
                    (slot_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetLayerSlotMute {
                        channel_id,
                        device_path,
                        slot,
                        mute: *mute != 0,
                    })?;
                }
            }
            ["slot", slot_str, "solo"] => {
                if let (Ok(slot), Some(OscType::Int(solo))) =
                    (slot_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetLayerSlotSolo {
                        channel_id,
                        device_path,
                        slot,
                        solo: *solo != 0,
                    })?;
                }
            }
            ["slot", slot_str, "note_map"] => match (slot_str.parse::<usize>(), args.first()) {
                (Ok(slot), Some(OscType::Blob(bytes))) if bytes.len() == 128 => {
                    let mut map = Box::new([0u8; 128]);
                    map.copy_from_slice(bytes);
                    command_tx.send(AudioCommand::SetLayerSlotNoteMap {
                        channel_id,
                        device_path,
                        slot,
                        map,
                    })?;
                }
                _ => warn!(
                    "Layer note_map on channel {} path {} slot {} needs a 128-byte blob",
                    channel_id, device_path, slot_str
                ),
            },
            ["slot", slot_str, "separate_out"] => {
                if let (Ok(slot), Some(OscType::Int(separate))) =
                    (slot_str.parse::<usize>(), args.first())
                {
                    command_tx.send(AudioCommand::SetLayerSlotSeparateOut {
                        channel_id,
                        device_path,
                        slot,
                        separate: *separate != 0,
                    })?;
                }
            }
            ["slot", slot_str, "audition"] => {
                if let (
                    Ok(slot),
                    Some(OscType::Int(note)),
                    Some(OscType::Int(velocity)),
                    Some(OscType::Int(on)),
                ) = (
                    slot_str.parse::<usize>(),
                    args.first(),
                    args.get(1),
                    args.get(2),
                ) {
                    command_tx.send(AudioCommand::AuditionLayerSlot {
                        channel_id,
                        device_path,
                        slot,
                        note: (*note).clamp(0, 127) as u8,
                        velocity: (*velocity).clamp(0, 127) as u8,
                        is_note_on: *on != 0,
                    })?;
                }
            }
            ["slot", slot_str, "note"] => {
                if let Ok(slot) = slot_str.parse::<usize>() {
                    let note = match args.first() {
                        Some(OscType::Int(n)) => Some(*n as u8),
                        Some(OscType::Float(n)) => Some(*n as u8),
                        _ => None,
                    };
                    if let Some(note) = note {
                        command_tx.send(AudioCommand::SetDrumSlotNote {
                            channel_id,
                            device_path,
                            slot,
                            note,
                        })?;
                    }
                }
            }
            ["slot", slot_str, "choke_targets"] => {
                match (slot_str.parse::<usize>(), args.first()) {
                    (Ok(slot), Some(OscType::Blob(bytes))) if bytes.len() == 16 => {
                        let mut le = [0u8; 16];
                        le.copy_from_slice(bytes);
                        command_tx.send(AudioCommand::SetDrumSlotChokeTargets {
                            channel_id,
                            device_path,
                            slot,
                            mask: u128::from_le_bytes(le),
                        })?;
                    }
                    _ => warn!(
                        "Drum choke_targets on channel {} path {} slot {} needs a 16-byte blob",
                        channel_id, device_path, slot_str
                    ),
                }
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
}

/// Argument count of `zone/{zid}/set`.
const ZONE_SET_ARGS: usize = 19;

/// Parse `zone/{zid}/set`: `key_lo key_hi vel_lo vel_hi root tune gain start end reverse
/// loop_mode loop_start loop_end crossfade key_fade_lo key_fade_hi vel_fade_lo vel_fade_hi
/// group_id` (see `docs/subsystems/osc-protocol.md`). Ranges are clamped and ordered, the rest
/// clamped into range.
fn parse_zone_set(args: &[OscType]) -> Result<ZoneSettings, String> {
    if args.len() < ZONE_SET_ARGS {
        return Err(format!(
            "expected {} args, got {}",
            ZONE_SET_ARGS,
            args.len()
        ));
    }
    let int = |i: usize| {
        osc_int(&args[i])
            .map(|v| v.clamp(i32::MIN as i64, i32::MAX as i64) as i32)
            .ok_or_else(|| format!("arg {} is not a number: {:?}", i, args[i]))
    };
    let float = |i: usize| {
        osc_float(&args[i]).ok_or_else(|| format!("arg {} is not a number: {:?}", i, args[i]))
    };
    Ok(ZoneSettings {
        ranges: ZoneRanges::new(
            (int(0)?, int(1)?),
            (int(2)?, int(3)?),
            (int(14)?, int(15)?),
            (int(16)?, int(17)?),
        ),
        root: int(4)?.clamp(0, 127) as u8,
        tune: float(5)?,
        gain: float(6)?,
        start: float(7)?,
        end: float(8)?,
        reverse: int(9)? != 0,
        loop_mode: int(10)?.clamp(0, 2) as u8,
        loop_start: float(11)?,
        loop_end: float(12)?,
        crossfade: float(13)?,
        group_id: int(18)?.max(0) as u32,
    }
    .sanitized())
}

/// Parse `zone_group/{gid}/set`: `gain mute solo play_mode`.
fn parse_zone_group_set(args: &[OscType]) -> Result<(f32, bool, bool, GroupPlayMode), String> {
    match (
        args.first().and_then(osc_float),
        args.get(1).and_then(osc_int),
        args.get(2).and_then(osc_int),
        args.get(3).and_then(osc_int),
    ) {
        (Some(gain), Some(mute), Some(solo), Some(mode)) => Ok((
            gain,
            mute != 0,
            solo != 0,
            GroupPlayMode::from_index(mode as i32),
        )),
        _ => Err(format!("expected gain mute solo play_mode, got {:?}", args)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn zone_args(values: [f32; 19]) -> Vec<rosc::OscType> {
        use rosc::OscType;
        // Ints where Godot sends ints (see parse_zone_set).
        const FLOATS: [usize; 7] = [5, 6, 7, 8, 11, 12, 13];
        values
            .iter()
            .enumerate()
            .map(|(i, v)| {
                if FLOATS.contains(&i) {
                    OscType::Float(*v)
                } else {
                    OscType::Int(*v as i32)
                }
            })
            .collect()
    }

    #[test]
    fn zone_osc_parses_nineteen_args() {
        use crate::audio::devices::sampler_zones::ZoneRanges;
        let args = zone_args([
            48.0, 62.0, 1.0, 64.0, 60.0, -1.5, 0.8, 0.1, 0.9, 1.0, 2.0, 0.3, 0.6, 0.25, 2.0, 3.0,
            0.0, 10.0, 4.0,
        ]);
        let s = parse_zone_set(&args).unwrap();
        assert_eq!(
            s.ranges,
            ZoneRanges::new((48, 62), (1, 64), (2, 3), (0, 10))
        );
        assert_eq!(s.root, 60);
        assert_eq!((s.tune, s.gain, s.start, s.end), (-1.5, 0.8, 0.1, 0.9));
        assert!(s.reverse);
        assert_eq!(s.loop_mode, 2);
        assert_eq!((s.loop_start, s.loop_end, s.crossfade), (0.3, 0.6, 0.25));
        assert_eq!(s.group_id, 4);
    }

    #[test]
    fn zone_osc_clamps_and_orders() {
        let args = zone_args([
            90.0, 300.0, 127.0, 0.0, 200.0, 99.0, -2.0, -1.0, 2.0, 0.0, 9.0, 0.0, 1.0, 5.0, 0.0,
            0.0, 0.0, 0.0, -3.0,
        ]);
        let s = parse_zone_set(&args).unwrap();
        assert_eq!((s.ranges.key_lo, s.ranges.key_hi), (90, 127));
        assert_eq!((s.ranges.vel_lo, s.ranges.vel_hi), (1, 127));
        assert_eq!(s.root, 127);
        assert_eq!((s.tune, s.gain, s.start, s.end), (48.0, 0.0, 0.0, 1.0));
        assert_eq!((s.loop_mode, s.crossfade, s.group_id), (2, 1.0, 0));
    }

    #[test]
    fn zone_osc_rejects_short_and_bad_args() {
        use rosc::OscType;
        let mut args = zone_args([0.0; 19]);
        assert!(parse_zone_set(&args[..18]).is_err());
        args[3] = OscType::String("loud".into());
        assert!(parse_zone_set(&args).is_err());
        let group = [
            OscType::Float(0.5),
            OscType::Int(0),
            OscType::Int(1),
            OscType::Int(1),
        ];
        let (gain, mute, solo, mode) = parse_zone_group_set(&group).unwrap();
        assert_eq!((gain, mute, solo), (0.5, false, true));
        assert_eq!(
            mode,
            crate::audio::devices::sampler_zones::GroupPlayMode::RoundRobin
        );
        assert!(parse_zone_group_set(&group[..3]).is_err());
    }
}
