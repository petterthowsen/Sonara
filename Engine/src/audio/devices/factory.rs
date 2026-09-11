//! Builds devices by type and ID. Runs on the command thread, never on the audio thread.

use crossbeam::channel::Sender;
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{info, warn};

use super::clap_host::SubprocessClapAdapter;
use super::{
    AudioDevice, DelayDevice, DeviceCategory, PolySynthDevice, PortFlow, SfizzDevice,
    SpectrumAnalyzerDevice,
};
use crate::audio::commands::{AudioCommand, BuiltinParamInfo, EngineStatus};
use crate::audio::ipc::ProcessManager;
use crate::audio::types::ChannelId;

/// Creates channel devices and describes the built-in devices to Godot.
pub struct DeviceFactory {
    process_manager: Arc<ProcessManager>,
    sample_rate: f32,
    max_buffer_size: usize,
    status_tx: Sender<EngineStatus>,
    command_tx: Sender<AudioCommand>,
}

impl DeviceFactory {
    /// Create a factory for devices running at `sample_rate` with buffers of up to
    /// `max_buffer_size` frames.
    pub fn new(
        process_manager: Arc<ProcessManager>,
        sample_rate: f32,
        max_buffer_size: usize,
        status_tx: Sender<EngineStatus>,
        command_tx: Sender<AudioCommand>,
    ) -> Self {
        Self {
            process_manager,
            sample_rate,
            max_buffer_size,
            status_tx,
            command_tx,
        }
    }

    /// Create a device of `device_type` ("builtin" or "clap"). Logs and returns None for unknown
    /// or failed devices.
    pub fn create(
        &self,
        device_type: &str,
        device_id: &str,
        device_file: &str,
        channel_id: ChannelId,
        position: i32,
    ) -> Option<Box<dyn AudioDevice>> {
        match device_type {
            "builtin" => self.create_builtin(device_id, channel_id, position),
            "clap" => self.create_clap(device_id, device_file, channel_id, position),
            _ => {
                warn!(
                    "Unknown device type: {} (supported: builtin, clap)",
                    device_type
                );
                None
            }
        }
    }

    /// Create a built-in device by ID.
    fn create_builtin(
        &self,
        device_id: &str,
        channel_id: ChannelId,
        position: i32,
    ) -> Option<Box<dyn AudioDevice>> {
        let device: Box<dyn AudioDevice> = match device_id {
            "sonara.builtin.polysynth" => Box::new(PolySynthDevice::new(self.sample_rate)),
            "sonara.builtin.delay" => Box::new(DelayDevice::new(self.sample_rate, 5000.0)),
            "sonara.builtin.sfizz" => Box::new(SfizzDevice::new(
                self.sample_rate,
                self.max_buffer_size,
                channel_id as usize,
                position as usize,
                Some(self.status_tx.clone()),
            )),
            "sonara.builtin.spectrum_analyzer" => {
                Box::new(SpectrumAnalyzerDevice::new(self.sample_rate))
            }
            _ => {
                warn!("Unknown built-in device ID: {}", device_id);
                return None;
            }
        };
        info!("Created built-in device {}", device_id);
        Some(device)
    }

    /// Create a CLAP plugin device. The plugin subprocess loads on a background thread and is
    /// activated later.
    fn create_clap(
        &self,
        device_id: &str,
        device_file: &str,
        channel_id: ChannelId,
        position: i32,
    ) -> Option<Box<dyn AudioDevice>> {
        if device_file.is_empty() {
            warn!("CLAP plugin {} missing file path", device_id);
            return None;
        }

        info!("Loading CLAP plugin {} from {}", device_id, device_file);
        match SubprocessClapAdapter::new(
            Arc::clone(&self.process_manager),
            channel_id as u32,
            position as usize,
            PathBuf::from(device_file),
            device_id,
            self.sample_rate,
            self.max_buffer_size,
            Some(self.command_tx.clone()),
            Some(self.status_tx.clone()),
        ) {
            Ok(adapter) => {
                info!(
                    "CLAP plugin {} created, subprocess loading in background (activation deferred)",
                    device_id
                );
                Some(Box::new(adapter))
            }
            Err(e) => {
                warn!("Failed to load CLAP plugin {}: {}", device_id, e);
                None
            }
        }
    }

    /// Describe every built-in device (ports, parameters, file support) for Godot's browser.
    pub fn builtin_device_infos(&self) -> Vec<EngineStatus> {
        // TODO: Simplify this to avoid creating temporary instances
        let devices: [Box<dyn AudioDevice>; 4] = [
            Box::new(PolySynthDevice::new(self.sample_rate)),
            Box::new(DelayDevice::new(self.sample_rate, 5000.0)),
            Box::new(SpectrumAnalyzerDevice::new(self.sample_rate)),
            Box::new(SfizzDevice::new_for_metadata(self.sample_rate)),
        ];
        devices
            .iter()
            .map(|device| builtin_device_info(device.as_ref()))
            .collect()
    }
}

/// Build the `BuiltinDeviceInfo` status for one device instance.
fn builtin_device_info(device: &dyn AudioDevice) -> EngineStatus {
    let category = match device.device_category() {
        DeviceCategory::Instrument => "instrument",
        DeviceCategory::Effect => "effect",
        DeviceCategory::Utility => "utility",
    }
    .to_string();

    let parameters: Vec<BuiltinParamInfo> = device
        .parameters()
        .into_iter()
        .map(|p| BuiltinParamInfo {
            id: p.id,
            name: p.name,
            unit: p.unit,
            min: p.min,
            max: p.max,
            default: p.default,
            param_type: p.param_type,
            syncable: p.syncable,
            enum_values: p.enum_values,
        })
        .collect();

    let audio_ports = device.audio_ports();
    let port_channels = |flow: fn(&PortFlow) -> bool| {
        audio_ports
            .iter()
            .find(|p| flow(&p.flow))
            .map(|p| p.channels)
            .unwrap_or(0)
    };
    let audio_in_channels = port_channels(|flow| matches!(flow, PortFlow::Input));
    let audio_out_channels = port_channels(|flow| matches!(flow, PortFlow::Output));

    let (supports_file_loading, file_extensions, file_type_description) =
        match device.file_loading_support() {
            Some(info) => (true, info.extensions, info.description),
            None => (false, Vec::new(), String::new()),
        };

    EngineStatus::BuiltinDeviceInfo {
        id: device.device_id().to_string(),
        name: device.device_name().to_string(),
        category,
        description: format!("{} v{}", device.device_name(), device.version()),
        accepts_midi: !device.midi_ports().is_empty(),
        audio_in_channels,
        audio_out_channels,
        supports_file_loading,
        file_extensions,
        file_type_description,
        parameters,
    }
}
