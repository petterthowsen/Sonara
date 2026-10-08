//! Mixer channel commands: creation, fader/pan/mute/solo, routing, sends, and live MIDI input.

use crate::audio::channel::Channel;
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;
use std::time::Instant;
use tracing::{info, warn};

/// Create a mixer channel with the given id and name.
pub(super) fn create_channel(
    state: &mut EngineState,
    id: ChannelId,
    name: String,
    buffer_size: usize,
) {
    let channel = Channel::new(id, name.clone(), buffer_size, state.device_sample_rate);
    state.channels.insert(id, channel);
    info!(
        "Channel {} created: {} [total channels: {}]",
        id,
        name,
        state.channels.len()
    );
}

/// Set a channel's fader level in dB.
pub(super) fn set_channel_volume(state: &mut EngineState, id: ChannelId, db: f32) {
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.volume_db = db;
    }
}

/// Set a channel's pan: `pan_left` is the single pan value, or the left handle when `pan_right` is given (dual mode).
pub(super) fn set_channel_pan(
    state: &mut EngineState,
    id: ChannelId,
    pan_left: f32,
    pan_right: Option<f32>,
) {
    if let Some(channel) = state.channels.get_mut(&id) {
        if let Some(pan_r) = pan_right {
            // Dual pan mode (STEREO_DUAL)
            channel.pan_left = pan_left.clamp(-1.0, 1.0);
            channel.pan_right = pan_r.clamp(-1.0, 1.0);
        } else {
            // Single pan value (STEREO_COMBINED, STEREO_BALANCE, MONO)
            channel.pan = pan_left.clamp(-1.0, 1.0);
        }
    }
}

/// Set a channel's pan mode.
pub(super) fn set_channel_pan_mode(state: &mut EngineState, id: ChannelId, mode: i32) {
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.pan_mode = mode.into();
    }
}

/// Set the handle spread of a channel in combined pan mode.
pub(super) fn set_channel_pan_width(state: &mut EngineState, id: ChannelId, width: f32) {
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.pan_width = width.clamp(-1.0, 1.0);
    }
}

/// Mute or unmute a channel.
pub(super) fn set_channel_mute(state: &mut EngineState, id: ChannelId, mute: bool) {
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.mute = mute;
    }
}

/// Solo or unsolo a channel.
pub(super) fn set_channel_solo(state: &mut EngineState, id: ChannelId, solo: bool) {
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.solo = solo;
    }
}

/// Route a channel's output to another channel (or nowhere).
pub(super) fn set_channel_route(
    state: &mut EngineState,
    id: ChannelId,
    output_id: Option<ChannelId>,
) {
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.output_channel_id = output_id;
        info!("Channel {} routed to {:?}", id, output_id);
    } else {
        warn!("Cannot set route for channel {} (not found)", id);
    }
}

/// Map an extra device output bus of a channel to a target channel.
pub(super) fn set_aux_out(
    state: &mut EngineState,
    id: ChannelId,
    bus_index: usize,
    target_id: ChannelId,
) {
    if let Some(channel) = state.channels.get_mut(&id) {
        channel.set_aux_out(bus_index, target_id);
        info!("Channel {} extra out {} -> {}", id, bus_index, target_id);
    } else {
        warn!("Cannot set aux out for channel {} (not found)", id);
    }
}

/// Set the MIDI input device a channel listens to.
pub(super) fn set_midi_input_device(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_id: i32,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        channel.midi_routing.device_id = device_id;
        info!(
            "Channel {} MIDI input device set to {}",
            channel_id, device_id
        );
    } else {
        warn!(
            "Cannot set MIDI input device for channel {} (not found)",
            channel_id
        );
    }
}

/// Arm or disarm a channel for MIDI recording.
pub(super) fn set_record_armed(state: &mut EngineState, channel_id: ChannelId, armed: bool) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        channel.midi_routing.record_armed = armed;
        info!("Channel {} record armed: {}", channel_id, armed);
    } else {
        warn!(
            "Cannot set record armed for channel {} (not found)",
            channel_id
        );
    }
}

/// Queue a live MIDI event on a channel for the next audio callback.
pub(super) fn midi_event(
    state: &mut EngineState,
    channel_id: ChannelId,
    message_type: u8,
    midi_channel: u8,
    note: u8,
    velocity: u8,
    received_at: Instant,
) {
    use crate::audio::midi_types::{MidiEvent, MidiMessageType};

    if let Some(channel) = state.channels.get(&channel_id) {
        // Convert message type
        if let Some(msg_type) = MidiMessageType::from_u8(message_type) {
            // The audio thread turns received_at into a frame offset
            let event = MidiEvent {
                message_type: msg_type,
                midi_channel,
                note,
                velocity,
                received_at,
                frame_offset: 0,
            };

            // Push to channel's MIDI queue (lock-free)
            channel.midi_queue.push(event);
        } else {
            warn!("Unknown MIDI message type: {}", message_type);
        }
    } else {
        warn!(
            "Cannot send MIDI event to channel {} (not found)",
            channel_id
        );
    }
}

/// Add a send from a channel to a bus unless one to that target already exists.
pub(super) fn add_send(
    state: &mut EngineState,
    channel_id: ChannelId,
    target_channel_id: ChannelId,
    amount_db: f32,
    pre_fader: bool,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        // Check if send already exists to this target
        if channel
            .send_channels
            .iter()
            .any(|s| s.target_channel_id == target_channel_id)
        {
            warn!(
                "Send from channel {} to {} already exists",
                channel_id, target_channel_id
            );
        } else {
            channel.send_channels.push(crate::audio::channel::Send {
                target_channel_id,
                amount_db,
                pre_fader,
                muted: false,
            });
            info!(
                "Send added: channel {} -> {} ({:.1} dB, {})",
                channel_id,
                target_channel_id,
                amount_db,
                if pre_fader { "pre-fader" } else { "post-fader" }
            );
        }
    } else {
        warn!("Cannot add send: channel {} not found", channel_id);
    }
}

/// Remove a channel's send to `target_channel_id`.
pub(super) fn remove_send(
    state: &mut EngineState,
    channel_id: ChannelId,
    target_channel_id: ChannelId,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        let initial_len = channel.send_channels.len();
        channel
            .send_channels
            .retain(|s| s.target_channel_id != target_channel_id);
        if channel.send_channels.len() != initial_len {
            info!(
                "Send removed: channel {} -> {}",
                channel_id, target_channel_id
            );
        } else {
            warn!(
                "Send not found: channel {} -> {}",
                channel_id, target_channel_id
            );
        }
    } else {
        warn!("Cannot remove send: channel {} not found", channel_id);
    }
}

/// Set a send level in dB, clamped to -60..+12.
pub(super) fn set_send_amount(
    state: &mut EngineState,
    channel_id: ChannelId,
    target_channel_id: ChannelId,
    amount_db: f32,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(send) = channel
            .send_channels
            .iter_mut()
            .find(|s| s.target_channel_id == target_channel_id)
        {
            send.amount_db = amount_db.clamp(-60.0, 12.0);
            // Don't log every parameter change (too noisy)
        } else {
            warn!(
                "Cannot set send amount: send not found (channel {} -> {})",
                channel_id, target_channel_id
            );
        }
    } else {
        warn!("Cannot set send amount: channel {} not found", channel_id);
    }
}

/// Switch a send between pre- and post-fader.
pub(super) fn set_send_pre_fader(
    state: &mut EngineState,
    channel_id: ChannelId,
    target_channel_id: ChannelId,
    pre_fader: bool,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(send) = channel
            .send_channels
            .iter_mut()
            .find(|s| s.target_channel_id == target_channel_id)
        {
            send.pre_fader = pre_fader;
            info!(
                "Send pre-fader set: channel {} -> {} ({})",
                channel_id,
                target_channel_id,
                if pre_fader { "pre" } else { "post" }
            );
        } else {
            warn!(
                "Cannot set send pre-fader: send not found (channel {} -> {})",
                channel_id, target_channel_id
            );
        }
    } else {
        warn!(
            "Cannot set send pre-fader: channel {} not found",
            channel_id
        );
    }
}

/// Mute or unmute a send.
pub(super) fn set_send_mute(
    state: &mut EngineState,
    channel_id: ChannelId,
    target_channel_id: ChannelId,
    muted: bool,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(send) = channel
            .send_channels
            .iter_mut()
            .find(|s| s.target_channel_id == target_channel_id)
        {
            send.muted = muted;
            info!(
                "Send mute set: channel {} -> {} ({})",
                channel_id,
                target_channel_id,
                if muted { "muted" } else { "unmuted" }
            );
        } else {
            warn!(
                "Cannot set send mute: send not found (channel {} -> {})",
                channel_id, target_channel_id
            );
        }
    } else {
        warn!("Cannot set send mute: channel {} not found", channel_id);
    }
}

#[cfg(test)]
mod tests {
    use crate::audio::commands::{process_command, AudioCommand};
    use crate::audio::state::EngineState;

    #[test]
    fn pan_width_command_clamps() {
        let mut state = EngineState::default();
        let (status_tx, _status_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            &status_tx,
        );
        for (input, expected) in [(3.0, 1.0), (-3.0, -1.0), (0.4, 0.4)] {
            process_command(
                &mut state,
                AudioCommand::SetChannelPanWidth {
                    id: 2,
                    width: input,
                },
                128,
                &status_tx,
            );
            assert_eq!(state.channels[&2].pan_width, expected);
        }
    }
}
