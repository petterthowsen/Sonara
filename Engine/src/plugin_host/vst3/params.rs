//! VST3 parameters as the engine sees them (spec 028 decisions).
//!
//! The engine's parameter id is the index from `getParameterInfo`; `Vst3ParamMap` maps it to
//! the plugin's `ParamID`. Values are already normalized, so no range mapping is needed. The
//! map is rebuilt after `restartComponent` reports changed parameter titles, and published to
//! the audio thread as a fresh `Arc`.

use std::collections::HashMap;

use ::vst3::com_scrape_types::ComPtr;
use ::vst3::Steinberg::kResultOk;
use ::vst3::Steinberg::Vst::*;

use super::char16_str;
use crate::audio::ipc::PluginParameterInfo;
use crate::plugin_host::value_text;

/// Engine parameter index to `ParamID` and back.
#[derive(Debug, Default)]
pub struct Vst3ParamMap {
    /// By engine index; None where the controller reported no info.
    ids: Vec<Option<ParamID>>,
    index_by_id: HashMap<ParamID, u32>,
}

impl Vst3ParamMap {
    pub fn from_ids(ids: Vec<Option<ParamID>>) -> Self {
        let index_by_id = ids
            .iter()
            .enumerate()
            .filter_map(|(index, id)| Some((((*id)?), index as u32)))
            .collect();
        Self { ids, index_by_id }
    }

    /// Read every parameter's id from the controller.
    ///
    /// # Safety
    /// Calls controller code: main thread only.
    pub unsafe fn build(controller: &ComPtr<IEditController>) -> Self {
        let count = controller.getParameterCount().max(0);
        let ids = (0..count)
            .map(|index| {
                let mut info: ParameterInfo = std::mem::zeroed();
                (controller.getParameterInfo(index, &mut info) == kResultOk).then_some(info.id)
            })
            .collect();
        Self::from_ids(ids)
    }

    pub fn len(&self) -> u32 {
        self.ids.len() as u32
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }

    /// The plugin's id for an engine index.
    pub fn param_id(&self, index: u32) -> Option<ParamID> {
        self.ids.get(index as usize).copied().flatten()
    }

    /// The engine's index for a plugin parameter id.
    pub fn index_of(&self, id: ParamID) -> Option<u32> {
        self.index_by_id.get(&id).copied()
    }
}

/// `getParamStringByValue` as a Rust string.
///
/// # Safety
/// Calls controller code: main thread only.
pub unsafe fn value_string(
    controller: &ComPtr<IEditController>,
    id: ParamID,
    normalized: f64,
) -> Option<String> {
    let mut text: String128 = [0; 128];
    (controller.getParamStringByValue(id, normalized, &mut text) == kResultOk)
        .then(|| char16_str(&text))
}

/// Flags of a `ParameterInfo`, as `PluginParameterInfo` carries them.
#[derive(Debug, PartialEq, Eq)]
pub struct MappedFlags {
    pub automatable: bool,
    pub stepped: bool,
    pub hidden: bool,
    pub read_only: bool,
    pub bypass: bool,
}

pub fn map_flags(flags: i32, step_count: i32) -> MappedFlags {
    use ParameterInfo_::ParameterFlags_ as f;
    MappedFlags {
        automatable: flags & f::kCanAutomate != 0,
        stepped: step_count > 0,
        hidden: flags & f::kIsHidden != 0,
        read_only: flags & f::kIsReadOnly != 0,
        bypass: flags & f::kIsBypass != 0,
    }
}

/// Stepped parameters of at most this many steps get per-step labels (as for CLAP).
const MAX_STEP_LABELS: i32 = 64;

/// Describe one parameter. Values are normalized, so the range is 0..1; a stepped parameter
/// reports `0..stepCount` like a CLAP stepped parameter, so Godot sees the same shape.
///
/// # Safety
/// Calls controller code: main thread only.
pub unsafe fn describe(
    controller: &ComPtr<IEditController>,
    index: u32,
    info: &ParameterInfo,
) -> PluginParameterInfo {
    let flags = map_flags(info.flags, info.stepCount);
    let (max, default) = if flags.stepped {
        let steps = info.stepCount as f64;
        (steps as f32, (info.defaultNormalizedValue * steps) as f32)
    } else {
        (1.0, info.defaultNormalizedValue as f32)
    };

    let text = |normalized: f64| value_string(controller, info.id, normalized);
    let step_labels = if flags.stepped && info.stepCount < MAX_STEP_LABELS {
        (0..=info.stepCount)
            .map(|step| {
                text(step as f64 / info.stepCount as f64).unwrap_or_else(|| step.to_string())
            })
            .collect()
    } else {
        Vec::new()
    };
    let units = char16_str(&info.units);
    let display = if flags.stepped {
        Vec::new()
    } else {
        let labels: Vec<Option<String>> = (0..value_text::DISPLAY_POINTS)
            .map(|i| text(value_text::sample_value(0.0, 1.0, i)))
            .collect();
        value_text::display_curve(&labels)
            .map(|(_, curve)| curve)
            .unwrap_or_default()
    };

    PluginParameterInfo {
        id: index,
        name: char16_str(&info.title),
        unit: units,
        min: 0.0,
        max,
        default,
        is_automation_safe: flags.automatable,
        is_stepped: flags.stepped,
        is_hidden: flags.hidden,
        is_read_only: flags.read_only,
        is_bypass: flags.bypass,
        // VST3 has no non-destructive modulation (spec 028, out of scope for v1).
        is_modulatable: false,
        module: String::new(),
        step_labels,
        display,
    }
}

/// Describe every parameter the controller reports.
///
/// # Safety
/// Calls controller code: main thread only.
pub unsafe fn describe_all(controller: &ComPtr<IEditController>) -> Vec<PluginParameterInfo> {
    let count = controller.getParameterCount().max(0);
    (0..count)
        .filter_map(|index| {
            let mut info: ParameterInfo = std::mem::zeroed();
            if controller.getParameterInfo(index, &mut info) != kResultOk {
                return None;
            }
            Some(describe(controller, index as u32, &info))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ParameterInfo_::ParameterFlags_ as f;

    #[test]
    fn the_map_goes_both_ways_and_skips_holes() {
        let map = Vst3ParamMap::from_ids(vec![Some(100), None, Some(7)]);
        assert_eq!(map.len(), 3);
        assert_eq!(map.param_id(0), Some(100));
        assert_eq!(map.param_id(1), None);
        assert_eq!(map.param_id(2), Some(7));
        assert_eq!(map.param_id(3), None);
        assert_eq!(map.index_of(7), Some(2));
        assert_eq!(map.index_of(100), Some(0));
        assert_eq!(map.index_of(8), None);
        assert!(Vst3ParamMap::default().is_empty());
    }

    #[test]
    fn flags_map_like_the_clap_ones() {
        let mapped = map_flags(f::kCanAutomate | f::kIsHidden, 0);
        assert_eq!(
            mapped,
            MappedFlags {
                automatable: true,
                stepped: false,
                hidden: true,
                read_only: false,
                bypass: false,
            }
        );
        let mapped = map_flags(f::kIsReadOnly | f::kIsBypass, 3);
        assert!(mapped.stepped && mapped.read_only && mapped.bypass && !mapped.automatable);
    }
}
