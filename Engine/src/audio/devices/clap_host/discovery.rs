//! Plugin discovery and scanning for CLAP plugins

use std::path::{Path, PathBuf};
use std::collections::HashMap;
use clack_host::prelude::*;
use super::super::DeviceCategory;
use super::PluginError;

/// Metadata for a discovered plugin
#[derive(Debug, Clone)]
pub struct PluginDescriptor {
    pub id: String,              // e.g. "com.u-he.diva"
    pub name: String,
    pub vendor: String,
    pub version: String,
    pub category: DeviceCategory,
    pub path: PathBuf,           // Path to .clap bundle
    pub description: Option<String>,
    pub url: Option<String>,
}

/// Plugin scanner that finds .clap files in standard locations
pub struct PluginScanner {
    scan_paths: Vec<PathBuf>,
    discovered_plugins: HashMap<String, PluginDescriptor>,
}

impl PluginScanner {
    /// Create a new plugin scanner with default scan paths
    pub fn new() -> Self {
        Self {
            scan_paths: Self::default_scan_paths(),
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

    /// Scan a single directory for .clap files
    fn scan_directory(path: &Path) -> Result<Vec<PluginDescriptor>, PluginError> {
        let mut plugins = Vec::new();

        let entries = std::fs::read_dir(path)
            .map_err(|e| PluginError::Other(format!("Failed to read directory: {}", e)))?;

        for entry in entries.flatten() {
            let path = entry.path();
            
            // Check for .clap extension or .so files that might be CLAP plugins
            if let Some(ext) = path.extension() {
                if ext == "clap" || ext == "so" {
                    match Self::load_plugin_metadata(&path) {
                        Ok(mut discovered) => {
                            plugins.append(&mut discovered);
                        }
                        Err(e) => {
                            tracing::debug!("Skipping {:?}: {}", path, e);
                        }
                    }
                }
            }
        }

        Ok(plugins)
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
        let factory = bundle.get_plugin_factory()
            .ok_or_else(|| PluginError::UnsupportedPlugin("No plugin factory found".to_string()))?;

        // Iterate through all plugins in the bundle
        let mut plugins = Vec::new();
        
        for descriptor in factory.plugin_descriptors() {
            match Self::extract_descriptor_info(&descriptor, path) {
                Ok(plugin_desc) => {
                    tracing::info!("Discovered plugin: {} ({})", plugin_desc.name, plugin_desc.id);
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
        let id = descriptor.id()
            .ok_or_else(|| PluginError::InvalidPluginId("Missing plugin ID".to_string()))?
            .to_str()
            .map_err(|e| PluginError::InvalidPluginId(format!("Invalid plugin ID: {:?}", e)))?
            .to_string();

        let name = descriptor.name()
            .ok_or_else(|| PluginError::Other("Missing plugin name".to_string()))?
            .to_str()
            .map_err(|e| PluginError::Other(format!("Invalid plugin name: {:?}", e)))?
            .to_string();

        let vendor = descriptor.vendor()
            .and_then(|v| v.to_str().ok())
            .unwrap_or("Unknown")
            .to_string();

        let version = descriptor.version()
            .and_then(|v| v.to_str().ok())
            .unwrap_or("0.0.0")
            .to_string();

        let description = descriptor.description()
            .and_then(|d| d.to_str().ok())
            .map(|s| s.to_string());

        let url = descriptor.url()
            .and_then(|u| u.to_str().ok())
            .map(|s| s.to_string());

        // Infer category from plugin features
        let category = Self::infer_category(&descriptor);

        Ok(PluginDescriptor {
            id,
            name,
            vendor,
            version,
            category,
            path: bundle_path.to_path_buf(),
            description,
            url,
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
                    "audio-effect" | "effect" | "reverb" | "delay" | "compressor" | 
                    "equalizer" | "filter" | "distortion" | "modulation" => {
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

    /// Get a plugin descriptor by ID
    pub fn get_plugin(&self, id: &str) -> Option<&PluginDescriptor> {
        self.discovered_plugins.get(id)
    }

    /// Get all discovered plugins
    pub fn all_plugins(&self) -> impl Iterator<Item = &PluginDescriptor> {
        self.discovered_plugins.values()
    }

    /// Get number of discovered plugins
    pub fn plugin_count(&self) -> usize {
        self.discovered_plugins.len()
    }

    /// Clear all discovered plugins
    pub fn clear(&mut self) {
        self.discovered_plugins.clear();
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
}

