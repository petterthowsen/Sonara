//! Device data stream subscriptions (spectrum, oscilloscope, ...).

use crate::audio::devices::DevicePath;
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;
use tracing::{info, warn};

/// Subscribe to a device data stream (spectrum, oscilloscope, ...).
pub(super) fn subscribe_device_data(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    data_type: String,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            match device.subscribe_data(&data_type) {
                Ok(()) => {
                    info!(
                        "Subscribed to '{}' data on channel {} device {}",
                        data_type, channel_id, device_path
                    );
                }
                Err(e) => {
                    warn!(
                        "Failed to subscribe to '{}' on channel {} device {}: {}",
                        data_type, channel_id, device_path, e
                    );
                }
            }
        } else {
            warn!(
                "Device not found at channel {} path {}",
                channel_id, device_path
            );
        }
    } else {
        warn!("Channel {} not found for subscribe device data", channel_id);
    }
}

/// Unsubscribe from a device data stream.
pub(super) fn unsubscribe_device_data(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    data_type: String,
) {
    if let Some(channel) = state.channels.get_mut(&channel_id) {
        if let Some(device) = channel.device_at_path_mut(&device_path) {
            device.unsubscribe_data(&data_type);
            info!(
                "Unsubscribed from '{}' data on channel {} device {}",
                data_type, channel_id, device_path
            );
        } else {
            warn!(
                "Device not found at channel {} path {}",
                channel_id, device_path
            );
        }
    } else {
        warn!(
            "Channel {} not found for unsubscribe device data",
            channel_id
        );
    }
}
