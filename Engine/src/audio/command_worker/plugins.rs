//! Subprocess CLAP plugin commands on the command thread: scanning, reload, hosting policy, state
//! save/load, activation and GUI.

use std::path::PathBuf;
use tracing::{info, warn};

use super::device_tick::PolledPlugin;
use super::CommandWorker;
use crate::audio::commands::{AudioCommand, EngineStatus};
use crate::audio::devices::clap_host::subprocess_adapter::PluginIpcHandle;
use crate::audio::devices::clap_host::SubprocessClapAdapter;
use crate::audio::devices::sfizz_keys::KeyKind;
use crate::audio::devices::{container, AudioDevice, DevicePath, SfizzDevice};
use crate::audio::ipc::HostingPolicy;
use crate::audio::types::ChannelId;

impl CommandWorker {
    /// Scan for CLAP and VST3 plugins and report each one to Godot.
    pub(super) fn scan_plugins(&mut self, paths: Vec<PathBuf>, vst3_paths: Vec<PathBuf>) {
        info!("Starting plugin scan...");
        self.plugin_scanner.set_paths(paths);
        self.plugin_scanner.set_vst3_paths(vst3_paths);
        let count = match self.plugin_scanner.scan() {
            Ok(count) => count,
            Err(e) => {
                warn!("Plugin scan failed: {}", e);
                return;
            }
        };
        info!("Plugin scan complete: {} plugins found", count);

        // Godot drains its OSC socket once per frame into a 64 KB queue, and a full scan is
        // far more than that. Send in batches with a pause (about one frame) in between so
        // the tail, including /plugin/scan_complete, isn't dropped.
        const BATCH: usize = 32;
        const BATCH_PAUSE: std::time::Duration = std::time::Duration::from_millis(20);

        for (i, plugin) in self.plugin_scanner.all_plugins().enumerate() {
            if i > 0 && i % BATCH == 0 {
                std::thread::sleep(BATCH_PAUSE);
            }
            let category = plugin.category.as_str().to_string();

            self.send_status(EngineStatus::PluginInfo {
                id: plugin.id.clone(),
                name: plugin.name.clone(),
                vendor: plugin.vendor.clone(),
                version: plugin.version.clone(),
                category,
                description: plugin.description.clone(),
                path: plugin.path.to_string_lossy().to_string(),
                features: plugin.features.clone(),
                format: plugin.format.as_str().to_string(),
            });
        }

        std::thread::sleep(BATCH_PAUSE);
        self.send_status(EngineStatus::PluginScanComplete { count });
    }

    /// Respawn a crashed plugin's host and restore its state on a background thread.
    ///
    /// A crash takes down every instance in the host, so every device that was in the same host
    /// process is reloaded with it: one Reload brings the whole host back (Phase 5).
    pub(super) fn reload_device(&self, channel_id: ChannelId, device_path: DevicePath) {
        let state = self.with_plugin(channel_id, &device_path, |plugin| {
            let load = plugin.load();
            (load.is_crashed() || load.is_failed(), load.host_pid())
        });
        let host_pid = match state {
            None => {
                warn!(
                    "Reload requested for channel {} device {}, which is not a subprocess plugin",
                    channel_id, device_path
                );
                return;
            }
            Some((false, _)) => {
                warn!(
                    "Reload requested for channel {} device {}, but it hasn't crashed",
                    channel_id, device_path
                );
                return;
            }
            Some((true, pid)) => pid,
        };

        let mut requests = Vec::new();
        {
            let mut state = self.lock_state();
            for (&id, channel) in state.channels.iter_mut() {
                container::visit_devices_mut(&mut channel.devices, &mut |path, device| {
                    let Some(plugin) = device.as_any_mut().downcast_mut::<SubprocessClapAdapter>()
                    else {
                        return;
                    };
                    let load = plugin.load();
                    let requested = id == channel_id && *path == device_path;
                    // Pid 0: the plugin never finished loading, so it shared no host.
                    let same_host =
                        host_pid != 0 && load.is_crashed() && load.host_pid() == host_pid;
                    if requested || same_host {
                        requests.push((id, *path, plugin.begin_reload()));
                    }
                });
            }
        }
        for (id, path, request) in requests {
            info!(
                "Reloading plugin at channel {} device {} (host pid {} crashed)",
                id, path, host_pid
            );
            request.spawn();
        }
    }

    /// Replace the hosting policy and move every loaded plugin whose host changed.
    pub(super) fn set_plugin_hosting(&mut self, policy: HostingPolicy) {
        self.process_manager.set_hosting_policy(policy);
        // The next tick compares every ready plugin with the new policy and moves it; run it now
        // rather than up to one interval later.
        self.poll_devices();
    }

    /// Move a plugin to the host process the hosting policy now picks: save its state, close its
    /// GUI, then respawn it there through the reload path, which restores the state (Phase 5).
    /// Audio passes through the plugin until it is ready in its new host.
    pub(super) fn move_plugin(&self, plugin: &PolledPlugin) {
        let (channel_id, device_path) = (plugin.channel_id, plugin.device_path);
        let gui_open = self
            .with_plugin(channel_id, &device_path, |plugin| plugin.is_gui_open())
            .unwrap_or(false);
        if gui_open {
            if let Err(e) = plugin.handle.close_gui() {
                warn!(
                    "Failed to close the GUI of {} before moving it: {}",
                    plugin.handle.device_name(),
                    e
                );
            }
            self.send_status(EngineStatus::PluginGuiClosed {
                channel_id,
                device_path,
            });
        }

        // Without a state extension the reload re-sends the cached parameter values instead.
        match plugin.handle.save_state() {
            Ok(state) => {
                self.with_plugin(channel_id, &device_path, |plugin| {
                    plugin.set_saved_state(state)
                });
            }
            Err(e) => info!(
                "Moving {} without a state blob ({}); its parameter values are re-sent",
                plugin.handle.device_name(),
                e
            ),
        }

        let request = self.with_plugin(channel_id, &device_path, |plugin| {
            let from = plugin.host_assignment().key.clone();
            let to = plugin.desired_host();
            // The policy may have changed back while the state was saved.
            if to == *plugin.host_assignment() || !plugin.load().is_ready() {
                return None;
            }
            Some((from, to.key, plugin.begin_reload()))
        });
        if let Some(Some((from, to, request))) = request {
            info!(
                "Moving plugin {} (channel {} device {}) from host {} to host {}",
                plugin.handle.device_name(),
                channel_id,
                device_path,
                from,
                to
            );
            request.spawn();
        }
    }

    /// Ask a plugin for its state blob, write it to `file_path` and report the size (project
    /// save path). The blob travels as a file because it rarely fits one OSC datagram.
    pub(super) fn save_plugin_state(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        file_path: String,
    ) {
        let Some(handle) = self.plugin_handle(channel_id, &device_path) else {
            // Not a subprocess plugin: the locked path reports it has no state.
            self.apply_locked(AudioCommand::SavePluginState {
                channel_id,
                device_path,
                file_path,
            });
            return;
        };

        let size = match handle.save_state() {
            Ok(state) => match std::fs::write(&file_path, &state) {
                Ok(()) => {
                    info!(
                        "Saved {} bytes of plugin state (channel {} device {}) to {}",
                        state.len(),
                        channel_id,
                        device_path,
                        file_path
                    );
                    let size = state.len() as i64;
                    self.with_plugin(channel_id, &device_path, |plugin| {
                        plugin.set_saved_state(state)
                    });
                    size
                }
                Err(e) => {
                    warn!(
                        "Failed to write plugin state (channel {} device {}) to {}: {}",
                        channel_id, device_path, file_path, e
                    );
                    -1
                }
            },
            Err(e) => {
                warn!(
                    "Failed to save plugin state (channel {} device {}): {}",
                    channel_id, device_path, e
                );
                -1
            }
        };
        self.send_status(EngineStatus::PluginStateSaved {
            channel_id,
            device_path,
            file_path,
            size,
        });
    }

    /// Hand a state blob read from `file_path` back to a plugin (project load path).
    pub(super) fn load_plugin_state(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        file_path: String,
    ) {
        let Some(handle) = self.plugin_handle(channel_id, &device_path) else {
            self.apply_locked(AudioCommand::LoadPluginState {
                channel_id,
                device_path,
                file_path,
            });
            return;
        };

        let state = match std::fs::read(&file_path) {
            Ok(state) => state,
            Err(e) => {
                warn!(
                    "Could not read plugin state for channel {} device {} from {}: {}",
                    channel_id, device_path, file_path, e
                );
                return;
            }
        };
        let len = state.len();
        match handle.load_state(state.clone()) {
            Ok(()) => {
                // Keep it as the saved state too, so a crash before the next refresh restores
                // what the project loaded rather than the plugin's defaults.
                self.with_plugin(channel_id, &device_path, |plugin| {
                    plugin.set_saved_state(state);
                    plugin.set_state_dirty();
                });
                info!(
                    "Restored {} bytes of plugin state (channel {} device {})",
                    len, channel_id, device_path
                );
            }
            Err(e) => warn!(
                "Failed to load plugin state (channel {} device {}): {}",
                channel_id, device_path, e
            ),
        }
    }

    /// Get an IPC handle for the subprocess CLAP plugin at a path, or None if the device
    /// doesn't exist or isn't one.
    pub(super) fn plugin_handle(
        &self,
        channel_id: ChannelId,
        device_path: &DevicePath,
    ) -> Option<PluginIpcHandle> {
        self.with_plugin(channel_id, device_path, |plugin| plugin.ipc_handle())
    }

    /// Run `f` under the lock on the subprocess CLAP plugin at a path, if there is one.
    pub(super) fn with_plugin<R>(
        &self,
        channel_id: ChannelId,
        device_path: &DevicePath,
        f: impl FnOnce(&mut SubprocessClapAdapter) -> R,
    ) -> Option<R> {
        let mut state = self.lock_state();
        // Quiet on a miss: callers use `None` to tell "not a plugin" from "plugin".
        state
            .device_as_mut::<SubprocessClapAdapter>(channel_id, device_path)
            .ok()
            .map(f)
    }

    /// Activate or deactivate a subprocess plugin with the lock released.
    pub(super) fn set_plugin_active(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_path: DevicePath,
        active: bool,
    ) {
        let is_active = self.with_plugin(channel_id, &device_path, |plugin| plugin.is_active());
        if is_active != Some(!active) {
            return;
        }

        let latency = if active {
            match handle.activate() {
                Ok(latency) => latency,
                Err(e) => {
                    warn!(
                        "Failed to activate device at channel {} path {}: {}",
                        channel_id, device_path, e
                    );
                    return;
                }
            }
        } else {
            if let Err(e) = handle.deactivate() {
                warn!(
                    "Failed to deactivate device at channel {} path {}: {}",
                    channel_id, device_path, e
                );
                return;
            }
            0
        };

        self.with_plugin(channel_id, &device_path, |plugin| {
            plugin.set_active_state(active, latency)
        });
        info!(
            "Device {}: channel={} device={}",
            if active { "activated" } else { "deactivated" },
            channel_id,
            device_path
        );
        self.send_status(EngineStatus::DeviceActiveChanged {
            channel_id,
            device_path,
            active,
        });
    }

    /// Open a subprocess plugin's GUI with the lock released, then report its size so the host
    /// window is sized and Godot can lay it out. An already-open GUI reports its current state.
    pub(super) fn open_plugin_gui(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_path: DevicePath,
        window_handle: Option<u64>,
    ) {
        let gui = match handle.open_gui(window_handle) {
            Ok(gui) => gui,
            Err(e) => {
                warn!(
                    "Failed to open subprocess plugin GUI at channel {} device {}: {}",
                    channel_id, device_path, e
                );
                return;
            }
        };
        self.with_plugin(channel_id, &device_path, |plugin| plugin.set_gui_open(true));
        info!(
            "Opened GUI for subprocess plugin at channel {} device {} (window_handle: {:?}, size: {}x{}, resizable: {}, floating: {})",
            channel_id, device_path, window_handle, gui.width, gui.height, gui.resizable, gui.floating
        );

        self.send_status(EngineStatus::PluginGuiOpened {
            channel_id,
            device_path,
            width: gui.width,
            height: gui.height,
            resizable: gui.resizable,
            floating: gui.floating,
        });
    }

    /// Close a subprocess plugin's GUI with the lock released, then tell Godot to destroy its
    /// window.
    pub(super) fn close_plugin_gui(
        &self,
        handle: PluginIpcHandle,
        channel_id: ChannelId,
        device_path: DevicePath,
    ) {
        let was_open = self
            .with_plugin(channel_id, &device_path, |plugin| plugin.is_gui_open())
            .unwrap_or(false);

        if was_open {
            let result = handle.close_gui();
            self.with_plugin(channel_id, &device_path, |plugin| {
                plugin.set_gui_open(false)
            });
            if let Err(e) = result {
                warn!(
                    "Failed to close subprocess plugin GUI at channel {} device {}: {}",
                    channel_id, device_path, e
                );
                return;
            }
        }

        info!(
            "Closed GUI for subprocess plugin at channel {} device {}",
            channel_id, device_path
        );
        self.send_status(EngineStatus::PluginGuiClosed {
            channel_id,
            device_path,
        });
    }

    /// Activate or deactivate a device: a subprocess plugin with the lock released, anything else
    /// under the lock.
    pub(super) fn set_device_active(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        active: bool,
    ) {
        match self.plugin_handle(channel_id, &device_path) {
            Some(handle) => self.set_plugin_active(handle, channel_id, device_path, active),
            None => self.apply_locked(AudioCommand::SetDeviceActive {
                channel_id,
                device_path,
                active,
            }),
        }
    }

    /// Open a device's GUI: a subprocess plugin's with the lock released, anything else under
    /// the lock (where it is refused).
    pub(super) fn open_gui(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        window_handle: Option<u64>,
    ) {
        match self.plugin_handle(channel_id, &device_path) {
            Some(handle) => self.open_plugin_gui(handle, channel_id, device_path, window_handle),
            None => self.apply_locked(AudioCommand::OpenPluginGui {
                channel_id,
                device_path,
                window_handle,
            }),
        }
    }

    /// Close a device's GUI: a subprocess plugin's with the lock released, anything else under
    /// the lock (where it is refused).
    pub(super) fn close_gui(&self, channel_id: ChannelId, device_path: DevicePath) {
        match self.plugin_handle(channel_id, &device_path) {
            Some(handle) => self.close_plugin_gui(handle, channel_id, device_path),
            None => self.apply_locked(AudioCommand::ClosePluginGui {
                channel_id,
                device_path,
            }),
        }
    }

    /// Show or hide a subprocess plugin's GUI.
    pub(super) fn set_gui_visible(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        visible: bool,
    ) {
        match self.plugin_handle(channel_id, &device_path) {
            Some(handle) => {
                if let Err(e) = handle.set_gui_visible(visible) {
                    warn!(
                        "Failed to {} plugin GUI at channel {} device {}: {}",
                        if visible { "show" } else { "hide" },
                        channel_id,
                        device_path,
                        e
                    );
                }
            }
            None => warn!(
                "SetPluginGuiVisible: no subprocess plugin at channel {} device {}",
                channel_id, device_path
            ),
        }
    }

    /// Resize a subprocess plugin's GUI and report the size it ended up with.
    pub(super) fn set_gui_size(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        width: u32,
        height: u32,
    ) {
        match self.plugin_handle(channel_id, &device_path) {
            Some(handle) => match handle.set_gui_size(width, height) {
                Ok((width, height)) => self.send_status(EngineStatus::PluginGuiResizeRequest {
                    channel_id,
                    device_path,
                    width,
                    height,
                }),
                Err(e) => warn!(
                    "Failed to resize plugin GUI at channel {} device {} to {}x{}: {}",
                    channel_id, device_path, width, height, e
                ),
            },
            None => warn!(
                "SetPluginGuiSize: no subprocess plugin at channel {} device {}",
                channel_id, device_path
            ),
        }
    }
}

/// Queue the key labels and keyswitches an SFZ declared when it loaded. Sent even when empty.
pub(super) fn collect_sfizz_key_info(
    channel_id: ChannelId,
    device_path: DevicePath,
    sfizz: &mut SfizzDevice,
    statuses: &mut Vec<EngineStatus>,
) {
    if !sfizz.take_key_info_changed() {
        return;
    }
    let keys = sfizz
        .key_info()
        .into_iter()
        .map(|info| (info.key, info.kind == KeyKind::Keyswitch, info.label))
        .collect();
    statuses.push(EngineStatus::SfzKeyInfo {
        channel_id,
        device_path,
        keys,
        ranges: sfizz.playable_ranges(),
    });
}

/// Queue a status pair describing an SFZ device's parameters when its instrument changed them.
pub(super) fn collect_sfizz_parameters(
    channel_id: ChannelId,
    device_path: DevicePath,
    sfizz: &mut SfizzDevice,
    statuses: &mut Vec<EngineStatus>,
) {
    if !sfizz.take_parameters_changed() {
        return;
    }
    let params = sfizz.parameters();
    if params.is_empty() {
        return;
    }
    statuses.push(EngineStatus::PluginParameterCount {
        channel_id,
        device_path,
        count: params.len(),
    });
    for param in params.iter() {
        statuses.push(EngineStatus::PluginParameterInfo {
            channel_id,
            device_path,
            param_id: param.id,
            name: param.name.clone(),
            min: param.min,
            max: param.max,
            default: param.default,
            group: sfizz.parameter_group(param.id).to_string(),
            param_type: param.param_type,
            is_hidden: false,
            is_read_only: false,
            is_bypass: false,
            is_modulatable: param.is_modulatable,
            module: String::new(),
            enum_values: param.enum_values.clone(),
            unit: param.unit.clone(),
            display: param.display.clone(),
        });
    }
}
