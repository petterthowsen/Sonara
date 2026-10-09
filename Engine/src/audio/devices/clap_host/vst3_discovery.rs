//! VST3 discovery (spec 028): find `.vst3` bundles and describe the classes in them.
//!
//! Scanning never loads a plugin into the engine process. A bundle with
//! `Contents/Resources/moduleinfo.json` is read from that file; any other bundle is scanned
//! by `plugin_host --scan-vst3 <bundle>` in a throwaway process with a timeout, so a plugin
//! that crashes or hangs while loading only costs its own bundle.

use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use super::super::DeviceCategory;
use super::discovery::PluginDescriptor;
use crate::audio::ipc::PluginFormat;
use crate::plugin_host::vst3::{moduleinfo, ScannedClass};

/// How long a throwaway `--scan-vst3` process may take before the bundle is skipped.
const SCAN_TIMEOUT: Duration = Duration::from_secs(10);

/// Maximum folder depth below a scan root searched for bundles.
const MAX_SCAN_DEPTH: usize = 8;

/// The default VST3 search paths plus the `VST3_PATH` environment variable.
pub fn default_scan_paths() -> Vec<PathBuf> {
    resolve_scan_paths(
        std::env::var("HOME").ok().as_deref(),
        std::env::var("VST3_PATH").ok().as_deref(),
    )
}

/// `~/.vst3`, `/usr/lib/vst3` and `/usr/local/lib/vst3`, then the `:`-separated entries of
/// `vst3_path_env`, with duplicates removed in first-seen order.
pub fn resolve_scan_paths(home: Option<&str>, vst3_path_env: Option<&str>) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(home) = home {
        paths.push(PathBuf::from(home).join(".vst3"));
    }
    paths.push(PathBuf::from("/usr/lib/vst3"));
    paths.push(PathBuf::from("/usr/local/lib/vst3"));
    if let Some(env) = vst3_path_env {
        paths.extend(std::env::split_paths(env).filter(|path| !path.as_os_str().is_empty()));
    }
    let mut seen = HashSet::new();
    paths.retain(|path| seen.insert(path.clone()));
    paths
}

/// `configured` (or the default directories when it is empty) followed by the `VST3_PATH`
/// entries, deduplicated in first-seen order.
pub fn resolve_configured_paths(
    configured: Vec<PathBuf>,
    home: Option<&str>,
    vst3_path_env: Option<&str>,
) -> Vec<PathBuf> {
    if configured.is_empty() {
        return resolve_scan_paths(home, vst3_path_env);
    }
    let mut paths = configured;
    if let Some(env) = vst3_path_env {
        paths.extend(std::env::split_paths(env).filter(|path| !path.as_os_str().is_empty()));
    }
    let mut seen = HashSet::new();
    paths.retain(|path| seen.insert(path.clone()));
    paths
}

/// Find `.vst3` bundle directories under `root`, sorted. Bundles are not searched inside.
/// Symlinked folders are followed, each real folder is visited once.
pub fn find_bundles(root: &Path) -> Vec<PathBuf> {
    let mut bundles = Vec::new();
    let mut visited = HashSet::new();
    let mut pending = vec![(root.to_path_buf(), 0usize)];
    while let Some((dir, depth)) = pending.pop() {
        let canonical = std::fs::canonicalize(&dir).unwrap_or_else(|_| dir.clone());
        if !visited.insert(canonical) {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            if path.extension().is_some_and(|ext| ext == "vst3") {
                bundles.push(path);
            } else if depth < MAX_SCAN_DEPTH {
                pending.push((path, depth + 1));
            }
        }
    }
    bundles.sort();
    bundles
}

/// Category from the VST3 subcategories (`"Instrument|Synth"`): instruments are
/// `Instrument`, `Synth` or `Drum`; everything else is an effect.
pub fn infer_category(subcategories: &str) -> DeviceCategory {
    let is_instrument = subcategories.split('|').any(|part| {
        matches!(
            part.trim().to_ascii_lowercase().as_str(),
            "instrument" | "synth" | "drum"
        )
    });
    if is_instrument {
        DeviceCategory::Instrument
    } else {
        DeviceCategory::Effect
    }
}

/// The subcategories lowercased and split on `|`, as the descriptor's feature tags.
pub fn features_from_subcategories(subcategories: &str) -> Vec<String> {
    subcategories
        .split('|')
        .map(|part| part.trim().to_ascii_lowercase())
        .filter(|part| !part.is_empty())
        .collect()
}

/// The descriptor for one scanned class of `bundle`.
pub fn descriptor_for(class: ScannedClass, bundle: &Path) -> PluginDescriptor {
    let category = infer_category(&class.subcategories);
    PluginDescriptor {
        id: class.id,
        name: class.name,
        vendor: if class.vendor.is_empty() {
            "Unknown".to_string()
        } else {
            class.vendor
        },
        version: if class.version.is_empty() {
            "0.0.0".to_string()
        } else {
            class.version
        },
        category,
        path: bundle.to_path_buf(),
        description: None,
        features: features_from_subcategories(&class.subcategories),
        format: PluginFormat::Vst3,
    }
}

/// Every plugin of every bundle under `root`.
pub fn scan_directory(root: &Path) -> Vec<PluginDescriptor> {
    find_bundles(root)
        .iter()
        .flat_map(|bundle| scan_bundle(bundle))
        .collect()
}

/// The plugins in one bundle. A bundle that can't be scanned is logged and yields none.
pub fn scan_bundle(bundle: &Path) -> Vec<PluginDescriptor> {
    let classes = match moduleinfo::read_bundle(bundle) {
        Some(Ok(classes)) => classes,
        Some(Err(e)) => {
            tracing::warn!("Skipping {:?}: {}", bundle, e);
            return Vec::new();
        }
        None => match scan_out_of_process(bundle) {
            Ok(classes) => classes,
            Err(e) => {
                tracing::warn!("Skipping {:?}: {}", bundle, e);
                return Vec::new();
            }
        },
    };
    classes
        .into_iter()
        .map(|class| {
            tracing::info!("Discovered VST3 plugin: {} ({})", class.name, class.id);
            descriptor_for(class, bundle)
        })
        .collect()
}

/// The `plugin_host` binary next to the running engine executable.
fn plugin_host_path() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| format!("current_exe failed: {}", e))?;
    let dir = exe
        .parent()
        .ok_or_else(|| "engine executable has no directory".to_string())?;
    let path = dir.join("plugin_host");
    if path.exists() {
        Ok(path)
    } else {
        Err(format!(
            "plugin_host binary not found at {}",
            path.display()
        ))
    }
}

/// Parse the JSON lines `plugin_host --scan-vst3` prints, one `ScannedClass` per line.
/// Lines that aren't a class (log noise a plugin printed on stdout) are ignored.
pub fn parse_scan_output(output: &str) -> Vec<ScannedClass> {
    output
        .lines()
        .filter_map(|line| serde_json::from_str::<ScannedClass>(line.trim()).ok())
        .collect()
}

/// Run `plugin_host --scan-vst3 <bundle>` with a timeout.
fn scan_out_of_process(bundle: &Path) -> Result<Vec<ScannedClass>, String> {
    let host = plugin_host_path()?;
    let mut child = Command::new(host)
        .arg("--scan-vst3")
        .arg(bundle)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("could not start plugin_host: {}", e))?;
    let mut stdout = child.stdout.take().ok_or("no stdout")?;
    let reader = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.read_to_string(&mut text);
        text
    });

    let deadline = Instant::now() + SCAN_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = reader.join();
                return Err(format!("scan timed out after {:?}", SCAN_TIMEOUT));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(e) => return Err(format!("waiting for plugin_host failed: {}", e)),
        }
    };
    let output = reader.join().unwrap_or_default();
    if !status.success() {
        return Err(format!("scan process failed ({})", status));
    }
    Ok(parse_scan_output(&output))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn class(subcategories: &str) -> ScannedClass {
        ScannedClass {
            id: "00112233445566778899AABBCCDDEEFF".to_string(),
            name: "Test".to_string(),
            vendor: String::new(),
            version: String::new(),
            subcategories: subcategories.to_string(),
            category: moduleinfo::AUDIO_MODULE_CLASS.to_string(),
        }
    }

    #[test]
    fn configured_paths_replace_defaults_and_keep_env() {
        let configured = vec![PathBuf::from("/a"), PathBuf::from("/b")];
        let paths = resolve_configured_paths(configured.clone(), Some("/home/u"), Some("/b:/c"));
        assert_eq!(
            paths,
            vec![
                PathBuf::from("/a"),
                PathBuf::from("/b"),
                PathBuf::from("/c")
            ]
        );
        assert_eq!(
            resolve_configured_paths(Vec::new(), Some("/home/u"), None),
            resolve_scan_paths(Some("/home/u"), None)
        );
    }

    #[test]
    fn scan_paths_default_then_env_deduplicated() {
        let paths = resolve_scan_paths(Some("/home/u"), Some("/opt/vst3:/usr/lib/vst3:/opt/vst3"));
        assert_eq!(
            paths,
            vec![
                PathBuf::from("/home/u/.vst3"),
                PathBuf::from("/usr/lib/vst3"),
                PathBuf::from("/usr/local/lib/vst3"),
                PathBuf::from("/opt/vst3"),
            ]
        );
        assert_eq!(resolve_scan_paths(None, None).len(), 2);
    }

    #[test]
    fn bundles_are_found_in_subfolders_and_not_entered() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("vendor/Deep.vst3/Contents/x86_64-linux")).unwrap();
        std::fs::create_dir_all(root.join("Top.vst3/Contents/Inner.vst3")).unwrap();
        std::fs::create_dir_all(root.join("other")).unwrap();
        std::fs::write(root.join("File.vst3"), b"").unwrap();
        let found = find_bundles(root);
        assert_eq!(
            found,
            vec![root.join("Top.vst3"), root.join("vendor/Deep.vst3")]
        );
    }

    #[test]
    fn bundle_search_survives_a_symlink_loop() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("vendor/A.vst3")).unwrap();
        std::os::unix::fs::symlink(root, root.join("vendor/loop")).unwrap();
        assert_eq!(find_bundles(root), vec![root.join("vendor/A.vst3")]);
    }

    #[test]
    fn category_comes_from_the_subcategories() {
        assert_eq!(
            infer_category("Instrument|Synth"),
            DeviceCategory::Instrument
        );
        assert_eq!(infer_category("Fx|Instrument"), DeviceCategory::Instrument);
        assert_eq!(infer_category("Drum"), DeviceCategory::Instrument);
        assert_eq!(infer_category("synth"), DeviceCategory::Instrument);
        assert_eq!(infer_category("Fx|Reverb"), DeviceCategory::Effect);
        assert_eq!(infer_category("Analyzer"), DeviceCategory::Effect);
        assert_eq!(infer_category(""), DeviceCategory::Effect);
    }

    #[test]
    fn features_are_lowercased_and_split() {
        assert_eq!(
            features_from_subcategories("Fx|Reverb||Stereo"),
            vec!["fx", "reverb", "stereo"]
        );
        assert!(features_from_subcategories("").is_empty());
    }

    #[test]
    fn descriptor_maps_a_class() {
        let bundle = Path::new("/home/u/.vst3/Test.vst3");
        let descriptor = descriptor_for(class("Instrument"), bundle);
        assert_eq!(descriptor.format, PluginFormat::Vst3);
        assert_eq!(descriptor.id, "00112233445566778899AABBCCDDEEFF");
        assert_eq!(descriptor.path, bundle);
        assert_eq!(descriptor.vendor, "Unknown");
        assert_eq!(descriptor.category, DeviceCategory::Instrument);
        assert_eq!(descriptor.features, vec!["instrument"]);
    }

    #[test]
    fn scan_output_ignores_noise() {
        let line = serde_json::to_string(&class("Fx")).unwrap();
        let output = format!("plugin says hi\n{}\n\n{{not a class}}\n", line);
        let classes = parse_scan_output(&output);
        assert_eq!(classes.len(), 1);
        assert_eq!(classes[0].name, "Test");
    }

    #[test]
    fn a_bundle_with_moduleinfo_is_scanned_without_loading() {
        let dir = tempfile::tempdir().unwrap();
        let bundle = dir.path().join("Info.vst3");
        std::fs::create_dir_all(bundle.join("Contents/Resources")).unwrap();
        std::fs::write(
            bundle.join("Contents/Resources/moduleinfo.json"),
            r#"{"Classes":[{"CID":"00112233445566778899AABBCCDDEEFF","Category":"Audio Module Class","Name":"Info","Vendor":"V","Version":"1.0","Sub Categories":["Instrument","Synth"],},],}"#,
        )
        .unwrap();
        let found = scan_bundle(&bundle);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "Info");
        assert_eq!(found[0].category, DeviceCategory::Instrument);
    }
}
