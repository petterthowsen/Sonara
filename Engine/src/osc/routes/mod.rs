//! Routing of incoming OSC messages: split the address, then hand the message to the area that
//! owns its first segment. Each area file matches the full address and returns `false` for an
//! address it doesn't know.

mod audio;
mod audiofile;
mod channel;
mod clip;
mod device;
mod device_slots;
mod plugin;
mod project;
mod render;
mod track;
mod transport;

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::{OscMessage, OscPacket};
use tracing::warn;

use super::server::OscServer;
use crate::audio::devices::parse_osc_device_addr;
use crate::audio::AudioCommand;
use crate::logging::LogWriters;
use crate::window_manager::WindowManager;

impl OscServer {
    /// Handle an incoming OSC packet
    pub(super) fn handle_packet(
        &self,
        packet: OscPacket,
        command_tx: &Sender<AudioCommand>,
        log_writers: &LogWriters,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        match packet {
            OscPacket::Message(msg) => {
                self.handle_message(msg, command_tx, log_writers, window_manager)
            }
            OscPacket::Bundle(bundle) => {
                for packet in bundle.content {
                    self.handle_packet(packet, command_tx, log_writers, window_manager)?;
                }
                Ok(())
            }
        }
    }

    /// Handle an individual OSC message
    fn handle_message(
        &self,
        msg: OscMessage,
        command_tx: &Sender<AudioCommand>,
        log_writers: &LogWriters,
        window_manager: &mut WindowManager,
    ) -> Result<()> {
        let addr = msg.addr.as_str();
        let args = &msg.args;

        // Split address into parts for path-based routing
        let parts: Vec<&str> = addr.split('/').filter(|s| !s.is_empty()).collect();

        if let Some((channel_id, device_path, action)) = parse_osc_device_addr(&parts) {
            return self.handle_device_message(
                channel_id,
                device_path,
                &action,
                args,
                command_tx,
                window_manager,
            );
        }

        // Route based on the first address segment
        let handled = match parts.first().copied() {
            Some("transport") => self.route_transport(&parts, args, command_tx)?,
            Some("project") => self.route_project(&parts, args, command_tx, log_writers)?,
            Some("channel") => {
                self.route_channel(&parts, args, command_tx)?
                    || self.route_channel_devices(&parts, args, command_tx)?
            }
            Some("track") => self.route_track(&parts, args, command_tx)?,
            Some("clip") => self.route_clip(addr, &parts, args, command_tx)?,
            Some("plugin" | "plugins" | "builtin") => {
                self.route_plugin(&parts, args, command_tx)?
            }
            Some("audio") => self.route_audio(&parts, args, command_tx)?,
            Some("render") => self.route_render(&parts, args, command_tx)?,
            Some("audiofile") => self.route_audiofile(&parts, args)?,
            _ => false,
        };

        if !handled {
            warn!("Unknown OSC address: {}", addr);
        }

        Ok(())
    }
}
