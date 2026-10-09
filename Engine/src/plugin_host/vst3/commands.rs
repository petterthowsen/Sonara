//! VST3 command handling in `plugin_host` (spec 028, phase 2).
//!
//! `process_vst3_command` answers every `PluginCommand` with the same `PluginResponse`
//! variants the CLAP path (`plugin_host/commands.rs`) uses. It is a parallel path, not a
//! shared one: the event loop dispatches on the instance's format.
//!
//! Everything here runs on the host's main thread, which is the only thread that may call
//! the controller (`IEditController`). The processor half is handed to the audio thread on
//! activation and taken back before deactivation.

use std::collections::HashMap;
use std::os::fd::{IntoRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::mpsc::Sender;
use std::sync::Arc;

use ::vst3::com_scrape_types::ComWrapper;
use ::vst3::Steinberg::Vst::*;
use ::vst3::Steinberg::{kResultOk, IBStream};
use tracing::{error, info, warn};

use super::host_context::{ComponentHandler, HostContext, Vst3Shared};
use super::instance::Vst3Instance;
use super::module::Vst3Module;
use super::params::{self, Vst3ParamMap};
use super::processor::Vst3Processor;
use super::state_blob;
use super::stream::MemoryStream;
use super::tuid_from_hex;
use crate::audio::ipc::{
    HostMessage, InstanceId, PluginCommand, PluginResponse, SharedMemory, SharedMemoryLayout,
};
use crate::plugin_host::audio_thread::AudioThreadHandle;

/// Loaded bundles, shared by every VST3 instance in this host process: hosting modes put
/// several instances of one plugin in a process, and a bundle is loaded (`ModuleEntry`) once.
#[derive(Default)]
pub struct Vst3Modules {
    modules: HashMap<PathBuf, Arc<Vst3Module>>,
}

impl Vst3Modules {
    pub fn get_or_load(&mut self, bundle: &Path) -> Result<Arc<Vst3Module>, String> {
        if let Some(module) = self.modules.get(bundle) {
            return Ok(Arc::clone(module));
        }
        // SAFETY: loading a plugin executes its code; that is what this process is for.
        let module = Arc::new(unsafe { Vst3Module::load(bundle)? });
        self.modules
            .insert(bundle.to_path_buf(), Arc::clone(&module));
        Ok(module)
    }

    pub fn len(&self) -> usize {
        self.modules.len()
    }

    pub fn is_empty(&self) -> bool {
        self.modules.is_empty()
    }
}

/// Main-thread state of one VST3 instance.
pub struct Vst3State {
    pub instance_id: InstanceId,
    pub span: tracing::Span,
    /// Dropped first: terminates the controller and the component.
    pub instance: Vst3Instance,
    pub shared: Arc<Vst3Shared>,
    /// Keeps the handler alive for as long as the controller may call it.
    _handler: ComWrapper<ComponentHandler>,
    pub shared_memory: Arc<SharedMemory>,
    pub activated: bool,
    pub sample_rate: f32,
    pub max_buffer_size: usize,
    /// Offline rendering, applied at the next `setupProcessing`.
    pub offline: bool,
    pub latency_frames: u32,
    pub param_map: Arc<Vst3ParamMap>,
}

fn not_initialized(command: &str) -> PluginResponse {
    PluginResponse::Error {
        command: command.to_string(),
        error: "Plugin not initialized".to_string(),
    }
}

/// Process a command for `instance_id`. The VST3 counterpart of `process_command`.
pub fn process_vst3_command(
    cmd: PluginCommand,
    instance_id: InstanceId,
    fds: Vec<OwnedFd>,
    plugin_state: &mut Option<Vst3State>,
    modules: &mut Vst3Modules,
    event_tx: &Sender<HostMessage>,
    audio: &AudioThreadHandle,
) -> Option<PluginResponse> {
    match cmd {
        PluginCommand::Initialize {
            plugin_path,
            plugin_id,
            sample_rate,
            max_buffer_size,
            ..
        } => {
            if plugin_state.is_some() {
                return Some(PluginResponse::InitializeError {
                    error: format!("Instance {} is already loaded in this host", instance_id),
                });
            }
            info!(
                "Initializing VST3 plugin: class {} from {:?} as instance {}",
                plugin_id, plugin_path, instance_id
            );
            let Some(shm_fd) = fds.into_iter().next() else {
                return Some(PluginResponse::InitializeError {
                    error: "Initialize came without a shared memory descriptor".to_string(),
                });
            };
            let layout = SharedMemoryLayout::new(max_buffer_size);
            let shared_memory = match SharedMemory::from_fd(shm_fd.into_raw_fd(), layout) {
                Ok(shm) => Arc::new(shm),
                Err(e) => {
                    error!("Failed to map shared memory: {}", e);
                    return Some(PluginResponse::InitializeError {
                        error: format!("Failed to map shared memory: {}", e),
                    });
                }
            };
            match initialize(
                instance_id,
                &plugin_path,
                &plugin_id,
                sample_rate,
                max_buffer_size,
                shared_memory,
                modules,
                event_tx,
            ) {
                Ok(state) => {
                    *plugin_state = Some(state);
                    info!("✅ VST3 plugin loaded, sending InitializeSuccess");
                    Some(PluginResponse::InitializeSuccess {
                        device_name: plugin_id,
                        device_vendor: "Unknown".to_string(),
                        device_version: "1.0".to_string(),
                        category: "effect".to_string(),
                    })
                }
                Err(error) => {
                    error!("Failed to load VST3 plugin: {}", error);
                    Some(PluginResponse::InitializeError { error })
                }
            }
        }

        // The GUI is phase 4 of spec 028.
        PluginCommand::OpenGui { .. } => Some(PluginResponse::GuiError {
            error: "VST3 plugin GUIs are not supported yet".to_string(),
        }),
        PluginCommand::CloseGui => Some(PluginResponse::GuiClosed),
        PluginCommand::SetGuiVisible { .. } | PluginCommand::SetGuiSize { .. } => {
            Some(PluginResponse::GuiError {
                error: "GUI is not open".to_string(),
            })
        }
        PluginCommand::HasGui => Some(PluginResponse::HasGuiResponse { supported: false }),

        PluginCommand::Shutdown => None,

        PluginCommand::Activate { sample_rate } => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(PluginResponse::ActivateResult {
                    success: false,
                    error: Some("Plugin not initialized".to_string()),
                    latency_frames: 0,
                });
            };
            if state.activated && (state.sample_rate - sample_rate).abs() < f32::EPSILON {
                return Some(PluginResponse::ActivateResult {
                    success: true,
                    error: None,
                    latency_frames: state.latency_frames,
                });
            }
            if state.activated {
                deactivate(state, audio);
            }
            state.sample_rate = sample_rate;
            match activate(state, audio) {
                Ok(latency) => {
                    info!(
                        "✅ VST3 plugin activated at {} Hz (latency {} frames)",
                        sample_rate, latency
                    );
                    Some(PluginResponse::ActivateResult {
                        success: true,
                        error: None,
                        latency_frames: latency,
                    })
                }
                Err(error) => {
                    error!("Failed to activate VST3 plugin: {}", error);
                    Some(PluginResponse::ActivateResult {
                        success: false,
                        error: Some(error),
                        latency_frames: 0,
                    })
                }
            }
        }

        PluginCommand::Deactivate => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(PluginResponse::DeactivateResult {
                    success: false,
                    error: Some("Plugin not initialized".to_string()),
                });
            };
            if state.activated {
                deactivate(state, audio);
                info!("✅ VST3 plugin deactivated");
            }
            Some(PluginResponse::DeactivateResult {
                success: true,
                error: None,
            })
        }

        // Processing starts and stops with activation, as for CLAP.
        PluginCommand::StartProcessing => match plugin_state {
            Some(state) if state.activated => Some(PluginResponse::ProcessingStarted),
            Some(_) => Some(PluginResponse::Error {
                command: "StartProcessing".to_string(),
                error: "Plugin not activated".to_string(),
            }),
            None => Some(not_initialized("StartProcessing")),
        },
        PluginCommand::StopProcessing => match plugin_state {
            Some(_) => Some(PluginResponse::ProcessingStopped),
            None => Some(not_initialized("StopProcessing")),
        },

        PluginCommand::Reset => {
            // setActive(false) then setActive(true), with processing stopped around it.
            if let Some(state) = plugin_state.as_mut() {
                if state.activated {
                    if let Err(e) = reactivate(state, audio) {
                        error!("Failed to reset VST3 plugin: {}", e);
                    }
                }
            }
            Some(PluginResponse::ResetComplete)
        }

        PluginCommand::SetRenderMode { offline } => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(PluginResponse::RenderModeSet { applied: false });
            };
            if state.offline == offline {
                return Some(PluginResponse::RenderModeSet { applied: true });
            }
            state.offline = offline;
            // The mode applies at `setupProcessing`: an active plugin is re-set-up now.
            let applied = if state.activated {
                match reactivate(state, audio) {
                    Ok(()) => true,
                    Err(e) => {
                        warn!("Could not apply the render mode: {}", e);
                        false
                    }
                }
            } else {
                true
            };
            info!(
                "Render mode set to {}",
                if offline { "offline" } else { "realtime" }
            );
            Some(PluginResponse::RenderModeSet { applied })
        }

        PluginCommand::Unload => {
            if let Some(state) = plugin_state.as_mut() {
                if state.activated {
                    deactivate(state, audio);
                }
            }
            // Dropping the state terminates the plugin on this (the main) thread.
            *plugin_state = None;
            audio.remove_instance(instance_id);
            info!("Unloaded VST3 instance {}", instance_id);
            Some(PluginResponse::Unloaded)
        }

        PluginCommand::SaveState => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(not_initialized("SaveState"));
            };
            // Clear before saving: a change during or after the save is newer than the blob.
            state.shared.clear_state_dirty();
            match save_state(&state.instance) {
                Ok(blob) => {
                    info!("Saved {} bytes of VST3 state", blob.len());
                    Some(PluginResponse::StateSaved { state: blob })
                }
                Err(error) => Some(PluginResponse::Error {
                    command: "SaveState".to_string(),
                    error,
                }),
            }
        }

        PluginCommand::LoadState { state: blob } => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(not_initialized("LoadState"));
            };
            match load_state(&state.instance, &blob) {
                Ok(()) => {
                    info!("Restored VST3 state ({} bytes)", blob.len());
                    report_all_values(state);
                    Some(PluginResponse::StateLoadResult {
                        success: true,
                        error: None,
                    })
                }
                Err(error) => Some(PluginResponse::StateLoadResult {
                    success: false,
                    error: Some(error),
                }),
            }
        }

        PluginCommand::GetParameterInfo => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(not_initialized("GetParameterInfo"));
            };
            let Some(controller) = state.instance.controller() else {
                return Some(PluginResponse::ParameterInfo { params: Vec::new() });
            };
            let infos = unsafe { params::describe_all(controller) };
            info!("✅ Queried {} parameters from VST3 plugin", infos.len());
            rebuild_param_map(state, audio);
            Some(PluginResponse::ParameterInfo { params: infos })
        }

        PluginCommand::GetParameter { param_id } => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(not_initialized("GetParameter"));
            };
            let (Some(id), Some(controller)) = (
                state.param_map.param_id(param_id),
                state.instance.controller(),
            ) else {
                return Some(PluginResponse::Error {
                    command: "GetParameter".to_string(),
                    error: format!("Parameter {} not found", param_id),
                });
            };
            let value = unsafe { controller.getParamNormalized(id) };
            Some(PluginResponse::ParameterValue {
                param_id,
                value: value as f32,
            })
        }

        PluginCommand::SetParameter { param_id, value } => {
            let Some(state) = plugin_state.as_mut() else {
                return Some(not_initialized("SetParameter"));
            };
            let (Some(id), Some(controller)) = (
                state.param_map.param_id(param_id),
                state.instance.controller(),
            ) else {
                return Some(PluginResponse::Error {
                    command: "SetParameter".to_string(),
                    error: format!("Parameter {} not found", param_id),
                });
            };
            let value = value.clamp(0.0, 1.0);
            // The controller always learns the value; the processor gets it as an input
            // parameter change at offset 0 of the next block, ordered with the audio it
            // affects.
            unsafe { controller.setParamNormalized(id, value as f64) };
            if state.activated {
                state.shared.queue_to_audio(id, value as f64);
            }
            // Echo the engine's own value back so Godot's control follows the model.
            let _ = event_tx.send(HostMessage::Event {
                instance_id,
                event: crate::audio::ipc::PluginEvent::ParameterValueChanged { param_id, value },
            });
            None // fire-and-forget
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn initialize(
    instance_id: InstanceId,
    bundle: &Path,
    plugin_id: &str,
    sample_rate: f32,
    max_buffer_size: usize,
    shared_memory: Arc<SharedMemory>,
    modules: &mut Vst3Modules,
    event_tx: &Sender<HostMessage>,
) -> Result<Vst3State, String> {
    let class_id = tuid_from_hex(plugin_id)
        .ok_or_else(|| format!("{:?} is not a VST3 class ID (32 hex characters)", plugin_id))?;
    let module = modules.get_or_load(bundle)?;

    let shared = Arc::new(Vst3Shared::new(instance_id, plugin_id, event_tx.clone()));
    let handler = ComWrapper::new(ComponentHandler::new(Arc::clone(&shared)));
    let host_context = ComWrapper::new(HostContext);

    // SAFETY: plugin code, on the host's main thread (the controller's thread).
    let instance = unsafe { Vst3Instance::create_inactive(&module, &class_id, &host_context)? };
    let handler_ptr = handler
        .to_com_ptr::<IComponentHandler>()
        .ok_or_else(|| "the component handler is not an IComponentHandler".to_string())?;
    unsafe { instance.set_component_handler(&handler_ptr) };

    let param_map = Arc::new(match instance.controller() {
        Some(controller) => unsafe { Vst3ParamMap::build(controller) },
        None => Vst3ParamMap::default(),
    });
    shared.set_param_map(Arc::clone(&param_map));

    Ok(Vst3State {
        instance_id,
        span: shared.span().clone(),
        instance,
        shared,
        _handler: handler,
        shared_memory,
        activated: false,
        sample_rate,
        max_buffer_size,
        offline: false,
        latency_frames: 0,
        param_map,
    })
}

/// `setupProcessing`, `setActive`, `setProcessing`, then hand the processor to the audio
/// thread. Returns the plugin's latency in frames.
fn activate(state: &mut Vst3State, audio: &AudioThreadHandle) -> Result<u32, String> {
    unsafe {
        if let Err(e) = state.instance.activate(
            state.sample_rate as f64,
            state.max_buffer_size as u32,
            state.offline,
        ) {
            state.instance.deactivate();
            return Err(e);
        }
    }
    let processor = Vst3Processor::new(
        state.instance.processor().clone(),
        Arc::clone(&state.shared),
        Arc::clone(&state.param_map),
        state.sample_rate as f64,
        state.offline,
        state.instance.audio_input_count() > 0,
    );
    if let Err(e) = audio.set_vst3_processor(
        state.instance_id,
        processor,
        Arc::clone(&state.shared_memory),
        state.span.clone(),
    ) {
        unsafe { state.instance.deactivate() };
        return Err(e);
    }
    state.latency_frames = state.instance.latency_samples();
    state.activated = true;
    Ok(state.latency_frames)
}

/// Take the processor back from the audio thread, then stop and deactivate the plugin.
fn deactivate(state: &mut Vst3State, audio: &AudioThreadHandle) {
    // The audio thread answers any request in flight before it lets go.
    drop(audio.take_vst3_processor(state.instance_id));
    unsafe { state.instance.deactivate() };
    state.activated = false;
}

/// `setActive(false)` then `setActive(true)` at the current rate and mode.
fn reactivate(state: &mut Vst3State, audio: &AudioThreadHandle) -> Result<(), String> {
    deactivate(state, audio);
    activate(state, audio).map(|_| ())
}

/// Rebuild the parameter map from the controller and publish it to the audio thread.
fn rebuild_param_map(state: &mut Vst3State, audio: &AudioThreadHandle) {
    let Some(controller) = state.instance.controller() else {
        return;
    };
    state.param_map = Arc::new(unsafe { Vst3ParamMap::build(controller) });
    state.shared.set_param_map(Arc::clone(&state.param_map));
    audio.set_vst3_param_map(state.instance_id, Arc::clone(&state.param_map));
}

/// Send every parameter's current value to the engine.
fn report_all_values(state: &Vst3State) {
    let Some(controller) = state.instance.controller() else {
        return;
    };
    let mut sent = 0;
    for index in 0..state.param_map.len() {
        if let Some(id) = state.param_map.param_id(index) {
            let value = unsafe { controller.getParamNormalized(id) };
            state.shared.report_value(id, value);
            sent += 1;
        }
    }
    info!("Reported {} parameter values", sent);
}

/// Pack the component and controller states into the engine's single blob.
fn save_state(instance: &Vst3Instance) -> Result<Vec<u8>, String> {
    let component_stream = ComWrapper::new(MemoryStream::empty());
    let component_ptr = component_stream
        .to_com_ptr::<IBStream>()
        .ok_or("memory stream is not an IBStream")?;
    let result = unsafe { instance.component().getState(component_ptr.as_ptr()) };
    if result != kResultOk {
        return Err(format!(
            "IComponent::getState failed with tresult {}",
            result
        ));
    }
    let component_bytes = component_stream.take_bytes();

    let mut controller_bytes = Vec::new();
    if let Some(controller) = instance.controller() {
        let controller_stream = ComWrapper::new(MemoryStream::empty());
        let controller_ptr = controller_stream
            .to_com_ptr::<IBStream>()
            .ok_or("memory stream is not an IBStream")?;
        // A controller with no state of its own may decline; that is an empty stream.
        if unsafe { controller.getState(controller_ptr.as_ptr()) } == kResultOk {
            controller_bytes = controller_stream.take_bytes();
        }
    }
    Ok(state_blob::pack(&component_bytes, &controller_bytes))
}

/// `component.setState`, then `controller.setComponentState` with the component bytes, then
/// `controller.setState` with the controller bytes.
fn load_state(instance: &Vst3Instance, blob: &[u8]) -> Result<(), String> {
    let (component_bytes, controller_bytes) = state_blob::unpack(blob)?;
    let stream = |bytes: &[u8]| -> Result<_, String> {
        let wrapper = ComWrapper::new(MemoryStream::with_bytes(bytes.to_vec()));
        let ptr = wrapper
            .to_com_ptr::<IBStream>()
            .ok_or("memory stream is not an IBStream")?;
        Ok((wrapper, ptr))
    };

    let (_keep, component_stream) = stream(component_bytes)?;
    let result = unsafe { instance.component().setState(component_stream.as_ptr()) };
    if result != kResultOk {
        return Err(format!(
            "IComponent::setState failed with tresult {}",
            result
        ));
    }
    if let Some(controller) = instance.controller() {
        let (_keep, component_again) = stream(component_bytes)?;
        let result = unsafe { controller.setComponentState(component_again.as_ptr()) };
        if result != kResultOk {
            warn!(
                "IEditController::setComponentState returned tresult {}",
                result
            );
        }
        if !controller_bytes.is_empty() {
            let (_keep, controller_stream) = stream(controller_bytes)?;
            let result = unsafe { controller.setState(controller_stream.as_ptr()) };
            if result != kResultOk {
                warn!("IEditController::setState returned tresult {}", result);
            }
        }
    }
    Ok(())
}

/// Main-thread upkeep between commands: rebuild the parameter map after a rescan, report
/// values after a wholesale change, keep the controller in step with the processor's own
/// parameter changes, and re-activate when the plugin's latency changed.
pub fn service_vst3(state: &mut Vst3State, audio: &AudioThreadHandle) {
    if state.shared.take_params_rescanned() {
        rebuild_param_map(state, audio);
        info!(
            "Parameter map rebuilt after a rescan ({} parameters)",
            state.param_map.len()
        );
    }
    if state.shared.take_param_values_rescanned() {
        report_all_values(state);
    }
    // The processor's changes already reached the engine through the block's output events;
    // the controller still has to learn them.
    let changes = state.shared.take_from_audio();
    if !changes.is_empty() {
        if let Some(controller) = state.instance.controller() {
            for (id, value) in changes {
                unsafe { controller.setParamNormalized(id, value) };
            }
        }
    }
    if state.shared.take_reactivate_requested() && state.activated {
        info!("Re-activating after a latency change");
        if let Err(e) = reactivate(state, audio) {
            error!("Re-activation failed: {}", e);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loading_a_missing_bundle_is_an_error_and_is_not_cached() {
        let mut modules = Vst3Modules::default();
        let missing = Path::new("/nonexistent/Plugin.vst3");
        assert!(modules.get_or_load(missing).is_err());
        assert!(modules.is_empty());
    }
}
