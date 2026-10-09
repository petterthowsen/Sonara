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

/// What a route handler needs: where to send commands and how to answer Godot directly.
pub(super) struct RouteCtx<'a> {
    /// The address of the message being routed, for warnings.
    pub addr: &'a str,
    /// Where commands for the command thread go.
    pub commands: &'a Sender<AudioCommand>,
    /// The server, to answer Godot directly and reach the AudioFileService.
    pub server: &'a OscServer,
    /// The log files `/project/init` rotates.
    pub log_writers: &'a LogWriters,
    /// The plugin GUI host windows.
    pub windows: &'a mut WindowManager,
}

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

        let mut cx = RouteCtx {
            addr,
            commands: command_tx,
            server: self,
            log_writers,
            windows: window_manager,
        };

        if let Some((channel_id, device_path, action)) = parse_osc_device_addr(&parts) {
            return device::handle_device_message(channel_id, device_path, &action, args, &mut cx);
        }

        // Route based on the first address segment
        let handled = match parts.first().copied() {
            Some("transport") => transport::route(&parts, args, &mut cx)?,
            Some("project") => project::route(&parts, args, &mut cx)?,
            Some("channel") => {
                channel::route(&parts, args, &mut cx)? || device::route(&parts, args, &mut cx)?
            }
            Some("track") => track::route(&parts, args, &mut cx)?,
            Some("clip") => clip::route(&parts, args, &mut cx)?,
            Some("plugin" | "plugins" | "builtin") => plugin::route(&parts, args, &mut cx)?,
            Some("audio") => audio::route(&parts, args, &mut cx)?,
            Some("render") => render::route(&parts, args, &mut cx)?,
            Some("audiofile") => audiofile::route(&parts, args, &cx)?,
            _ => false,
        };

        if !handled {
            warn!("Unknown OSC address: {}", addr);
        }

        Ok(())
    }
}
