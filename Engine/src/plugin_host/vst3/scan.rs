//! `plugin_host --scan-vst3 <bundle>`: print the classes a VST3 bundle contains, as one
//! JSON object per line. The engine's scanner invokes this in a throwaway process when a
//! bundle has no `moduleinfo.json`, so a crashing plugin can never take the engine down
//! during a scan (spec 028 decisions).
//!
//! With a `moduleinfo.json` present the file is read instead of loading the binary.

use ::vst3::com_scrape_types::ComPtr;
use ::vst3::Steinberg::{
    kResultOk, IPluginFactory, IPluginFactory2, IPluginFactory2Trait, IPluginFactory3,
    IPluginFactory3Trait, IPluginFactoryTrait, PClassInfo, PClassInfo2, PClassInfoW,
};
use serde::Serialize;
use std::path::Path;

use super::module::Vst3Module;
use super::moduleinfo::{self, AUDIO_MODULE_CLASS};
use super::{char16_str, char8_str, tuid_to_hex};

/// One class as the scanner reports it: id (32 uppercase hex characters), name, vendor,
/// version, subcategories (pipe-joined) and category.
#[derive(Debug, Clone, Serialize)]
pub struct ScannedClass {
    pub id: String,
    pub name: String,
    pub vendor: String,
    pub version: String,
    pub subcategories: String,
    pub category: String,
}

/// Read the class list out of a loaded module's plugin factory. Prefers `getClassInfoUnicode`
/// (`IPluginFactory3`), then `getClassInfo2`, then the bare `getClassInfo`.
pub fn classes_from_factory(factory: &ComPtr<IPluginFactory>) -> Vec<ScannedClass> {
    let count = unsafe { factory.countClasses() };
    let factory2 = factory.cast::<IPluginFactory2>();
    let factory3 = factory.cast::<IPluginFactory3>();
    let mut classes = Vec::new();
    for index in 0..count {
        let mut class = None;
        if let Some(factory3) = &factory3 {
            let mut info: PClassInfoW = unsafe { std::mem::zeroed() };
            if unsafe { factory3.getClassInfoUnicode(index, &mut info) } == kResultOk {
                class = Some(ScannedClass {
                    id: tuid_to_hex(&info.cid),
                    name: char16_str(&info.name),
                    vendor: char16_str(&info.vendor),
                    version: char16_str(&info.version),
                    subcategories: char8_str(&info.subCategories),
                    category: char8_str(&info.category),
                });
            }
        }
        if class.is_none() {
            if let Some(factory2) = &factory2 {
                let mut info: PClassInfo2 = unsafe { std::mem::zeroed() };
                if unsafe { factory2.getClassInfo2(index, &mut info) } == kResultOk {
                    class = Some(ScannedClass {
                        id: tuid_to_hex(&info.cid),
                        name: char8_str(&info.name),
                        vendor: char8_str(&info.vendor),
                        version: char8_str(&info.version),
                        subcategories: char8_str(&info.subCategories),
                        category: char8_str(&info.category),
                    });
                }
            }
        }
        if class.is_none() {
            let mut info: PClassInfo = unsafe { std::mem::zeroed() };
            if unsafe { factory.getClassInfo(index, &mut info) } == kResultOk {
                class = Some(ScannedClass {
                    id: tuid_to_hex(&info.cid),
                    name: char8_str(&info.name),
                    vendor: String::new(),
                    version: String::new(),
                    subcategories: String::new(),
                    category: char8_str(&info.category),
                });
            }
        }
        classes.extend(class);
    }
    classes
}

/// The audio-module (processor) classes of a loaded module; controller classes are skipped.
pub fn audio_module_classes(classes: &[ScannedClass]) -> Vec<ScannedClass> {
    classes
        .iter()
        .filter(|class| class.category == AUDIO_MODULE_CLASS)
        .cloned()
        .collect()
}

/// Scan one bundle: `moduleinfo.json` when it exists and parses, otherwise load the binary
/// in this process and enumerate the factory.
pub fn scan_bundle(bundle: &Path) -> Result<Vec<ScannedClass>, String> {
    if let Some(result) = moduleinfo::read_bundle(bundle) {
        return result;
    }
    // SAFETY: this binary is the scan target; a throwaway process is the point.
    let module = unsafe { Vst3Module::load(bundle)? };
    Ok(audio_module_classes(&classes_from_factory(
        module.factory(),
    )))
}

/// CLI entry point for `plugin_host --scan-vst3 <bundle>`: one JSON object per line, exit
/// code 0 when at least the bundle could be scanned.
pub fn run_scan(bundle: &Path) -> i32 {
    match scan_bundle(bundle) {
        Ok(classes) => {
            for class in &classes {
                match serde_json::to_string(class) {
                    Ok(line) => println!("{}", line),
                    Err(e) => {
                        eprintln!("serializing class {} failed: {}", class.id, e);
                        return 1;
                    }
                }
            }
            0
        }
        Err(e) => {
            eprintln!("vst3 scan failed: {}", e);
            1
        }
    }
}
