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

use super::parse::ArgError;
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

/// A malformed message (`ArgError`) is logged at WARN and counts as handled, so it is neither
/// reported as an unknown address nor aborts the rest of a bundle. Any other error (a closed
/// command channel) goes on to the caller.
fn warn_on_arg_error(result: Result<bool>) -> Result<bool> {
    match result {
        Err(err) => match err.downcast::<ArgError>() {
            Ok(arg_error) => {
                warn!("{}", arg_error);
                Ok(true)
            }
            Err(err) => Err(err),
        },
        ok => ok,
    }
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
            return warn_on_arg_error(
                device::handle_device_message(channel_id, device_path, &action, args, &mut cx)
                    .map(|()| true),
            )
            .map(|_| ());
        }

        // Route based on the first address segment
        let handled = match parts.first().copied() {
            Some("transport") => warn_on_arg_error(transport::route(&parts, args, &mut cx))?,
            Some("project") => warn_on_arg_error(project::route(&parts, args, &mut cx))?,
            Some("channel") => {
                warn_on_arg_error(channel::route(&parts, args, &mut cx))?
                    || warn_on_arg_error(device::route(&parts, args, &mut cx))?
            }
            Some("track") => warn_on_arg_error(track::route(&parts, args, &mut cx))?,
            Some("clip") => warn_on_arg_error(clip::route(&parts, args, &mut cx))?,
            Some("plugin" | "plugins" | "builtin") => {
                warn_on_arg_error(plugin::route(&parts, args, &mut cx))?
            }
            Some("audio") => warn_on_arg_error(audio::route(&parts, args, &mut cx))?,
            Some("render") => warn_on_arg_error(render::route(&parts, args, &mut cx))?,
            Some("audiofile") => warn_on_arg_error(audiofile::route(&parts, args, &cx))?,
            _ => false,
        };

        if !handled {
            warn!("Unknown OSC address: {}", addr);
        }

        Ok(())
    }
}
