//! Plugin discovery and scanning for CLAP plugins

use super::super::DeviceCategory;
use super::PluginError;
use clack_host::prelude::*;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Metadata for a discovered plugin
#[derive(Debug, Clone)]
pub struct PluginDescriptor {
    pub id: String, // e.g. "com.u-he.diva"
    pub name: String,
    pub vendor: String,
    pub version: String,
    pub category: DeviceCategory,
    pub path: PathBuf, // Path to .clap bundle
    pub description: Option<String>,
    pub url: Option<String>,
    /// CLAP feature tags, e.g. ["audio-effect", "reverb"]
    pub features: Vec<String>,
}

/// Plugin scanner that finds .clap files in standard locations
pub struct PluginScanner {
    scan_paths: Vec<PathBuf>,
    discovered_plugins: HashMap<String, PluginDescriptor>,
}

impl PluginScanner {
    /// Create a new plugin scanner with default scan paths, plus CLAP_PATH if set
    pub fn new() -> Self {
        Self {
            scan_paths: Self::resolve_scan_paths(
                Vec::new(),
                std::env::var("CLAP_PATH").ok().as_deref(),
            ),
            discovered_plugins: HashMap::new(),
        }
    }

    /// Create a scanner with custom scan paths
    pub fn with_paths(paths: Vec<PathBuf>) -> Self {
        Self {
            scan_paths: paths,
            discovered_plugins: HashMap::new(),
        }
    }

    /// Replace the configured scan paths. An empty `paths` falls back to the built-in
    /// defaults. CLAP_PATH entries, if set, are always appended.
    pub fn set_paths(&mut self, paths: Vec<PathBuf>) {
        self.scan_paths =
            Self::resolve_scan_paths(paths, std::env::var("CLAP_PATH").ok().as_deref());
    }

    /// Build the effective scan path list: `configured` (or the built-in defaults, if
    /// `configured` is empty), plus any directories from `clap_path_env` (a `CLAP_PATH`-style
    /// `:`-separated list), with duplicates removed while keeping first-seen order.
    fn resolve_scan_paths(configured: Vec<PathBuf>, clap_path_env: Option<&str>) -> Vec<PathBuf> {
        let mut paths = if configured.is_empty() {
            Self::default_scan_paths()
        } else {
            configured
        };

        if let Some(env_value) = clap_path_env {
            for path in std::env::split_paths(env_value) {
                paths.push(path);
            }
        }

        let mut seen = std::collections::HashSet::new();
        paths.retain(|p| seen.insert(p.clone()));
        paths
    }

    /// Get standard CLAP plugin paths (Linux-specific)
    fn default_scan_paths() -> Vec<PathBuf> {
        let mut paths = vec![
            PathBuf::from("/usr/lib/clap"),
            PathBuf::from("/usr/local/lib/clap"),
        ];

        // Add user's home directory
        if let Ok(home) = std::env::var("HOME") {
            paths.push(PathBuf::from(format!("{}/.clap", home)));
        }

        paths
    }

    /// Scan all configured paths and discover plugins
    pub fn scan(&mut self) -> Result<usize, PluginError> {
        tracing::info!("Scanning for CLAP plugins in {:?}", self.scan_paths);

        self.discovered_plugins.clear();
        let mut total_plugins = 0;

        for path in &self.scan_paths {
            if !path.exists() {
                tracing::debug!("Scan path does not exist: {:?}", path);
                continue;
            }

            match Self::scan_directory(path) {
                Ok(plugins) => {
                    tracing::info!("Found {} plugin(s) in {:?}", plugins.len(), path);
                    total_plugins += plugins.len();
                    for plugin in plugins {
                        self.discovered_plugins.insert(plugin.id.clone(), plugin);
                    }
                }
                Err(e) => {
                    tracing::warn!("Error scanning directory {:?}: {}", path, e);
                }
            }
        }

        tracing::info!("Total plugins discovered: {}", total_plugins);
        Ok(total_plugins)
    }

    /// Scan a directory and its subfolders for plugin files
    fn scan_directory(path: &Path) -> Result<Vec<PluginDescriptor>, PluginError> {
        let mut plugins = Vec::new();

        for file in Self::find_plugin_files(path)? {
            match Self::load_plugin_metadata(&file) {
                Ok(mut discovered) => {
                    plugins.append(&mut discovered);
                }
                Err(e) => {
                    tracing::debug!("Skipping {:?}: {}", file, e);
                }
            }
        }

        Ok(plugins)
    }

    /// Maximum folder depth below a scan root that `find_plugin_files` descends into.
    const MAX_SCAN_DEPTH: usize = 16;

    /// Find plugin files under `root`, sorted. `.clap` files are found in any subfolder, as
    /// the CLAP spec asks. `.so` files are only taken from the top level of `root`: deeper
    /// down they are usually a plugin's own support libraries, which must not be loaded.
    /// Symlinked folders are followed, each real folder is visited once.
    fn find_plugin_files(root: &Path) -> Result<Vec<PathBuf>, PluginError> {
        let mut files = Vec::new();
        let mut visited = std::collections::HashSet::new();
        let mut pending = vec![(root.to_path_buf(), 0usize)];

        while let Some((dir, depth)) = pending.pop() {
            let canonical = std::fs::canonicalize(&dir).unwrap_or_else(|_| dir.clone());
            if !visited.insert(canonical) {
                continue;
            }

            let entries = match std::fs::read_dir(&dir) {
                Ok(entries) => entries,
                Err(e) if depth == 0 => {
                    return Err(PluginError::Other(format!(
                        "Failed to read directory: {}",
                        e
                    )));
                }
                Err(e) => {
                    tracing::debug!("Skipping unreadable folder {:?}: {}", dir, e);
                    continue;
                }
            };

            for entry in entries.flatten() {
                let path = entry.path();
                // `is_dir`/`is_file` follow symlinks
                if path.is_dir() {
                    if depth < Self::MAX_SCAN_DEPTH {
                        pending.push((path, depth + 1));
                    }
                } else if path.is_file() {
                    let is_plugin = match path.extension() {
                        Some(ext) if ext == "clap" => true,
                        Some(ext) if ext == "so" => depth == 0,
                        _ => false,
                    };
                    if is_plugin {
                        files.push(path);
                    }
                }
            }
        }

        files.sort();
        Ok(files)
    }

    /// Load metadata from a plugin bundle without fully initializing it
    fn load_plugin_metadata(path: &Path) -> Result<Vec<PluginDescriptor>, PluginError> {
        tracing::debug!("Attempting to load plugin metadata from {:?}", path);

        // Load the bundle (unsafe because we're loading arbitrary native code)
        let bundle = unsafe {
            PluginBundle::load(path)
                .map_err(|e| PluginError::LoadError(format!("Failed to load bundle: {:?}", e)))?
        };

        // Get the plugin factory
        let factory = bundle
            .get_plugin_factory()
            .ok_or_else(|| PluginError::UnsupportedPlugin("No plugin factory found".to_string()))?;

        // Iterate through all plugins in the bundle
        let mut plugins = Vec::new();

        for descriptor in factory.plugin_descriptors() {
            match Self::extract_descriptor_info(&descriptor, path) {
                Ok(plugin_desc) => {
                    tracing::info!(
                        "Discovered plugin: {} ({})",
                        plugin_desc.name,
                        plugin_desc.id
                    );
                    plugins.push(plugin_desc);
                }
                Err(e) => {
                    tracing::warn!("Failed to extract plugin info: {}", e);
                }
            }
        }

        Ok(plugins)
    }

    /// Extract information from a CLAP plugin descriptor
    fn extract_descriptor_info(
        descriptor: &clack_host::factory::PluginDescriptor,
        bundle_path: &Path,
    ) -> Result<PluginDescriptor, PluginError> {
        let id = descriptor
            .id()
            .ok_or_else(|| PluginError::InvalidPluginId("Missing plugin ID".to_string()))?
            .to_str()
            .map_err(|e| PluginError::InvalidPluginId(format!("Invalid plugin ID: {:?}", e)))?
            .to_string();

        let name = descriptor
            .name()
            .ok_or_else(|| PluginError::Other("Missing plugin name".to_string()))?
            .to_str()
            .map_err(|e| PluginError::Other(format!("Invalid plugin name: {:?}", e)))?
            .to_string();

        let vendor = descriptor
            .vendor()
            .and_then(|v| v.to_str().ok())
            .unwrap_or("Unknown")
            .to_string();

        let version = descriptor
            .version()
            .and_then(|v| v.to_str().ok())
            .unwrap_or("0.0.0")
            .to_string();

        let description = descriptor
            .description()
            .and_then(|d| d.to_str().ok())
            .map(|s| s.to_string());

        let url = descriptor
            .url()
            .and_then(|u| u.to_str().ok())
            .map(|s| s.to_string());

        // Infer category from plugin features
        let category = Self::infer_category(&descriptor);

        let features = descriptor
            .features()
            .filter_map(|feature| feature.to_str().ok().map(|s| s.to_string()))
            .collect();

        Ok(PluginDescriptor {
            id,
            name,
            vendor,
            version,
            category,
            path: bundle_path.to_path_buf(),
            description,
            url,
            features,
        })
    }

    /// Infer device category from CLAP plugin features
    fn infer_category(descriptor: &clack_host::factory::PluginDescriptor) -> DeviceCategory {
        // Check plugin features array
        for feature in descriptor.features() {
            if let Ok(feature_str) = feature.to_str() {
                match feature_str {
                    "instrument" | "synthesizer" | "sampler" | "drum-machine" => {
                        return DeviceCategory::Instrument;
                    }
                    "audio-effect" | "effect" | "reverb" | "delay" | "compressor" | "equalizer"
                    | "filter" | "distortion" | "modulation" => {
                        return DeviceCategory::Effect;
                    }
                    "analyzer" | "utility" => {
                        return DeviceCategory::Utility;
                    }
                    _ => {}
                }
            }
        }

        // Default to effect if no features match
        DeviceCategory::Effect
    }

    /// Get all discovered plugins
    /// Vendor of plugin `id` in bundle `path`. Reads that one bundle when the plugin wasn't
    /// scanned in this session (Godot caches its plugin list, so a project can load before any
    /// scan), and remembers what it found. None when the bundle can't be read.
    pub fn vendor_of(&mut self, id: &str, path: &Path) -> Option<String> {
        if let Some(plugin) = self.discovered_plugins.get(id) {
            return Some(plugin.vendor.clone());
        }
        match Self::load_plugin_metadata(path) {
            Ok(descriptors) => {
                for descriptor in descriptors {
                    self.discovered_plugins
                        .insert(descriptor.id.clone(), descriptor);
                }
            }
            Err(e) => tracing::warn!("Could not read plugin metadata from {:?}: {}", path, e),
        }
        self.discovered_plugins
            .get(id)
            .map(|plugin| plugin.vendor.clone())
    }

    pub fn all_plugins(&self) -> impl Iterator<Item = &PluginDescriptor> {
        self.discovered_plugins.values()
    }
}

impl Default for PluginScanner {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scanner_creation() {
        let scanner = PluginScanner::new();
        assert!(!scanner.scan_paths.is_empty());
    }

    #[test]
    fn test_custom_paths() {
        let custom_paths = vec![PathBuf::from("/custom/path")];
        let scanner = PluginScanner::with_paths(custom_paths.clone());
        assert_eq!(scanner.scan_paths, custom_paths);
    }

    #[test]
    fn test_resolve_scan_paths_empty_configured_uses_defaults() {
        let resolved = PluginScanner::resolve_scan_paths(Vec::new(), None);
        assert_eq!(resolved, PluginScanner::default_scan_paths());
    }

    #[test]
    fn test_resolve_scan_paths_configured_replaces_defaults() {
        let configured = vec![PathBuf::from("/custom/path")];
        let resolved = PluginScanner::resolve_scan_paths(configured.clone(), None);
        assert_eq!(resolved, configured);
    }

    #[test]
    fn test_resolve_scan_paths_appends_clap_path_entries() {
        let configured = vec![PathBuf::from("/custom/path")];
        let resolved =
            PluginScanner::resolve_scan_paths(configured, Some("/from/env/a:/from/env/b"));
        assert_eq!(
            resolved,
            vec![
                PathBuf::from("/custom/path"),
                PathBuf::from("/from/env/a"),
                PathBuf::from("/from/env/b"),
            ]
        );
    }

    #[test]
    fn test_find_plugin_files_searches_subfolders() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("vendor/deep")).unwrap();
        std::fs::write(root.join("Top.clap"), b"").unwrap();
        std::fs::write(root.join("vendor/Foo.clap"), b"").unwrap();
        std::fs::write(root.join("vendor/deep/Bar.clap"), b"").unwrap();
        std::fs::write(root.join("vendor/readme.txt"), b"").unwrap();

        let found = PluginScanner::find_plugin_files(root).unwrap();
        assert_eq!(
            found,
            vec![
                root.join("Top.clap"),
                root.join("vendor/Foo.clap"),
                root.join("vendor/deep/Bar.clap"),
            ]
        );
    }

    #[test]
    fn test_find_plugin_files_takes_so_only_at_top_level() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("vendor/lib")).unwrap();
        std::fs::write(root.join("Legacy.so"), b"").unwrap();
        std::fs::write(root.join("vendor/lib/libsupport.so"), b"").unwrap();

        let found = PluginScanner::find_plugin_files(root).unwrap();
        assert_eq!(found, vec![root.join("Legacy.so")]);
    }

    #[test]
    fn test_find_plugin_files_survives_symlink_loop() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path();
        std::fs::create_dir_all(root.join("vendor")).unwrap();
        std::fs::write(root.join("vendor/Foo.clap"), b"").unwrap();
        std::os::unix::fs::symlink(root, root.join("vendor/loop")).unwrap();

        let found = PluginScanner::find_plugin_files(root).unwrap();
        assert_eq!(found, vec![root.join("vendor/Foo.clap")]);
    }

    #[test]
    fn test_find_plugin_files_missing_root_is_error() {
        let dir = tempfile::tempdir().unwrap();
        assert!(PluginScanner::find_plugin_files(&dir.path().join("nope")).is_err());
    }

    #[test]
    fn test_resolve_scan_paths_deduplicates_keeping_order() {
        let configured = vec![PathBuf::from("/a"), PathBuf::from("/b")];
        let resolved = PluginScanner::resolve_scan_paths(configured, Some("/b:/a:/c"));
        assert_eq!(
            resolved,
            vec![
                PathBuf::from("/a"),
                PathBuf::from("/b"),
                PathBuf::from("/c")
            ]
        );
    }
}
