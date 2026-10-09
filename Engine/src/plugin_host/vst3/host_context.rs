//! Host-side COM objects: the context handed to `IPluginBase::initialize`, and the
//! `IComponentHandler` the controller reports edits and restarts to.
//!
//! The context answers `getName` and refuses `createInstance` with `kNotImplemented`;
//! host-created `IMessage`/`IAttributeList` objects are out of scope for spec 028 v1, so
//! plugins fall back to synchronous calls. Later phases extend the interface list (e.g.
//! `IPlugFrame` and `IRunLoop` in one object, see the plan's GUI phase).
//!
//! `Vst3Shared` is the state the handler, the main thread and the audio thread share, like
//! `SubprocessHostShared` for CLAP. Parameter changes cross between the threads in two
//! preallocated queues, so the audio thread only ever `try_lock`s a buffer that already has
//! its capacity.

use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};

use ::vst3::Class;
use ::vst3::Steinberg::Vst::{
    IComponentHandler, IComponentHandlerTrait, IHostApplication, IHostApplicationTrait, ParamID,
    ParamValue, RestartFlags_, String128,
};
use ::vst3::Steinberg::{int32, kInvalidArgument, kNotImplemented, kResultOk, tresult, TUID};
use tracing::info;

use super::params::Vst3ParamMap;
use super::write_string128;
use crate::audio::ipc::{HostMessage, InstanceId, PluginEvent};

/// Parameter changes queued in each direction between audio blocks. More are dropped.
const CHANGE_QUEUE_CAPACITY: usize = 512;

/// State shared by one instance's component handler, main-thread service step and audio
/// thread.
pub struct Vst3Shared {
    instance_id: InstanceId,
    span: tracing::Span,
    event_tx: Sender<HostMessage>,
    /// Edits for the processor (`performEdit`, `SetParameter`): drained by the audio thread
    /// into the next block's parameter changes.
    to_audio: Mutex<Vec<(ParamID, ParamValue)>>,
    /// The processor's own parameter changes, for the controller: drained on the main thread.
    from_audio: Mutex<Vec<(ParamID, ParamValue)>>,
    param_map: Mutex<Arc<Vst3ParamMap>>,
    params_rescanned: AtomicBool,
    param_values_rescanned: AtomicBool,
    reactivate_requested: AtomicBool,
    state_dirty: AtomicBool,
}

impl Vst3Shared {
    pub fn new(instance_id: InstanceId, plugin_name: &str, event_tx: Sender<HostMessage>) -> Self {
        Self {
            instance_id,
            span: crate::plugin_host::logging::instance_span(instance_id, plugin_name),
            event_tx,
            to_audio: Mutex::new(Vec::with_capacity(CHANGE_QUEUE_CAPACITY)),
            from_audio: Mutex::new(Vec::with_capacity(CHANGE_QUEUE_CAPACITY)),
            param_map: Mutex::new(Arc::new(Vst3ParamMap::default())),
            params_rescanned: AtomicBool::new(false),
            param_values_rescanned: AtomicBool::new(false),
            reactivate_requested: AtomicBool::new(false),
            state_dirty: AtomicBool::new(false),
        }
    }

    pub fn span(&self) -> &tracing::Span {
        &self.span
    }

    pub fn set_param_map(&self, map: Arc<Vst3ParamMap>) {
        *self.param_map.lock().unwrap() = map;
    }

    pub fn param_map(&self) -> Arc<Vst3ParamMap> {
        Arc::clone(&self.param_map.lock().unwrap())
    }

    fn send_event(&self, event: PluginEvent) {
        let _ = self.event_tx.send(HostMessage::Event {
            instance_id: self.instance_id,
            event,
        });
    }

    /// Tell the engine the plugin's GUI wants a new size.
    pub fn request_gui_resize(&self, width: u32, height: u32) {
        self.send_event(PluginEvent::GuiResizeRequest { width, height });
    }

    /// Queue an edit for the processor. Dropped when the queue is full.
    pub fn queue_to_audio(&self, id: ParamID, value: ParamValue) {
        let mut queue = self.to_audio.lock().unwrap();
        if queue.len() < CHANGE_QUEUE_CAPACITY {
            queue.push((id, value));
        }
    }

    /// Audio thread: hand every queued edit to `apply`. Skipped when the main thread holds
    /// the queue; the edits stay queued for the next block.
    pub fn drain_to_audio(&self, mut apply: impl FnMut(ParamID, ParamValue)) {
        if let Ok(mut queue) = self.to_audio.try_lock() {
            for (id, value) in queue.drain(..) {
                apply(id, value);
            }
        }
    }

    /// Audio thread: record a parameter change the processor made, for the controller.
    pub fn push_from_audio(&self, id: ParamID, value: ParamValue) {
        if let Ok(mut queue) = self.from_audio.try_lock() {
            if queue.len() < CHANGE_QUEUE_CAPACITY {
                queue.push((id, value));
            }
        }
    }

    /// Main thread: the processor's parameter changes since the last call.
    pub fn take_from_audio(&self) -> Vec<(ParamID, ParamValue)> {
        // Copy rather than take: the shared queue keeps its capacity, so the audio thread's
        // next push never allocates.
        let mut queue = self.from_audio.lock().unwrap();
        let changes = queue.clone();
        queue.clear();
        changes
    }

    /// Tell the engine a parameter's value, by its engine index.
    pub fn report_value(&self, id: ParamID, value: ParamValue) {
        if let Some(param_id) = self.param_map().index_of(id) {
            self.send_event(PluginEvent::ParameterValueChanged {
                param_id,
                value: value as f32,
            });
        }
    }

    /// Tell the engine the saved state is stale. One event per saved blob (`clear_state_dirty`
    /// re-arms it), as for CLAP.
    pub fn mark_dirty(&self) {
        if !self.state_dirty.swap(true, Ordering::AcqRel) {
            self.send_event(PluginEvent::StateDirty);
        }
    }

    pub fn clear_state_dirty(&self) {
        self.state_dirty.store(false, Ordering::Release);
    }

    /// True once after the parameter list changed.
    pub fn take_params_rescanned(&self) -> bool {
        self.params_rescanned.swap(false, Ordering::AcqRel)
    }

    /// True once after parameter values changed without per-parameter edits.
    pub fn take_param_values_rescanned(&self) -> bool {
        self.param_values_rescanned.swap(false, Ordering::AcqRel)
    }

    /// True once after the plugin asked to be re-activated (latency changed).
    pub fn take_reactivate_requested(&self) -> bool {
        self.reactivate_requested.swap(false, Ordering::AcqRel)
    }

    /// React to `IComponentHandler::restartComponent`.
    pub fn restart(&self, flags: int32) {
        let _entered = self.span.enter();
        info!("Plugin requested restartComponent({:#x})", flags);
        if flags & RestartFlags_::kReloadComponent != 0 {
            self.params_rescanned.store(true, Ordering::Release);
            self.param_values_rescanned.store(true, Ordering::Release);
        }
        if flags & RestartFlags_::kParamTitlesChanged != 0 {
            self.params_rescanned.store(true, Ordering::Release);
        }
        if flags & RestartFlags_::kParamValuesChanged != 0 {
            self.param_values_rescanned.store(true, Ordering::Release);
        }
        if flags & RestartFlags_::kLatencyChanged != 0 {
            self.reactivate_requested.store(true, Ordering::Release);
        }
    }
}

/// The `IComponentHandler` the controller reports to.
pub struct ComponentHandler {
    shared: Arc<Vst3Shared>,
}

impl ComponentHandler {
    pub fn new(shared: Arc<Vst3Shared>) -> Self {
        Self { shared }
    }
}

impl Class for ComponentHandler {
    type Interfaces = (IComponentHandler,);
}

impl IComponentHandlerTrait for ComponentHandler {
    unsafe fn beginEdit(&self, _id: ParamID) -> tresult {
        kResultOk
    }

    /// A GUI edit: forward it to the processor and the engine, and mark the state dirty.
    unsafe fn performEdit(&self, id: ParamID, value_normalized: ParamValue) -> tresult {
        self.shared.queue_to_audio(id, value_normalized);
        self.shared.report_value(id, value_normalized);
        self.shared.mark_dirty();
        kResultOk
    }

    unsafe fn endEdit(&self, _id: ParamID) -> tresult {
        kResultOk
    }

    unsafe fn restartComponent(&self, flags: int32) -> tresult {
        self.shared.restart(flags);
        kResultOk
    }
}

pub struct HostContext;

impl HostContext {
    /// The name `getName` reports to plugins.
    pub const NAME: &'static str = "Sonara";
}

impl Class for HostContext {
    type Interfaces = (IHostApplication,);
}

impl IHostApplicationTrait for HostContext {
    unsafe fn getName(&self, name: *mut String128) -> tresult {
        if name.is_null() {
            return kInvalidArgument;
        }
        write_string128(name, "Sonara");
        kResultOk
    }

    unsafe fn createInstance(
        &self,
        _cid: *mut TUID,
        _iid: *mut TUID,
        obj: *mut *mut c_void,
    ) -> tresult {
        if !obj.is_null() {
            *obj = std::ptr::null_mut();
        }
        kNotImplemented
    }
}
