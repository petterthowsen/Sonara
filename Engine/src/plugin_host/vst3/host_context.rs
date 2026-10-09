//! Host-side COM context object handed to `IPluginBase::initialize`.
//!
//! v1 answers `getName` and refuses `createInstance` with `kNotImplemented`; host-created
//! `IMessage`/`IAttributeList` objects are out of scope for spec 028 phase 1. Plugins fall
//! back to synchronous calls. Later phases extend the interface list (e.g. `IPlugFrame` and
//! `IRunLoop` in one object, see the plan's GUI phase).

use std::ffi::c_void;

use ::vst3::Class;
use ::vst3::Steinberg::Vst::{IHostApplication, IHostApplicationTrait, String128};
use ::vst3::Steinberg::{kInvalidArgument, kNotImplemented, kResultOk, tresult, TUID};

use super::write_string128;

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
