//! Layer and Drum Machine slot commands.

use crate::audio::devices::DevicePath;
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;
use tracing::warn;

/// Set a Layer slot's volume from a normalized value.
pub(super) fn set_layer_slot_volume(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    volume: f32,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            if let Some(layer) = device
                .as_any_mut()
                .downcast_mut::<crate::audio::devices::LayerDevice>()
            {
                if !layer.set_slot_volume_normalized(slot, volume) {
                    warn!(
                        "Layer slot {} not found at channel {} path {}",
                        slot, channel_id, device_path
                    );
                }
            } else {
                warn!(
                    "Device at channel {} path {} is not a Layer",
                    channel_id, device_path
                );
            }
        }
    }
}

/// Mute or unmute a Layer slot.
pub(super) fn set_layer_slot_mute(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    mute: bool,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            if let Some(layer) = device
                .as_any_mut()
                .downcast_mut::<crate::audio::devices::LayerDevice>()
            {
                if !layer.set_slot_mute(slot, mute) {
                    warn!(
                        "Layer slot {} not found at channel {} path {}",
                        slot, channel_id, device_path
                    );
                }
            }
        }
    }
}

/// Solo or unsolo a Layer slot.
pub(super) fn set_layer_slot_solo(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    solo: bool,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            if let Some(layer) = device
                .as_any_mut()
                .downcast_mut::<crate::audio::devices::LayerDevice>()
            {
                if !layer.set_slot_solo(slot, solo) {
                    warn!(
                        "Layer slot {} not found at channel {} path {}",
                        slot, channel_id, device_path
                    );
                }
            }
        }
    }
}

/// Set the note a Drum Machine pad responds to.
pub(super) fn set_drum_slot_note(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    note: u8,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            if let Some(drum) = device
                .as_any_mut()
                .downcast_mut::<crate::audio::devices::DrumMachineDevice>()
            {
                if !drum.set_slot_note(slot, note) {
                    warn!(
                        "Drum slot {} note {} rejected at channel {} path {}",
                        slot, note, channel_id, device_path
                    );
                }
            } else {
                warn!(
                    "Device at channel {} path {} is not a Drum Machine",
                    channel_id, device_path
                );
            }
        }
    }
}

/// Set the notes a Drum Machine pad chokes.
pub(super) fn set_drum_slot_choke_targets(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    mask: u128,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            if let Some(drum) = device
                .as_any_mut()
                .downcast_mut::<crate::audio::devices::DrumMachineDevice>()
            {
                if !drum.set_slot_choke_targets(slot, mask) {
                    warn!(
                        "Drum slot {} choke targets {:#x} rejected at channel {} path {}",
                        slot, mask, channel_id, device_path
                    );
                }
            } else {
                warn!(
                    "Device at channel {} path {} is not a Drum Machine",
                    channel_id, device_path
                );
            }
        }
    }
}

/// Set a Layer slot's note map.
pub(super) fn set_layer_slot_note_map(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    map: Box<[u8; 128]>,
) {
    with_layer(state, channel_id, &device_path, slot, |layer| {
        layer.set_slot_note_map(slot, &map)
    })
}

/// Send a Layer slot to its own extra output.
pub(super) fn set_layer_slot_separate_out(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    separate: bool,
) {
    with_layer(state, channel_id, &device_path, slot, |layer| {
        layer.set_slot_separate_out(slot, separate)
    })
}

/// Audition a note on a single Layer slot.
pub(super) fn audition_layer_slot(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    note: u8,
    velocity: u8,
    is_note_on: bool,
) {
    with_layer(state, channel_id, &device_path, slot, |layer| {
        layer.audition_slot(slot, note, velocity, is_note_on)
    })
}

/// Run `apply` on the Layer at `device_path`, warning when the channel, device or slot is missing.
fn with_layer(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: &DevicePath,
    slot: usize,
    apply: impl FnOnce(&mut crate::audio::devices::LayerDevice) -> bool,
) {
    let Some(device) = state
        .channels
        .get_mut(&channel_id)
        .and_then(|channel| channel.device_at_path_mut(device_path))
    else {
        warn!("No device at channel {} path {}", channel_id, device_path);
        return;
    };
    let Some(layer) = device
        .as_any_mut()
        .downcast_mut::<crate::audio::devices::LayerDevice>()
    else {
        warn!(
            "Device at channel {} path {} is not a Layer",
            channel_id, device_path
        );
        return;
    };
    if !apply(layer) {
        warn!(
            "Layer slot {} not found at channel {} path {}",
            slot, channel_id, device_path
        );
    }
}
