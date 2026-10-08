//! Sampler commands: zones, groups, focus, and sample loading.

use super::{with_device, CommandEffects};
use crate::audio::devices::sampler_zones::{GroupPlayMode, ZoneSettings};
use crate::audio::devices::{DevicePath, SamplerDevice};
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;

/// Mark a sampler (or one of its zones) as loading a sample.
pub(super) fn begin_load_device_sample(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    zone_id: Option<u32>,
    req_id: String,
) {
    with_device::<SamplerDevice, _>(
        state,
        "begin load device sample",
        channel_id,
        &device_path,
        |sampler| match zone_id {
            Some(zone_id) => sampler.begin_zone_load(zone_id, req_id),
            None => sampler.begin_sample_load(req_id),
        },
    );
}

/// Hand decoded PCM to a sampler or one of its zones.
pub(super) fn load_device_sample(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    zone_id: Option<u32>,
    req_id: String,
    samples: Vec<f32>,
    sample_rate: u32,
    channels: usize,
    effects: &mut CommandEffects,
) {
    // If the sampler is missing, the PCM comes back unused and is freed after the lock.
    let mut pending = Some(samples);
    with_device::<SamplerDevice, _>(
        state,
        "load device sample",
        channel_id,
        &device_path,
        |sampler| {
            let samples = pending.take().expect("applied once");
            match zone_id {
                Some(zone_id) => {
                    sampler.set_zone_sample(zone_id, &req_id, samples, channels, sample_rate)
                }
                None => sampler.set_sample(&req_id, samples, channels, sample_rate),
            }
        },
    );
    if let Some(unused) = pending {
        effects.discard(unused);
    }
}

/// Tell a sampler (or one of its zones) its sample load failed.
pub(super) fn fail_device_sample_load(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    zone_id: Option<u32>,
    req_id: String,
    message: String,
) {
    with_device::<SamplerDevice, _>(
        state,
        "fail device sample load",
        channel_id,
        &device_path,
        |sampler| match zone_id {
            Some(zone_id) => sampler.fail_zone_load(zone_id, &req_id, &message),
            None => sampler.fail_sample_load(&req_id, &message),
        },
    );
}

/// Switch a sampler between single-sample and multisample mode.
pub(super) fn set_sampler_mode(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    multisample: bool,
) {
    with_device::<SamplerDevice, _>(
        state,
        "set sampler mode",
        channel_id,
        &device_path,
        |sampler| sampler.set_multisample(multisample),
    );
}

/// Create or update a sampler zone.
pub(super) fn set_sampler_zone(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    zone_id: u32,
    settings: ZoneSettings,
) {
    with_device::<SamplerDevice, _>(
        state,
        "set sampler zone",
        channel_id,
        &device_path,
        |sampler| sampler.set_zone(zone_id, &settings),
    );
}

/// Remove a sampler zone.
pub(super) fn remove_sampler_zone(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    zone_id: u32,
) {
    with_device::<SamplerDevice, _>(
        state,
        "remove sampler zone",
        channel_id,
        &device_path,
        |sampler| sampler.remove_zone(zone_id),
    );
}

/// Create or update a sampler zone group.
pub(super) fn set_sampler_zone_group(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    group_id: u32,
    gain: f32,
    mute: bool,
    solo: bool,
    play_mode: GroupPlayMode,
) {
    with_device::<SamplerDevice, _>(
        state,
        "set sampler zone group",
        channel_id,
        &device_path,
        |sampler| sampler.set_zone_group(group_id, gain, mute, solo, play_mode),
    );
}

/// Remove a sampler zone group.
pub(super) fn remove_sampler_zone_group(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    group_id: u32,
) {
    with_device::<SamplerDevice, _>(
        state,
        "remove sampler zone group",
        channel_id,
        &device_path,
        |sampler| sampler.remove_zone_group(group_id),
    );
}

/// Set the sampler zone that edits and auditions apply to.
pub(super) fn set_sampler_focus(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    zone_id: u32,
) {
    with_device::<SamplerDevice, _>(
        state,
        "set sampler focus",
        channel_id,
        &device_path,
        |sampler| sampler.set_focus(zone_id),
    );
}

#[cfg(test)]
mod tests {
    use crate::audio::commands::{process_command, AudioCommand, CommandEffects, EngineStatus};
    use crate::audio::devices::DevicePath;
    use crate::audio::state::EngineState;

    #[test]
    fn sampler_zone_commands_route_to_device() {
        use crate::audio::devices::sampler_zones::{ZoneRanges, ZoneSettings};
        let mut state = EngineState::default();
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        let run = |state: &mut EngineState, cmd| {
            // The sampler device sends its own statuses to `status_tx`; forward the command's
            // so the test reads one stream.
            let mut effects = CommandEffects::default();
            process_command(state, cmd, 128, &mut effects);
            for status in effects.statuses {
                let _ = status_tx.send(status);
            }
        };
        run(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
        );
        let sampler = crate::audio::devices::SamplerDevice::new(
            48_000.0,
            2,
            DevicePath::root(0),
            Some(status_tx.clone()),
        );
        state
            .channels
            .get_mut(&2)
            .unwrap()
            .devices
            .push(Box::new(sampler));
        let path = DevicePath::root(0);
        run(
            &mut state,
            AudioCommand::SetSamplerMode {
                channel_id: 2,
                device_path: path.clone(),
                multisample: true,
            },
        );
        run(
            &mut state,
            AudioCommand::SetSamplerZone {
                channel_id: 2,
                device_path: path.clone(),
                zone_id: 5,
                settings: ZoneSettings {
                    ranges: ZoneRanges::new((60, 72), (1, 127), (0, 0), (0, 0)),
                    ..ZoneSettings::default()
                },
            },
        );
        run(
            &mut state,
            AudioCommand::BeginLoadDeviceSample {
                channel_id: 2,
                device_path: path.clone(),
                zone_id: Some(5),
                req_id: "z5".to_string(),
            },
        );
        run(
            &mut state,
            AudioCommand::LoadDeviceSample {
                channel_id: 2,
                device_path: path.clone(),
                zone_id: Some(5),
                req_id: "z5".to_string(),
                samples: vec![0.5; 48_000],
                sample_rate: 48_000,
                channels: 1,
            },
        );
        let zone_states: Vec<(u32, String)> = status_rx
            .try_iter()
            .filter_map(|s| match s {
                EngineStatus::SamplerZoneLoadingState { zone_id, state, .. } => {
                    Some((zone_id, state))
                }
                _ => None,
            })
            .collect();
        assert_eq!(
            zone_states,
            vec![(5, "loading".to_string()), (5, "ready".to_string())]
        );

        let audition = |note, is_note_on| AudioCommand::AuditionDevice {
            channel_id: 2,
            device_path: DevicePath::root(0),
            note,
            velocity: 100,
            is_note_on,
        };
        let peak = |state: &mut EngineState| {
            let device = &mut state.channels.get_mut(&2).unwrap().devices[0];
            let mut out = vec![0.0f32; 512];
            device.process_block(&[0.0; 512], &mut out, 256);
            out.iter().fold(0.0f32, |m, x| m.max(x.abs()))
        };
        run(&mut state, audition(40, true));
        assert_eq!(peak(&mut state), 0.0, "outside the zone");
        run(&mut state, audition(64, true));
        assert!(peak(&mut state) > 0.1, "the zone plays");

        // state/get resends the zone's state; removing the zone silences it.
        run(
            &mut state,
            AudioCommand::GetDeviceState {
                channel_id: 2,
                device_path: path.clone(),
            },
        );
        assert!(status_rx.try_iter().any(|s| matches!(
            s,
            EngineStatus::SamplerZoneLoadingState { zone_id: 5, ref state, .. } if state == "ready"
        )));
        run(
            &mut state,
            AudioCommand::RemoveSamplerZone {
                channel_id: 2,
                device_path: path,
                zone_id: 5,
            },
        );
        peak(&mut state);
        assert_eq!(peak(&mut state), 0.0);
    }
}
