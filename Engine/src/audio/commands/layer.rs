//! Layer and Drum Machine slot commands.

use super::with_device;
use crate::audio::devices::{DevicePath, DrumMachineDevice, LayerDevice};
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
    with_layer(
        state,
        "set layer slot volume",
        channel_id,
        &device_path,
        slot,
        |layer| layer.set_slot_volume_normalized(slot, volume),
    )
}

/// Mute or unmute a Layer slot.
pub(super) fn set_layer_slot_mute(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    mute: bool,
) {
    with_layer(
        state,
        "set layer slot mute",
        channel_id,
        &device_path,
        slot,
        |layer| layer.set_slot_mute(slot, mute),
    )
}

/// Solo or unsolo a Layer slot.
pub(super) fn set_layer_slot_solo(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    solo: bool,
) {
    with_layer(
        state,
        "set layer slot solo",
        channel_id,
        &device_path,
        slot,
        |layer| layer.set_slot_solo(slot, solo),
    )
}

/// Set the note a Drum Machine pad responds to.
pub(super) fn set_drum_slot_note(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    note: u8,
) {
    let accepted = with_device::<DrumMachineDevice, _>(
        state,
        "set drum slot note",
        channel_id,
        &device_path,
        |drum| drum.set_slot_note(slot, note),
    );
    if accepted == Some(false) {
        warn!(
            "set drum slot note: slot {} note {} rejected at channel {} path {}",
            slot, note, channel_id, device_path
        );
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
    let accepted = with_device::<DrumMachineDevice, _>(
        state,
        "set drum slot choke targets",
        channel_id,
        &device_path,
        |drum| drum.set_slot_choke_targets(slot, mask),
    );
    if accepted == Some(false) {
        warn!(
            "set drum slot choke targets: slot {} targets {:#x} rejected at channel {} path {}",
            slot, mask, channel_id, device_path
        );
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
    with_layer(
        state,
        "set layer slot note map",
        channel_id,
        &device_path,
        slot,
        |layer| layer.set_slot_note_map(slot, &map),
    )
}

/// Send a Layer slot to its own extra output.
pub(super) fn set_layer_slot_separate_out(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    slot: usize,
    separate: bool,
) {
    with_layer(
        state,
        "set layer slot separate out",
        channel_id,
        &device_path,
        slot,
        |layer| layer.set_slot_separate_out(slot, separate),
    )
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
    with_layer(
        state,
        "audition layer slot",
        channel_id,
        &device_path,
        slot,
        |layer| layer.audition_slot(slot, note, velocity, is_note_on),
    )
}

/// Run `apply` on the Layer at `device_path`; `apply` returns false for a missing slot, which is
/// logged here together with the command's name.
fn with_layer(
    state: &mut EngineState,
    cmd: &str,
    channel_id: ChannelId,
    device_path: &DevicePath,
    slot: usize,
    apply: impl FnOnce(&mut LayerDevice) -> bool,
) {
    if with_device::<LayerDevice, _>(state, cmd, channel_id, device_path, apply) == Some(false) {
        warn!(
            "{}: slot {} not found at channel {} path {}",
            cmd, slot, channel_id, device_path
        );
    }
}
