//! VST3 bundle loading: resolve the binary inside a `.vst3` bundle, `dlopen` it, call
//! `ModuleEntry(handle)`, then `GetPluginFactory`. `ModuleExit` runs in `Drop` before the
//! library is unloaded.
//!
//! A `Vst3Module` must outlive every instance created from it; callers keep an
//! `Arc<Vst3Module>` next to each instance so a missing `ModuleEntry`/`ModuleExit` pairing
//! can't crash at unload (spec 028, risks to watch).
use std::ffi::c_void;
use std::path::{Path, PathBuf};

use ::vst3::com_scrape_types::ComPtr;
use ::vst3::Steinberg::IPluginFactory;

type ModuleEntryFn = unsafe extern "system" fn(handle: *mut c_void) -> bool;
type ModuleExitFn = unsafe extern "system" fn() -> bool;
type GetPluginFactoryFn = unsafe extern "system" fn() -> *mut IPluginFactory;

pub struct Vst3Module {
    bundle_path: PathBuf,
    binary_path: PathBuf,
    module_exit: Option<ModuleExitFn>,
    /// Released in `Drop` before `ModuleExit` runs, while the code is still mapped. Declared
    /// before `_library`, so the field drop order releases it before the handle closes.
    factory: Option<ComPtr<IPluginFactory>>,
    _library: libloading::os::unix::Library,
}

/// Resolve `<bundle>/Contents/<arch>-linux/<Name>.so` for the build target. Bundles only
/// (spec 028): a bare single-file `.so` VST3 is not a supported install shape.
pub fn bundle_binary_path(bundle: &Path) -> Result<PathBuf, String> {
    let arch_dir = match std::env::consts::ARCH {
        "x86_64" => "x86_64-linux",
        "aarch64" => "aarch64-linux",
        other => {
            return Err(format!(
                "Unsupported architecture {} for VST3 bundle {}",
                other,
                bundle.display()
            ))
        }
    };
    let dir = bundle.join("Contents").join(arch_dir);
    let entries =
        std::fs::read_dir(&dir).map_err(|e| format!("reading {}: {}", dir.display(), e))?;
    let mut candidates: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "so"))
        .collect();
    candidates.sort();
    candidates
        .into_iter()
        .next()
        .ok_or_else(|| format!("No .so binary in {}", dir.display()))
}

impl Vst3Module {
    /// Load the bundle and call `ModuleEntry`. `GetPluginFactory` is required; `ModuleEntry`
    /// and `ModuleExit` are optional in the SDK but a module whose entry refuses to load is
    /// an error.
    ///
    /// # Safety
    /// Loading a plugin executes its code in this process.
    pub unsafe fn load(bundle: &Path) -> Result<Self, String> {
        if !bundle.is_dir() {
            return Err(format!(
                "{} is not a VST3 bundle directory (bundles only, spec 028)",
                bundle.display()
            ));
        }
        let binary_path = bundle_binary_path(bundle)?;
        let library = libloading::os::unix::Library::open(
            Some(&binary_path),
            libloading::os::unix::RTLD_LAZY | libloading::os::unix::RTLD_LOCAL,
        )
        .map_err(|e| format!("dlopen({}) failed: {}", binary_path.display(), e))?;

        // The raw handle is what `ModuleEntry` expects; take it and put the Library back.
        let handle = library.into_raw();
        let library = libloading::os::unix::Library::from_raw(handle);

        if let Ok(symbol) = library.get::<ModuleEntryFn>(b"ModuleEntry\0") {
            let module_entry: ModuleEntryFn = *symbol;
            if !module_entry(handle) {
                return Err(format!("ModuleEntry failed for {}", binary_path.display()));
            }
        }
        let module_exit = library
            .get::<ModuleExitFn>(b"ModuleExit\0")
            .ok()
            .map(|symbol| *symbol);

        let get_factory: GetPluginFactoryFn = *library
            .get::<GetPluginFactoryFn>(b"GetPluginFactory\0")
            .map_err(|e| {
                format!(
                    "{} exports no GetPluginFactory: {}",
                    binary_path.display(),
                    e
                )
            })?;
        let factory_raw = get_factory();
        if factory_raw.is_null() {
            return Err(format!(
                "GetPluginFactory returned null for {}",
                binary_path.display()
            ));
        }
        let factory = ComPtr::from_raw(factory_raw).ok_or_else(|| {
            format!(
                "GetPluginFactory returned null for {}",
                binary_path.display()
            )
        })?;

        Ok(Self {
            bundle_path: bundle.to_path_buf(),
            binary_path,
            module_exit,
            factory: Some(factory),
            _library: library,
        })
    }

    pub fn bundle_path(&self) -> &Path {
        &self.bundle_path
    }

    pub fn binary_path(&self) -> &Path {
        &self.binary_path
    }

    pub fn factory(&self) -> &ComPtr<IPluginFactory> {
        self.factory
            .as_ref()
            .expect("factory dropped before module")
    }
}

impl Drop for Vst3Module {
    fn drop(&mut self) {
        // Release the factory first, then call ModuleExit while the module code is still
        // mapped, then the `library` field (declared after `factory`) closes the handle.
        self.factory = None;
        if let Some(module_exit) = self.module_exit {
            unsafe { module_exit() };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_binary_path_resolves_the_so() {
        let dir = tempfile::tempdir().unwrap();
        let arch = format!("Contents/{}-linux", std::env::consts::ARCH);
        let binaries = dir.path().join(&arch);
        std::fs::create_dir_all(&binaries).unwrap();
        std::fs::write(binaries.join("Some Plugin.so"), b"").unwrap();
        let resources = dir.path().join("Contents/Resources");
        std::fs::create_dir_all(&resources).unwrap();
        std::fs::write(resources.join("moduleinfo.json"), b"").unwrap();

        let resolved = bundle_binary_path(dir.path()).unwrap();
        assert_eq!(resolved, binaries.join("Some Plugin.so"));
    }

    #[test]
    fn bundle_binary_path_rejects_missing_binary() {
        let dir = tempfile::tempdir().unwrap();
        assert!(bundle_binary_path(dir.path()).is_err());
    }
}
