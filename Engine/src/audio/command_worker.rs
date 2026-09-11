//! Command thread: applies `AudioCommand`s to the engine state shared with the audio callback.
//!
//! The audio callback gives up on a buffer if it can't take the state lock quickly, so this
//! worker holds the lock only to read or swap state. Slow work (plugin scans, building and
//! dropping devices, plugin subprocess round-trips) runs with the lock released. This is safe
//! because the worker is the only thread that adds or removes channels and devices.

use crossbeam::channel::{Receiver, Sender};
use std::sync::{Arc, Mutex, MutexGuard};
use tracing::{info, warn};

use super::commands::{process_command, AudioCommand, EngineState, EngineStatus};
use super::devices::clap_host::subprocess_adapter::PluginIpcHandle;
use super::devices::clap_host::{PluginScanner, SubprocessClapAdapter};
use super::devices::{AudioDevice, DeviceCategory, DeviceFactory};
use super::ipc::ProcessManager;
use super::types::ChannelId;

/// Owns the command thread's resources and applies commands to the shared engine state.
pub struct CommandWorker {
    state: Arc<Mutex<EngineState>>,
    status_tx: Sender<EngineStatus>,
    max_buffer_size: usize,
    device_factory: DeviceFactory,
    plugin_scanner: PluginScanner,
}

impl CommandWorker {
    /// Create a worker whose devices run at `device_sample_rate` with buffers of up to
    /// `max_buffer_size` frames.
    pub fn new(
        state: Arc<Mutex<EngineState>>,
        status_tx: Sender<EngineStatus>,
        command_tx: Sender<AudioCommand>,
        device_sample_rate: f32,
        max_buffer_size: usize,
    ) -> Self {
        let process_manager = Arc::new(ProcessManager::new());
        process_manager.start_monitoring();
        let device_factory = DeviceFactory::new(
            process_manager,
            device_sample_rate,
            max_buffer_size,
            status_tx.clone(),
            command_tx,
        );

        Self {
            state,
            status_tx,
            max_buffer_size,
            device_factory,
            plugin_scanner: PluginScanner::new(),
        }
    }

    /// Apply commands until every sender has been dropped.
    pub fn run(mut self, command_rx: Receiver<AudioCommand>) {
        while let Ok(cmd) = command_rx.recv() {
            self.handle(cmd);
        }
    }

    /// Lock the engine state, recovering it if an earlier command panicked while holding it.
    fn lock_state(&self) -> MutexGuard<'_, EngineState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Send a status update to Godot.
    fn send_status(&self, status: EngineStatus) {
        let _ = self.status_tx.send(status);
    }

    /// Run slow commands with the lock released and everything else under the lock.
    fn handle(&mut self, cmd: AudioCommand) {
        match cmd {
            AudioCommand::ScanPlugins => self.scan_plugins(),
            AudioCommand::AdvertiseBuiltinDevices => self.advertise_builtin_devices(),
            AudioCommand::AddDeviceToChannel {
                channel_id,
                device_id,
                device_type,
                device_file,
                position,
                active,
                enabled,
            } => self.add_device(
                channel_id,
                &device_id,
                &device_type,
                &device_file,
                position,
                active,
                enabled,
            ),
            AudioCommand::RemoveDeviceFromChannel {
                channel_id,
                position,
            } => self.remove_device(channel_id, position),
            AudioCommand::ClearChannelDevices { channel_id } => self.clear_devices(channel_id),
            AudioCommand::RemoveChannel { id } => self.remove_channel(id),
            AudioCommand::ClearProject => self.clear_project(),
            AudioCommand::SetDeviceActive {
                channel_id,
                device_position,
                active,
            } => match self.plugin_handle(channel_id, device_position) {
                Some(handle) => self.set_plugin_active(handle, channel_id, device_position, active),
                None => self.apply_locked(AudioCommand::SetDeviceActive {
                    channel_id,
                    device_position,
                    active,
                }),
            },
            AudioCommand::OpenPluginGui {
                channel_id,
                device_position,
                window_handle,
            } => match self.plugin_handle(channel_id, device_position) {
                Some(handle) => {
                    self.open_plugin_gui(handle, channel_id, device_position, window_handle)
                }
                None => self.apply_locked(AudioCommand::OpenPluginGui {
                    channel_id,
                    device_position,
                    window_handle,
                }),
            },
            AudioCommand::ClosePluginGui {
                channel_id,
                device_position,
            } => match self.plugin_handle(channel_id, device_position) {
                Some(handle) => self.close_plugin_gui(handle, channel_id, device_position),
                None => self.apply_locked(AudioCommand::ClosePluginGui {
                    channel_id,
                    device_position,
                }),
            },
            other => self.apply_locked(other),
        }
    }

    /// Apply a fast command with the state lock held.
    fn apply_locked(&self, cmd: AudioCommand) {
        let status = process_command(
            &mut self.lock_state(),
            cmd,
            self.max_buffer_size,
            &self.status_tx,
        );
        if let Some(status) = status {
            self.send_status(status);
        }
    }

    /// Scan for CLAP plugins and report each one to Godot.
    fn scan_plugins(&mut self) {
        info!("Starting plugin scan...");
        let count = match self.plugin_scanner.scan() {
            Ok(count) => count,
            Err(e) => {
                warn!("Plugin scan failed: {}", e);
                return;
            }
        };
        info!("Plugin scan complete: {} plugins found", count);

        for plugin in self.plugin_scanner.all_plugins() {
            let category = match plugin.category {
                DeviceCategory::Instrument => "instrument",
                DeviceCategory::Effect => "effect",
                DeviceCategory::Utility => "utility",
            }
            .to_string();

            self.send_status(EngineStatus::PluginInfo {
                id: plugin.id.clone(),
                name: plugin.name.clone(),
                vendor: plugin.vendor.clone(),
                version: plugin.version.clone(),
                category,
                description: plugin.description.clone(),
                path: plugin.path.to_string_lossy().to_string(),
            });
        }

        self.send_status(EngineStatus::PluginScanComplete { count });
    }

    /// Describe the built-in devices to Godot.
    fn advertise_builtin_devices(&self) {
        info!("Advertising builtin devices...");
        let device_infos = self.device_factory.builtin_device_infos();
        let count = device_infos.len();
        for device_info in device_infos {
            self.send_status(device_info);
        }
        info!("Advertised {} builtin devices", count);
        self.send_status(EngineStatus::BuiltinDevicesComplete { count });
    }

    /// Build a device with the lock released, then insert it into the channel's chain.
    #[allow(clippy::too_many_arguments)]
    fn add_device(
        &self,
        channel_id: ChannelId,
        device_id: &str,
        device_type: &str,
        device_file: &str,
        position: i32,
        active: bool,
        enabled: bool,
    ) {
        if !self.lock_state().channels.contains_key(&channel_id) {
            warn!("Channel {} not found for add device", channel_id);
            return;
        }

        let Some(mut device) =
            self.device_factory
                .create(device_type, device_id, device_file, channel_id, position)
        else {
            return;
        };
        device.set_enabled(enabled);

        let mut state = self.lock_state();
        let Some(channel) = state.channels.get_mut(&channel_id) else {
            warn!(
                "Channel {} was removed while device {} was being created",
                channel_id, device_id
            );
            return;
        };
        let insert_pos = if position < 0 {
            channel.devices.len()
        } else {
            (position as usize).min(channel.devices.len())
        };
        channel.devices.insert(insert_pos, device);
        info!(
            "Device {} added to channel {} at position {} [active={}, enabled={}]",
            device_id, channel_id, insert_pos, active, enabled
        );
    }

    /// Detach a device under the lock and drop it afterwards: dropping a CLAP plugin closes its
    /// GUI and shuts down its subprocess.
    fn remove_device(&self, channel_id: ChannelId, position: usize) {
        let removed = {
            let mut state = self.lock_state();
            let Some(channel) = state.channels.get_mut(&channel_id) else {
                warn!("Channel {} not found for remove device", channel_id);
                return;
            };
            if position >= channel.devices.len() {
                warn!(
                    "Invalid device position {} for channel {}",
                    position, channel_id
                );
                return;
            }
            channel.devices.remove(position)
        };
        drop(removed);
        info!(
            "Device removed from channel {} at position {}",
            channel_id, position
        );
    }

    /// Detach a channel's whole device chain under the lock and drop it afterwards.
    fn clear_devices(&self, channel_id: ChannelId) {
        let removed = {
            let mut state = self.lock_state();
            let Some(channel) = state.channels.get_mut(&channel_id) else {
                warn!("Channel {} not found for clear devices", channel_id);
                return;
            };
            std::mem::take(&mut channel.devices)
        };
        drop(removed);
        info!("All devices cleared from channel {}", channel_id);
    }

    /// Detach a channel under the lock and drop it, with its devices, afterwards.
    fn remove_channel(&self, id: ChannelId) {
        let (removed, remaining) = {
            let mut state = self.lock_state();
            let removed = state.channels.remove(&id);
            (removed, state.channels.len())
        };
        match removed {
            Some(channel) => {
                drop(channel);
                info!("Channel {} removed [total channels: {}]", id, remaining);
            }
            None => warn!("Cannot remove channel {}: not found", id),
        }
    }

    /// Swap out all channels, tracks and clips under the lock and drop them afterwards.
    fn clear_project(&self) {
        let removed = {
            let mut state = self.lock_state();
            state.set_current_tick(0);
            (
                std::mem::take(&mut state.channels),
                std::mem::take(&mut state.tracks),
                std::mem::take(&mut state.clips),
            )
        };
        drop(removed);
        info!("Project cleared");
    }

    /// Get an IPC handle for the subprocess CLAP plugin at a position, or None if the device
    /// doesn't exist or isn't one.
    fn plugin_handle(
        &self,
        channel_id: ChannelId,
        device_position: usize,
    ) -> Option<PluginIpcHandle> {
        self.with_plugin(channel_id, device_position, |plugin| plugin.ipc_handle())
    }

    /// Run `f` under the lock on the subprocess CLAP plugin at a position, if there is one.
    fn with_plugin<R>(
        &self,
        channel_id: ChannelId,
        device_position: usize,
        f: impl FnOnce(&mut SubprocessClapAdapter) -> R,
    ) -> Option<R> {
        let mut state = self.lock_state();
        let device = state
            .channels
            .get_mut(&channel_id)?
            .devices
            .get_mut(device_position)?;
        let result = device
            .as_any_mut()
            .downcast_mut::<SubprocessClapAdapter>()
            .map(f);
        result
    }

    /// Activate or deactivate a subprocess plugin with the lock released.
    fn set_plugin_active(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_position: usize,
        active: bool,
    ) {
        let is_active = self.with_plugin(channel_id, device_position, |plugin| plugin.is_active());
        if is_active != Some(!active) {
            // Already in the requested state
            return;
        }

        let (action, result) = if active {
            ("activate", handle.activate())
        } else {
            ("deactivate", handle.deactivate())
        };
        if let Err(e) = result {
            warn!(
                "Failed to {} device at channel {} position {}: {}",
                action, channel_id, device_position, e
            );
            return;
        }

        self.with_plugin(channel_id, device_position, |plugin| {
            plugin.set_active_state(active)
        });
        info!(
            "Device {}: channel={} device={}",
            if active { "activated" } else { "deactivated" },
            channel_id,
            device_position
        );
        self.send_status(EngineStatus::DeviceActiveChanged {
            channel_id,
            device_position,
            active,
        });
    }

    /// Open a subprocess plugin's GUI with the lock released, then ask Godot to size its window.
    fn open_plugin_gui(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_position: usize,
        window_handle: Option<u64>,
    ) {
        let already_open = self
            .with_plugin(channel_id, device_position, |plugin| plugin.is_gui_open())
            .unwrap_or(false);

        let (width, height) = if already_open {
            // The size can't be queried once the GUI is open, so fall back to a default
            (800, 600)
        } else {
            match handle.open_gui(window_handle) {
                Ok((width, height, is_resizable)) => {
                    self.with_plugin(channel_id, device_position, |plugin| {
                        plugin.set_gui_open(true)
                    });
                    info!(
                        "Opened GUI for subprocess plugin at channel {} device {} (window_handle: {:?}, size: {}x{}, resizable: {})",
                        channel_id, device_position, window_handle, width, height, is_resizable
                    );
                    (width, height)
                }
                Err(e) => {
                    warn!(
                        "Failed to open subprocess plugin GUI at channel {} device {}: {}",
                        channel_id, device_position, e
                    );
                    return;
                }
            }
        };

        self.send_status(EngineStatus::PluginGuiResizeRequest {
            channel_id,
            device_position,
            width,
            height,
        });
    }

    /// Close a subprocess plugin's GUI with the lock released, then tell Godot to destroy its
    /// window.
    fn close_plugin_gui(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_position: usize,
    ) {
        let was_open = self
            .with_plugin(channel_id, device_position, |plugin| plugin.is_gui_open())
            .unwrap_or(false);

        if was_open {
            let result = handle.close_gui();
            // Mark closed even if IPC failed: the window is being destroyed regardless
            self.with_plugin(channel_id, device_position, |plugin| {
                plugin.set_gui_open(false)
            });
            if let Err(e) = result {
                warn!(
                    "Failed to close subprocess plugin GUI at channel {} device {}: {}",
                    channel_id, device_position, e
                );
                return;
            }
        }

        info!(
            "Closed GUI for subprocess plugin at channel {} device {}",
            channel_id, device_position
        );
        self.send_status(EngineStatus::PluginGuiClosed {
            channel_id,
            device_position,
        });
    }
}
