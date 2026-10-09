//! `Vst3Instance`: component plus controller, created from a class in a loaded
//! `Vst3Module`, with the same activate/process split the CLAP path uses.
//!
//! All calls into the plugin happen on the thread that owns the instance (the
//! `plugin_host` main thread, or the probe's single thread); `IAudioProcessor::process`
//! is only called by the code holding the `ProcessData`, matching the CLAP split between
//! instance and processor (spec 028, ground rules).

use std::ffi::c_void;
use std::sync::Arc;

use ::vst3::com_scrape_types::{ComPtr, ComWrapper};
use ::vst3::Interface;
use ::vst3::Steinberg::Vst::*;
use ::vst3::Steinberg::{
    kNotImplemented, kResultOk, FUnknown, IPluginBaseTrait, IPluginFactory, IPluginFactoryTrait,
    TUID,
};

use super::host_context::HostContext;
use super::module::Vst3Module;

pub struct Vst3Instance {
    /// Keeps the module code mapped for as long as any instance from it is alive.
    _module: Arc<Vst3Module>,
    /// Keeps the host context alive; plugins may hold a reference to it.
    _host_context: ComWrapper<HostContext>,
    component: ComPtr<IComponent>,
    controller: Option<ComPtr<IEditController>>,
    /// True when the component also implements `IEditController`: then only the component is
    /// `terminate`d, once.
    controller_is_component: bool,
    component_connection: Option<ComPtr<IConnectionPoint>>,
    controller_connection: Option<ComPtr<IConnectionPoint>>,
    processor: ComPtr<IAudioProcessor>,
    audio_inputs: i32,
    audio_outputs: i32,
    event_inputs: i32,
    active: bool,
    processing: bool,
}

/// Create the COM object for `class_id` through the factory, queried for interface `I`.
/// `_iid` is the interface id passed to `createInstance`.
unsafe fn factory_instance<I: Interface>(
    factory: &ComPtr<IPluginFactory>,
    class_id: &TUID,
    iid: &TUID,
) -> Result<ComPtr<I>, String> {
    let mut object: *mut c_void = std::ptr::null_mut();
    let result = factory.createInstance(class_id.as_ptr(), iid.as_ptr(), &mut object);
    if result != kResultOk {
        return Err(format!("createInstance failed with tresult {}", result));
    }
    ComPtr::from_raw(object as *mut I).ok_or_else(|| "createInstance returned null".to_string())
}

impl Vst3Instance {
    /// Create the component and controller for `class_id`, connect them, set up stereo
    /// buses, and activate: `setupProcessing`, `setActive(true)`, `setProcessing(true)`
    /// (spec 028, phase 1).
    ///
    /// # Safety
    /// Calls plugin code. The module must have been loaded in this process, and every call
    /// must happen on one thread.
    pub unsafe fn create(
        module: &Arc<Vst3Module>,
        class_id: &TUID,
        host_context: &ComWrapper<HostContext>,
        sample_rate: f64,
        max_block_frames: u32,
    ) -> Result<Self, String> {
        let factory = module.factory();
        let context = host_context
            .to_com_ptr::<IHostApplication>()
            .ok_or_else(|| "host context does not implement IHostApplication".to_string())?;
        let context_ptr = context.as_ptr() as *mut FUnknown;

        // 1. The component (the audio-processing object).
        let component = factory_instance::<IComponent>(factory, class_id, &IComponent_iid)?;
        if component.initialize(context_ptr) != kResultOk {
            return Err("IComponent::initialize failed".to_string());
        }

        // 2. The controller: either the same object also implements IEditController, or the
        // component names a separate controller class.
        let (controller, controller_is_component) = match component.cast::<IEditController>() {
            Some(controller) => (controller, true),
            None => {
                let mut controller_id: TUID = [0; 16];
                if component.getControllerClassId(&mut controller_id) != kResultOk
                    || controller_id.iter().all(|byte| *byte == 0)
                {
                    return Err(
                        "no edit controller: the component neither implements IEditController \
                         nor names a controller class"
                            .to_string(),
                    );
                }
                let controller = factory_instance::<IEditController>(
                    factory,
                    &controller_id,
                    &IEditController_iid,
                )?;
                if controller.initialize(context_ptr) != kResultOk {
                    return Err("IEditController::initialize failed".to_string());
                }
                (controller, false)
            }
        };

        // 3. Connect component and controller so parameter changes reach the processor.
        // Connect in both directions: JUCE's split controller installs its AudioProcessor
        // (and with it the parameter list) only when its own `connect` sees the component.
        let component_connection = component.cast::<IConnectionPoint>();
        let controller_connection = controller.cast::<IConnectionPoint>();
        match (&component_connection, &controller_connection) {
            (Some(from), Some(to)) => {
                if from.connect(to.as_ptr()) != kResultOk {
                    tracing::warn!(
                        "IConnectionPoint::connect (component to controller) failed; \
                         component/controller sync may not work"
                    );
                }
                if to.connect(from.as_ptr()) != kResultOk {
                    tracing::warn!(
                        "IConnectionPoint::connect (controller to component) failed; \
                         component/controller sync may not work"
                    );
                }
            }
            _ => tracing::warn!("component or controller has no IConnectionPoint"),
        }

        // 4. The audio processor.
        let processor = component
            .cast::<IAudioProcessor>()
            .ok_or_else(|| "the component has no IAudioProcessor".to_string())?;

        // 5. Buses: stereo in and out; instruments have no audio inputs. Only the main audio
        // buses and event input 0 are activated (aux/sidechain buses are out of scope).
        let audio_inputs =
            component.getBusCount(MediaTypes_::kAudio as i32, BusDirections_::kInput as i32);
        let audio_outputs =
            component.getBusCount(MediaTypes_::kAudio as i32, BusDirections_::kOutput as i32);
        let event_inputs =
            component.getBusCount(MediaTypes_::kEvent as i32, BusDirections_::kInput as i32);

        let mut stereo_in = [SpeakerArr::kStereo];
        let mut stereo_out = [SpeakerArr::kStereo];
        let mut no_inputs: [SpeakerArrangement; 0] = [];
        let (inputs, num_inputs) = if audio_inputs > 0 {
            (stereo_in.as_mut_ptr(), 1)
        } else {
            (no_inputs.as_mut_ptr(), 0)
        };
        let num_outputs = if audio_outputs > 0 { 1 } else { 0 };
        if processor.setBusArrangements(inputs, num_inputs, stereo_out.as_mut_ptr(), num_outputs)
            != kResultOk
        {
            tracing::warn!(
                "setBusArrangements(stereo) failed; the plugin keeps its own arrangement"
            );
        }
        if audio_inputs > 0
            && component.activateBus(
                MediaTypes_::kAudio as i32,
                BusDirections_::kInput as i32,
                0,
                1,
            ) != kResultOk
        {
            tracing::warn!("activateBus(audio input 0) failed");
        }
        if audio_outputs > 0
            && component.activateBus(
                MediaTypes_::kAudio as i32,
                BusDirections_::kOutput as i32,
                0,
                1,
            ) != kResultOk
        {
            tracing::warn!("activateBus(audio output 0) failed");
        }
        if event_inputs > 0
            && component.activateBus(
                MediaTypes_::kEvent as i32,
                BusDirections_::kInput as i32,
                0,
                1,
            ) != kResultOk
        {
            tracing::warn!("activateBus(event input 0) failed");
        }

        // 6. Real-time float processing, then activate.
        let mut setup = ProcessSetup {
            processMode: ProcessModes_::kRealtime as i32,
            symbolicSampleSize: SymbolicSampleSizes_::kSample32 as i32,
            maxSamplesPerBlock: max_block_frames as i32,
            sampleRate: sample_rate,
        };
        if processor.setupProcessing(&mut setup) != kResultOk {
            return Err("setupProcessing failed".to_string());
        }
        if component.setActive(1) != kResultOk {
            return Err("setActive(true) failed".to_string());
        }
        let active = true;
        let set_processing_result = processor.setProcessing(1);
        // kNotImplemented means the plugin does not toggle its processing state; hosts are
        // expected to continue (sfizz does this). Anything else is a real failure.
        if set_processing_result != kResultOk && set_processing_result != kNotImplemented {
            return Err(format!(
                "setProcessing(true) failed with tresult {}",
                set_processing_result
            ));
        }
        let processing = true;

        Ok(Self {
            _module: module.clone(),
            _host_context: host_context.clone(),
            component,
            controller: Some(controller),
            controller_is_component,
            component_connection,
            controller_connection,
            processor,
            audio_inputs,
            audio_outputs,
            event_inputs,
            active,
            processing,
        })
    }

    pub fn component(&self) -> &ComPtr<IComponent> {
        &self.component
    }

    pub fn controller(&self) -> Option<&ComPtr<IEditController>> {
        self.controller.as_ref()
    }

    pub fn processor(&self) -> &ComPtr<IAudioProcessor> {
        &self.processor
    }

    pub fn audio_input_count(&self) -> i32 {
        self.audio_inputs
    }

    pub fn audio_output_count(&self) -> i32 {
        self.audio_outputs
    }

    pub fn event_input_count(&self) -> i32 {
        self.event_inputs
    }

    /// Latency the plugin reports after activation, in samples.
    pub fn latency_samples(&self) -> u32 {
        unsafe { self.processor.getLatencySamples() }
    }

    /// Bus description for printing and diagnostics.
    pub fn bus_info(&self, media_type: i32, direction: i32, index: i32) -> Option<BusInfo> {
        let mut info: BusInfo = unsafe { std::mem::zeroed() };
        let result = unsafe {
            self.component
                .getBusInfo(media_type, direction, index, &mut info)
        };
        (result == kResultOk).then_some(info)
    }

    /// Run one processing block. The caller owns the buffers and event lists.
    ///
    /// # Safety
    /// `data` must point at buffers that stay alive for the call, and this must be called
    /// from one thread only.
    pub unsafe fn process(&mut self, data: *mut ProcessData) -> i32 {
        self.processor.process(data)
    }
}

impl Drop for Vst3Instance {
    /// Reverse of creation: stop processing, deactivate, disconnect, then terminate the
    /// controller and the component (once, when they are the same object).
    fn drop(&mut self) {
        unsafe {
            if self.processing {
                self.processor.setProcessing(0);
                self.processing = false;
            }
            if self.active {
                self.component.setActive(0);
                self.active = false;
            }
            if let (Some(from), Some(to)) =
                (&self.component_connection, &self.controller_connection)
            {
                from.disconnect(to.as_ptr());
                to.disconnect(from.as_ptr());
            }
            if let Some(controller) = &self.controller {
                if !self.controller_is_component {
                    controller.terminate();
                }
            }
            self.component.terminate();
        }
    }
}
