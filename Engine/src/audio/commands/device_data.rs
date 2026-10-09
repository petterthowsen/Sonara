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
    let device = match state.device_mut(channel_id, &device_path) {
        Ok(device) => device,
        Err(e) => {
            warn!("subscribe device data: {e}");
            return;
        }
    };
    match device.subscribe_data(&data_type) {
        Ok(()) => info!(
            "Subscribed to '{}' data on channel {} device {}",
            data_type, channel_id, device_path
        ),
        Err(e) => warn!(
            "Failed to subscribe to '{}' on channel {} device {}: {}",
            data_type, channel_id, device_path, e
        ),
    }
}

/// Unsubscribe from a device data stream.
pub(super) fn unsubscribe_device_data(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    data_type: String,
) {
    match state.device_mut(channel_id, &device_path) {
        Ok(device) => {
            device.unsubscribe_data(&data_type);
            info!(
                "Unsubscribed from '{}' data on channel {} device {}",
                data_type, channel_id, device_path
            );
        }
        Err(e) => warn!("unsubscribe device data: {e}"),
    }
}
