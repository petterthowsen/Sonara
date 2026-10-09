//! Channel routes: `/channel/{id}/*` (the device routes are in `device.rs`).

use anyhow::Result;
use rosc::OscType;
use tracing::info;

use super::RouteCtx;
use crate::audio::AudioCommand;
use crate::osc::parse::{segment, Args};
use std::time::Instant;

/// Handle channel routes: `/channel/{id}/*` (the device routes are in `device.rs`). Returns false for an address this area doesn't
/// know, so the caller can try the next area or report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        // Channel management - path-based: /channel/{id}/{command}
        ["channel", id_str, "create"] => {
            let id: usize = segment(cx.addr, id_str)?;
            let name = a.string(0)?;
            info!("Create channel {} ({})", id, name);
            cx.commands.send(AudioCommand::CreateChannel {
                id,
                name: name.to_string(),
            })?;
        }
        ["channel", id_str, "remove"] => {
            let id: usize = segment(cx.addr, id_str)?;
            info!("Remove channel {}", id);
            cx.commands.send(AudioCommand::RemoveChannel { id })?;
        }
        ["channel", id_str, "volume"] => {
            let id: usize = segment(cx.addr, id_str)?;
            cx.commands.send(AudioCommand::SetChannelVolume {
                id,
                db: a.float(0)?,
            })?;
        }
        ["channel", id_str, "pan"] => {
            let id: usize = segment(cx.addr, id_str)?;
            // One pan value, or a left and a right one; a right value that isn't a float
            // reads as absent.
            cx.commands.send(AudioCommand::SetChannelPan {
                id,
                pan_left: a.float(0)?,
                pan_right: a.opt_float(1),
            })?;
        }
        ["channel", id_str, "pan_mode"] => {
            let id: usize = segment(cx.addr, id_str)?;
            cx.commands.send(AudioCommand::SetChannelPanMode {
                id,
                mode: a.int(0)?,
            })?;
        }
        ["channel", id_str, "pan_width"] => {
            let id: usize = segment(cx.addr, id_str)?;
            cx.commands.send(AudioCommand::SetChannelPanWidth {
                id,
                width: a.float(0)?,
            })?;
        }
        ["channel", id_str, "mute"] => {
            let id: usize = segment(cx.addr, id_str)?;
            cx.commands.send(AudioCommand::SetChannelMute {
                id,
                mute: a.bool(0)?,
            })?;
        }
        ["channel", id_str, "solo"] => {
            let id: usize = segment(cx.addr, id_str)?;
            cx.commands.send(AudioCommand::SetChannelSolo {
                id,
                solo: a.bool(0)?,
            })?;
        }
        ["channel", id_str, "route"] => {
            let id: usize = segment(cx.addr, id_str)?;
            let output_id = a.int(0)?;
            let output = if output_id < 0 {
                None
            } else {
                Some(output_id as usize)
            };
            cx.commands.send(AudioCommand::SetChannelRoute {
                id,
                output_id: output,
            })?;
        }
        ["channel", id_str, "aux_out"] => {
            let id: usize = segment(cx.addr, id_str)?;
            cx.commands.send(AudioCommand::SetAuxOut {
                id,
                bus_index: a.non_negative(0)?,
                target_id: a.non_negative(1)?,
            })?;
        }

        // MIDI routing configuration
        ["channel", id_str, "midi_input_device"] => {
            let id: usize = segment(cx.addr, id_str)?;
            cx.commands.send(AudioCommand::SetMidiInputDevice {
                channel_id: id,
                device_id: a.int(0)?,
            })?;
        }
        ["channel", id_str, "record_armed"] => {
            let id: usize = segment(cx.addr, id_str)?;
            cx.commands.send(AudioCommand::SetRecordArmed {
                channel_id: id,
                armed: a.bool(0)?,
            })?;
        }

        // MIDI events - path-based: /channel/{id}/midi_event
        ["channel", id_str, "midi_event"] => {
            let channel_id: usize = segment(cx.addr, id_str)?;
            // Args: channel_id, message, midi_channel, pitch, velocity, timestamp_us
            // Godot's timestamp is on a different clock, so the engine stamps arrival instead
            let received_at = Instant::now();
            a.int(0)?; // channel_id (redundant, already in path)
            cx.commands.send(AudioCommand::MidiEvent {
                channel_id,
                message_type: a.int(1)? as u8,
                midi_channel: a.int(2)? as u8,
                note: a.int(3)? as u8,
                velocity: a.int(4)? as u8,
                received_at,
            })?;
        }
        ["channel", id_str, "midi_cc"] => {
            let channel_id: usize = segment(cx.addr, id_str)?;
            // Args: channel_id, midi_channel, cc_number, cc_value, timestamp_us
            // Godot's timestamp is on a different clock, so the engine stamps arrival instead
            let received_at = Instant::now();
            a.int(0)?; // channel_id (redundant)
            cx.commands.send(AudioCommand::MidiEvent {
                channel_id,
                message_type: 11, // MIDI_MESSAGE_CONTROL_CHANGE
                midi_channel: a.int(1)? as u8,
                note: a.int(2)? as u8,
                velocity: a.int(3)? as u8,
                received_at,
            })?;
        }

        // Send management - path-based: /channel/{id}/send/{target_id}/{command}
        ["channel", id_str, "send", target_str, "add"] => {
            let channel_id: usize = segment(cx.addr, id_str)?;
            let target_channel_id: usize = segment(cx.addr, target_str)?;
            // Args: amount_db (float or int, default -12 dB), pre_fader (int 0/1, default
            // post-fader). A wrongly typed optional value takes its default.
            cx.commands.send(AudioCommand::AddSend {
                channel_id,
                target_channel_id,
                amount_db: a.opt_float_or_int(0).unwrap_or(-12.0),
                pre_fader: a.opt_bool(1).unwrap_or(false),
            })?;
        }
        ["channel", id_str, "send", target_str, "remove"] => {
            let channel_id: usize = segment(cx.addr, id_str)?;
            let target_channel_id: usize = segment(cx.addr, target_str)?;
            cx.commands.send(AudioCommand::RemoveSend {
                channel_id,
                target_channel_id,
            })?;
        }
        ["channel", id_str, "send", target_str, "amount"] => {
            let channel_id: usize = segment(cx.addr, id_str)?;
            let target_channel_id: usize = segment(cx.addr, target_str)?;
            cx.commands.send(AudioCommand::SetSendAmount {
                channel_id,
                target_channel_id,
                amount_db: a.float_or_int(0)?,
            })?;
        }
        ["channel", id_str, "send", target_str, "pre_fader"] => {
            let channel_id: usize = segment(cx.addr, id_str)?;
            let target_channel_id: usize = segment(cx.addr, target_str)?;
            cx.commands.send(AudioCommand::SetSendPreFader {
                channel_id,
                target_channel_id,
                pre_fader: a.bool(0)?,
            })?;
        }
        ["channel", id_str, "send", target_str, "mute"] => {
            let channel_id: usize = segment(cx.addr, id_str)?;
            let target_channel_id: usize = segment(cx.addr, target_str)?;
            cx.commands.send(AudioCommand::SetSendMute {
                channel_id,
                target_channel_id,
                muted: a.bool(0)?,
            })?;
        }
        _ => return Ok(false),
    }
    Ok(true)
}
