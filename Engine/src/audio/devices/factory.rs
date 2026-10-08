//! Builds devices by type and ID. Runs on the command thread, never on the audio thread.

use crossbeam::channel::Sender;
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{info, warn};

use super::clap_host::SubprocessClapAdapter;
use super::{
    AudioDevice, ChainDevice, ChorusDevice, DelayDevice, DevicePath, DrumMachineDevice,
    FilterDevice, LayerDevice, MultibandDevice, PolySynthDevice, PortFlow, ReverbDevice,
    SamplerDevice, SfizzDevice, SpectrumAnalyzerDevice, UtilityDevice,
};
use crate::audio::block_clock::BlockClock;
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
    block_clock: Arc<BlockClock>,
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
        block_clock: Arc<BlockClock>,
    ) -> Self {
        Self {
            process_manager,
            sample_rate,
            max_buffer_size,
            status_tx,
            command_tx,
            block_clock,
        }
    }

    /// Rate for devices created from now on (Phase 7: the device rate changed).
    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        self.sample_rate = sample_rate;
    }

    /// Create a device of `device_type` ("builtin" or "clap"). `vendor` is the plugin's vendor
    /// (CLAP only; it picks the host process in "By vendor" hosting). Logs and returns None for
    /// unknown or failed devices.
    pub fn create(
        &self,
        device_type: &str,
        device_id: &str,
        device_file: &str,
        vendor: &str,
        channel_id: ChannelId,
        device_path: &DevicePath,
    ) -> Option<Box<dyn AudioDevice>> {
        match device_type {
            "builtin" => self.create_builtin(device_id, channel_id, device_path),
            "clap" => self.create_clap(device_id, device_file, vendor, channel_id, device_path),
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
        device_path: &DevicePath,
    ) -> Option<Box<dyn AudioDevice>> {
        if let Some(device) = create_effect(device_id, self.sample_rate, self.max_buffer_size) {
            info!("Created built-in effect {}", device_id);
            return Some(device);
        }
        if let Some(device) = create_drum(device_id, self.sample_rate, self.max_buffer_size) {
            info!("Created built-in drum {}", device_id);
            return Some(device);
        }
        if let Some(device) = create_note_effect(device_id, self.sample_rate, self.max_buffer_size)
        {
            info!("Created built-in note effect {}", device_id);
            return Some(device);
        }
        let device: Box<dyn AudioDevice> = match device_id {
            "sonara.builtin.polysynth" => Box::new(PolySynthDevice::new(self.sample_rate)),
            "sonara.builtin.sfizz" => Box::new(SfizzDevice::new(
                self.sample_rate,
                self.max_buffer_size,
                channel_id as usize,
                device_path.clone(),
                Some(self.status_tx.clone()),
            )),
            "sonara.builtin.spectrum_analyzer" => {
                Box::new(SpectrumAnalyzerDevice::new(self.sample_rate))
            }
            "sonara.builtin.chain" => Box::new(ChainDevice::new(self.max_buffer_size)),
            "sonara.builtin.layer" => Box::new(LayerDevice::new(self.max_buffer_size)),
            "sonara.builtin.multiband" => {
                Box::new(MultibandDevice::new(self.sample_rate, self.max_buffer_size))
            }
            "sonara.builtin.sampler" => Box::new(SamplerDevice::new(
                self.sample_rate,
                channel_id as usize,
                device_path.clone(),
                Some(self.status_tx.clone()),
            )),
            "sonara.builtin.drum_machine" => Box::new(DrumMachineDevice::new(self.max_buffer_size)),
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
        vendor: &str,
        channel_id: ChannelId,
        device_path: &DevicePath,
    ) -> Option<Box<dyn AudioDevice>> {
        if device_file.is_empty() {
            warn!("CLAP plugin {} missing file path", device_id);
            return None;
        }

        info!("Loading CLAP plugin {} from {}", device_id, device_file);
        match SubprocessClapAdapter::new(
            Arc::clone(&self.process_manager),
            channel_id as u32,
            device_path.clone(),
            PathBuf::from(device_file),
            device_id,
            vendor,
            self.sample_rate,
            self.max_buffer_size,
            Some(self.command_tx.clone()),
            Some(self.status_tx.clone()),
            Arc::clone(&self.block_clock),
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
        let others: [Box<dyn AudioDevice>; 8] = [
            Box::new(PolySynthDevice::new(self.sample_rate)),
            Box::new(SpectrumAnalyzerDevice::new(self.sample_rate)),
            Box::new(SfizzDevice::new_for_metadata(self.sample_rate)),
            Box::new(ChainDevice::new(self.max_buffer_size)),
            Box::new(LayerDevice::new(self.max_buffer_size)),
            Box::new(MultibandDevice::new(self.sample_rate, self.max_buffer_size)),
            Box::new(SamplerDevice::new_for_metadata()),
            Box::new(DrumMachineDevice::new(self.max_buffer_size)),
        ];
        let drums = DRUM_IDS
            .iter()
            .filter_map(|id| create_drum(id, self.sample_rate, self.max_buffer_size));
        let effects = EFFECT_IDS
            .iter()
            .filter_map(|id| create_effect(id, self.sample_rate, self.max_buffer_size));
        let note_effects = NOTE_EFFECT_IDS
            .iter()
            .filter_map(|id| create_note_effect(id, self.sample_rate, self.max_buffer_size));
        others
            .into_iter()
            .chain(drums)
            .chain(effects)
            .chain(note_effects)
            .map(|device| builtin_device_info(device.as_ref()))
            .collect()
    }
}

/// Built-in audio effects (spec 012): each is made from the sample rate and block size alone.
/// The effect conformance test runs over this list, so a new effect is covered by adding it here.
pub const EFFECT_IDS: &[&str] = &[
    "sonara.builtin.delay",
    "sonara.builtin.eq",
    "sonara.builtin.compressor",
    "sonara.builtin.filter",
    "sonara.builtin.chorus",
    "sonara.builtin.phaser",
    "sonara.builtin.reverb",
    "sonara.builtin.utility",
];

/// Built-in drum instruments (spec 013). Each is made from the sample rate and block size alone.
/// The drum conformance test runs over this list, so a new drum is covered by adding it here.
pub const DRUM_IDS: &[&str] = &[
    "sonara.builtin.kick",
    "sonara.builtin.snare",
    "sonara.builtin.hat",
    "sonara.builtin.clap",
];

/// Built-in note effects (spec 027). Each is made from the sample rate alone. The note-effect
/// conformance test (`note_fx/conformance.rs`) runs over this list, so a new note effect is
/// covered by adding it here.
pub const NOTE_EFFECT_IDS: &[&str] = &[
    "sonara.builtin.transpose",
    "sonara.builtin.note_filter",
    "sonara.builtin.velocity",
    "sonara.builtin.chord",
    "sonara.builtin.arpeggiator",
    "sonara.builtin.chance",
    "sonara.builtin.step_sequencer",
    "sonara.builtin.note_echo",
    "sonara.builtin.note_length",
    "sonara.builtin.latch",
];

/// Create a built-in note effect from [`NOTE_EFFECT_IDS`], prepared for `sample_rate`. Command
/// thread only (allocates). None for any other ID.
pub fn create_note_effect(
    device_id: &str,
    sample_rate: f32,
    max_frames: usize,
) -> Option<Box<dyn AudioDevice>> {
    use super::note_fx::{
        arpeggiator::Arpeggiator, chance::Chance, chord::Chord, latch::Latch, note_echo::NoteEcho,
        note_filter::NoteFilter, note_length::NoteLength, step_sequencer::StepSequencer,
        transpose::Transpose, velocity::Velocity, NoteFxHost,
    };
    let mut device: Box<dyn AudioDevice> = match device_id {
        "sonara.builtin.transpose" => Box::new(NoteFxHost::<Transpose>::new(sample_rate)),
        "sonara.builtin.note_filter" => Box::new(NoteFxHost::<NoteFilter>::new(sample_rate)),
        "sonara.builtin.velocity" => Box::new(NoteFxHost::<Velocity>::new(sample_rate)),
        "sonara.builtin.chord" => Box::new(NoteFxHost::<Chord>::new(sample_rate)),
        "sonara.builtin.arpeggiator" => Box::new(NoteFxHost::<Arpeggiator>::new(sample_rate)),
        "sonara.builtin.chance" => Box::new(NoteFxHost::<Chance>::new(sample_rate)),
        "sonara.builtin.step_sequencer" => Box::new(NoteFxHost::<StepSequencer>::new(sample_rate)),
        "sonara.builtin.note_echo" => Box::new(NoteFxHost::<NoteEcho>::new(sample_rate)),
        "sonara.builtin.note_length" => Box::new(NoteFxHost::<NoteLength>::new(sample_rate)),
        "sonara.builtin.latch" => Box::new(NoteFxHost::<Latch>::new(sample_rate)),
        _ => return None,
    };
    device.prepare(sample_rate, max_frames);
    Some(device)
}

/// Create a built-in drum from [`DRUM_IDS`], prepared for `sample_rate` and blocks of up to
/// `max_frames`. Command thread only (allocates). None for any other ID.
pub fn create_drum(
    device_id: &str,
    sample_rate: f32,
    max_frames: usize,
) -> Option<Box<dyn AudioDevice>> {
    use super::drums::{
        clap::ClapVoice, hat::HatVoice, kick::KickVoice, snare::SnareVoice, DrumHost,
    };
    let mut device: Box<dyn AudioDevice> = match device_id {
        "sonara.builtin.kick" => Box::new(DrumHost::<KickVoice>::new(sample_rate, max_frames)),
        "sonara.builtin.snare" => Box::new(DrumHost::<SnareVoice>::new(sample_rate, max_frames)),
        "sonara.builtin.hat" => Box::new(DrumHost::<HatVoice>::new(sample_rate, max_frames)),
        "sonara.builtin.clap" => Box::new(DrumHost::<ClapVoice>::new(sample_rate, max_frames)),
        _ => return None,
    };
    device.prepare(sample_rate, max_frames);
    Some(device)
}

/// Create a built-in effect from [`EFFECT_IDS`], prepared for `sample_rate` and blocks of up to
/// `max_frames`. Command thread only (allocates). None for any other ID.
pub fn create_effect(
    device_id: &str,
    sample_rate: f32,
    max_frames: usize,
) -> Option<Box<dyn AudioDevice>> {
    let mut device: Box<dyn AudioDevice> = match device_id {
        "sonara.builtin.delay" => Box::new(DelayDevice::new(sample_rate, 5000.0)),
        "sonara.builtin.eq" => Box::new(super::eq::EqDevice::new(sample_rate)),
        "sonara.builtin.compressor" => {
            Box::new(super::compressor::CompressorDevice::new(sample_rate))
        }
        "sonara.builtin.filter" => Box::new(FilterDevice::new(sample_rate)),
        "sonara.builtin.chorus" => Box::new(ChorusDevice::new(sample_rate)),
        "sonara.builtin.phaser" => Box::new(super::PhaserDevice::new(sample_rate)),
        "sonara.builtin.reverb" => Box::new(ReverbDevice::new(sample_rate)),
        "sonara.builtin.utility" => Box::new(UtilityDevice::new(sample_rate)),
        _ => return None,
    };
    device.prepare(sample_rate, max_frames);
    Some(device)
}

/// Build the `BuiltinDeviceInfo` status for one device instance.
fn builtin_device_info(device: &dyn AudioDevice) -> EngineStatus {
    let category = device.device_category().as_str().to_string();

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
            is_logarithmic: p.is_logarithmic,
            skew: p.skew,
            module: p.module,
            is_automation_safe: p.is_automation_safe,
            is_modulatable: p.is_modulatable,
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
        is_container: device.is_container(),
        parameters,
        default_modulators: device.default_modulators(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::devices::container::DeviceContainer;
    use crate::audio::dsp::test_util::peak;
    use crate::audio::midi_types::{NoteEvent, NoteExpression};

    /// A note on key 36 held for a quarter second, rendered in 256-frame blocks, with an
    /// expression event for it in every block when `expressions` is set.
    fn render_note(device: &mut dyn AudioDevice, expressions: bool) -> Vec<f32> {
        const SR: f32 = 48_000.0;
        const BLOCK: usize = 256;
        device.prepare(SR, BLOCK);
        let on = NoteEvent::test_on(36, 100);
        let silence = [0.0; BLOCK * 2];
        let mut out = vec![0.0; (SR as usize / 2) * 2];
        device.send_note_event(&on, 0);
        for (i, block) in out.chunks_mut(BLOCK * 2).enumerate() {
            if expressions {
                let expression = NoteEvent::Expression {
                    note_id: on.note_id(),
                    key: on.key(),
                    kind: NoteExpression::Pitch,
                    value: 2.0,
                };
                device.send_note_event(&expression, 3);
            }
            if i == 47 {
                device.send_note_event(&NoteEvent::test_off(36), 0);
            }
            device.process_block(&silence[..block.len()], block, block.len() / 2);
        }
        out
    }

    /// The built-ins that aren't covered by the effect and drum conformance runs: instruments
    /// and containers ignore a per-note expression event (REQ-013). The ones that make no sound
    /// without a loaded file (Sampler, sfizz) must still take the event without panicking.
    #[test]
    fn expression_event_is_ignored_by_instruments_and_containers() {
        const SR: f32 = 48_000.0;
        type Make = fn() -> Box<dyn AudioDevice>;
        fn with_synth(mut container: Box<dyn AudioDevice>) -> Box<dyn AudioDevice> {
            container
                .as_container_mut()
                .expect("container")
                .insert_child(0, Box::new(PolySynthDevice::new(SR)));
            container
        }
        let cases: [(&str, bool, Make); 8] = [
            ("polysynth", true, || Box::new(PolySynthDevice::new(SR))),
            ("sampler", false, || {
                Box::new(SamplerDevice::new_for_metadata())
            }),
            ("sfizz", false, || {
                Box::new(SfizzDevice::new_for_metadata(SR))
            }),
            ("spectrum_analyzer", false, || {
                Box::new(SpectrumAnalyzerDevice::new(SR))
            }),
            ("chain", true, || {
                with_synth(Box::new(ChainDevice::new(512)))
            }),
            ("layer", true, || {
                with_synth(Box::new(LayerDevice::new(512)))
            }),
            ("drum_machine", true, || {
                with_synth(Box::new(DrumMachineDevice::new(512)))
            }),
            ("multiband", false, || {
                Box::new(MultibandDevice::new(SR, 512))
            }),
        ];
        for (name, sounds, make) in cases {
            let reference = render_note(make().as_mut(), false);
            assert_eq!(peak(&reference) > 0.0, sounds, "{name}: unexpected level");
            assert!(
                render_note(make().as_mut(), true) == reference,
                "{name}: an expression event changed the output"
            );
        }
    }

    #[test]
    fn multiband_is_advertised_as_an_effect_container() {
        let device = MultibandDevice::new(48_000.0, 512);
        let EngineStatus::BuiltinDeviceInfo {
            id,
            category,
            is_container,
            accepts_midi,
            parameters,
            ..
        } = builtin_device_info(&device)
        else {
            panic!("expected BuiltinDeviceInfo");
        };
        assert_eq!(id, "sonara.builtin.multiband");
        assert_eq!(category, "effect");
        assert!(is_container);
        assert!(!accepts_midi);
        // Mix + Output, then Active + Gain + Mute + Solo per band, plus Low Edge for bands 2..6.
        assert_eq!(parameters.len(), 2 + 6 * 4 + 5);
        let active = parameters
            .iter()
            .find(|p| p.id == 10)
            .expect("band 1 Active");
        assert!(!active.is_automation_safe);
    }

    #[test]
    fn multiband_is_a_container_not_an_effect_id() {
        assert!(!EFFECT_IDS.contains(&"sonara.builtin.multiband"));
        assert!(create_effect("sonara.builtin.multiband", 48_000.0, 512).is_none());
    }
}
