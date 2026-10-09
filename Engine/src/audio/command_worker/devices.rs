//! Device chain commands on the command thread: building, removing and configuring devices.

use std::path::Path;
use tracing::{info, warn};

use super::CommandWorker;
use crate::audio::commands::EngineStatus;
use crate::audio::devices::{container, DevicePath};
use crate::audio::types::ChannelId;

impl CommandWorker {
    /// Describe the built-in devices to Godot.
    pub(super) fn advertise_builtin_devices(&self) {
        info!("Advertising builtin devices...");
        let device_infos = self.device_factory.builtin_device_infos();
        let count = device_infos.len();
        for device_info in device_infos {
            self.send_status(device_info);
        }
        for kind_info in crate::audio::commands::modulator_kind_infos() {
            self.send_status(kind_info);
        }
        info!("Advertised {} builtin devices", count);
        self.send_status(EngineStatus::BuiltinDevicesComplete { count });
    }

    /// Build a device with the lock released, then insert it into the parent list.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn add_device(
        &mut self,
        channel_id: ChannelId,
        parent_path: DevicePath,
        device_id: &str,
        device_type: &str,
        device_file: &str,
        position: i32,
        active: bool,
        enabled: bool,
    ) {
        if !parent_path.can_join() {
            warn!(
                "Cannot add device {} below channel {} path {}: nesting is too deep",
                device_id, channel_id, parent_path
            );
            return;
        }
        let child_count = {
            let state = self.lock_state();
            let Some(channel) = state.channels.get(&channel_id) else {
                warn!("Channel {} not found for add device", channel_id);
                return;
            };
            if parent_path.is_empty() {
                channel.devices.len()
            } else {
                match channel
                    .device_at_path(&parent_path)
                    .and_then(|d| d.as_container())
                {
                    Some(container) => container.child_count(),
                    None => {
                        warn!(
                            "No container at channel {} path {} for add device",
                            channel_id, parent_path
                        );
                        return;
                    }
                }
            }
        };

        let insert_pos = if position < 0 {
            child_count
        } else {
            (position as usize).min(child_count)
        };
        let device_path = parent_path.join(insert_pos);

        // The vendor picks the host process in "By vendor" hosting.
        let vendor = if device_type == "clap" || device_type == "vst3" {
            self.plugin_scanner
                .vendor_of(device_id, Path::new(device_file))
                .unwrap_or_else(|| "Unknown".to_string())
        } else {
            String::new()
        };

        let Some(mut device) = self.device_factory.create(
            device_type,
            device_id,
            device_file,
            &vendor,
            channel_id,
            &device_path,
        ) else {
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
        match super::devices::container::insert_device(
            &mut channel.devices,
            &parent_path,
            insert_pos,
            device,
        ) {
            Ok(path) => info!(
                "Device {} added to channel {} at {} [active={}, enabled={}]",
                device_id, channel_id, path, active, enabled
            ),
            Err(e) => warn!("{}", e),
        }
    }

    /// Detach a device under the lock and drop it afterwards: dropping a CLAP plugin closes its
    /// GUI and shuts down its subprocess.
    pub(super) fn remove_device(
        &self,
        channel_id: ChannelId,
        parent_path: DevicePath,
        position: usize,
    ) {
        if !parent_path.can_join() {
            warn!(
                "Invalid device parent path {} for channel {}",
                parent_path, channel_id
            );
            return;
        }
        let path = parent_path.join(position);
        let removed = {
            let mut state = self.lock_state();
            let Some(channel) = state.channels.get_mut(&channel_id) else {
                warn!("Channel {} not found for remove device", channel_id);
                return;
            };
            channel.release_note_effect_at(&path);
            super::devices::container::remove_device(&mut channel.devices, &path)
        };
        if removed.is_none() {
            warn!("Invalid device path {} for channel {}", path, channel_id);
            return;
        }
        drop(removed);
        info!("Device removed from channel {} at {}", channel_id, path);
    }

    /// Detach a channel's whole device chain under the lock and drop it afterwards.
    pub(super) fn clear_devices(&self, channel_id: ChannelId) {
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

    /// Set a device data stream option. An option that needs new buffers (the EQ analyser's FFT
    /// size) builds them with the lock released and swaps them in; the old ones are dropped
    /// after the lock is released again.
    pub(super) fn configure_device_data(
        &self,
        channel_id: ChannelId,
        device_path: DevicePath,
        data_type: &str,
        key: &str,
        value: f32,
    ) {
        let build = {
            let mut state = self.lock_state();
            let device = match state.device_mut(channel_id, &device_path) {
                Ok(device) => device,
                Err(e) => {
                    warn!("configure device data: {e}");
                    return;
                }
            };
            match device.configure_data(data_type, key, value) {
                Ok(build) => build,
                Err(e) => {
                    warn!(
                        "Failed to set '{}' of '{}' on channel {} device {}: {}",
                        key, data_type, channel_id, device_path, e
                    );
                    return;
                }
            }
        };
        let Some(build) = build else {
            return;
        };
        let built = build();
        let replaced = {
            let mut state = self.lock_state();
            match state.device_mut(channel_id, &device_path) {
                Ok(device) => device.apply_data_build(built),
                Err(_) => Some(built),
            }
        };
        drop(replaced);
    }
}
