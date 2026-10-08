//! Plugin commands the command worker could not route to a subprocess plugin.
//!
//! `CommandWorker` handles plugin state and GUI commands for subprocess plugins first. What reaches
//! these functions targets a device that is not a loaded plugin.

use crate::audio::commands::EngineStatus;
use crate::audio::devices::DevicePath;
use crate::audio::state::EngineState;
use crate::audio::types::ChannelId;
use crossbeam::channel::Sender;
use tracing::warn;

/// Answer a state save for a device that is not a plugin, so a project save waiting on it does not
/// time out. Reports size 0 for an existing device and -1 for a missing one.
///
/// Only non-plugin devices get here: the command worker handles subprocess plugins.
pub(super) fn save_plugin_state(
    state: &mut EngineState,
    channel_id: ChannelId,
    device_path: DevicePath,
    file_path: String,
    status_tx: &Sender<EngineStatus>,
) {
    let found = state
        .channels
        .get(&channel_id)
        .is_some_and(|channel| channel.device_at_path(&device_path).is_some());
    if !found {
        warn!(
            "Save plugin state: no device at channel {} path {}",
            channel_id, device_path
        );
    }
    // Always answer, so a project save waiting on it doesn't time out.
    let _ = status_tx.send(EngineStatus::PluginStateSaved {
        channel_id,
        device_path,
        file_path,
        size: if found { 0 } else { -1 },
    });
}

/// Warn that a plugin state load found no loaded plugin.
pub(super) fn load_plugin_state(channel_id: ChannelId, device_path: DevicePath) {
    warn!(
        "Load plugin state: no loaded plugin at channel {} path {}",
        channel_id, device_path
    );
}

/// Warn that a plugin GUI cannot be opened because the device is not a CLAP plugin.
pub(super) fn open_plugin_gui(channel_id: ChannelId, device_path: DevicePath) {
    // Subprocess plugins are handled by the command worker before this point.
    warn!(
        "open plugin GUI: device at channel {} path {} is not a CLAP plugin",
        channel_id, device_path
    );
}

/// Warn that a plugin GUI cannot be closed because the device is not a CLAP plugin.
pub(super) fn close_plugin_gui(channel_id: ChannelId, device_path: DevicePath) {
    // Subprocess plugins are handled by the command worker before this point.
    warn!(
        "close plugin GUI: device at channel {} path {} is not a CLAP plugin",
        channel_id, device_path
    );
}

/// Warn that no subprocess plugin exists at the path, for the GUI visibility and size commands.
///
/// The command worker handles these for subprocess plugins, the only ones they apply to.
pub(super) fn plugin_gui_unavailable(channel_id: ChannelId, device_path: DevicePath) {
    warn!(
        "Plugin GUI visibility/size: no subprocess plugin at channel {} device {}",
        channel_id, device_path
    );
}

#[cfg(test)]
mod tests {
    use crate::audio::commands::{process_command, AudioCommand, EngineStatus};
    use crate::audio::devices::DevicePath;
    use crate::audio::state::EngineState;

    /// A project save waits for every `state/save` it sent, so a device without plugin state
    /// must still answer: size 0 for a device that has none, -1 for no device at all.
    #[test]
    fn save_plugin_state_always_answers() {
        let mut state = EngineState::default();
        let (status_tx, status_rx) = crossbeam::channel::unbounded();
        process_command(
            &mut state,
            AudioCommand::CreateChannel {
                id: 2,
                name: "T".to_string(),
            },
            128,
            &status_tx,
        );
        state.channels.get_mut(&2).unwrap().devices.push(Box::new(
            crate::audio::devices::PolySynthDevice::new(48_000.0),
        ));
        while status_rx.try_recv().is_ok() {}

        for (position, expected) in [(0, 0), (5, -1)] {
            process_command(
                &mut state,
                AudioCommand::SavePluginState {
                    channel_id: 2,
                    device_path: DevicePath::root(position),
                    file_path: "/tmp/unused.bin".to_string(),
                },
                128,
                &status_tx,
            );
            let replies: Vec<EngineStatus> = status_rx.try_iter().collect();
            assert_eq!(replies.len(), 1);
            assert!(matches!(
                &replies[0],
                EngineStatus::PluginStateSaved { channel_id: 2, size, file_path, .. }
                    if *size == expected && file_path == "/tmp/unused.bin"
            ));
        }
    }
}
