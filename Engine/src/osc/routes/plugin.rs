//! Plugin routes: `/plugin/*`, `/plugins/*` and `/builtin/*`.

use anyhow::Result;
use crossbeam::channel::Sender;
use rosc::OscType;
use tracing::{info, warn};

use crate::audio::AudioCommand;
use crate::osc::server::OscServer;
use std::path::PathBuf;

use crate::audio::devices::DevicePath;

impl OscServer {
    /// Handle plugin routes: `/plugin/*`, `/plugins/*` and `/builtin/*`. Returns false for an address this area doesn't
    /// know, so the caller can try the next area or report an unknown address.
    pub(super) fn route_plugin(
        &self,
        parts: &[&str],
        args: &[OscType],
        command_tx: &Sender<AudioCommand>,
    ) -> Result<bool> {
        match parts {
            // Plugin management - path-based: /plugin/{command}
            // /plugin/scan [path:String]* — with no args, the engine uses its built-in
            // default search paths (and CLAP_PATH, if set).
            ["plugin", "scan"] => {
                let paths: Vec<PathBuf> = args
                    .iter()
                    .filter_map(|a| match a {
                        OscType::String(s) => Some(PathBuf::from(s)),
                        _ => None,
                    })
                    .collect();
                info!("Scan plugins: {} configured path(s)", paths.len());
                command_tx.send(AudioCommand::ScanPlugins { paths })?;
            }
            // /plugins/hosting <mode:s> [plugin_id:s mode:s]* — how plugins are grouped into
            // host processes, plus per-plugin overrides (Phase 5).
            ["plugins", "hosting"] => match parse_hosting_policy(args) {
                Ok(policy) => {
                    info!(
                        "Plugin hosting: {} ({} override(s))",
                        policy.mode.name(),
                        policy.overrides.len()
                    );
                    command_tx.send(AudioCommand::SetPluginHosting { policy })?;
                }
                Err(e) => warn!("Ignoring /plugins/hosting: {}", e),
            },
            ["builtin", "request"] => {
                info!("Request builtin devices");
                command_tx.send(AudioCommand::AdvertiseBuiltinDevices)?;
            }
            ["plugin", "get_parameters"] => {
                if let (Some(OscType::Int(channel_id)), Some(OscType::Int(device_position))) =
                    (args.get(0), args.get(1))
                {
                    info!(
                        "Get plugin parameters: channel={} device={}",
                        channel_id, device_position
                    );
                    command_tx.send(AudioCommand::GetPluginParameters {
                        channel_id: *channel_id as usize,
                        device_path: DevicePath::root(*device_position as usize),
                    })?;
                }
            }
            _ => return Ok(false),
        }
        Ok(true)
    }
}

/// Parse `/plugins/hosting <mode:s> [plugin_id:s mode:s]*` into a hosting policy. An unknown
/// override mode is skipped with a warning; an unknown global mode rejects the message.
fn parse_hosting_policy(args: &[OscType]) -> Result<crate::audio::ipc::HostingPolicy, String> {
    use crate::audio::ipc::{HostingMode, HostingPolicy};

    let mode = match args.first() {
        Some(OscType::String(name)) => {
            HostingMode::parse(name).ok_or_else(|| format!("unknown hosting mode '{}'", name))?
        }
        _ => return Err("expected the hosting mode as the first argument".to_string()),
    };
    let mut policy = HostingPolicy {
        mode,
        ..Default::default()
    };
    for pair in args[1..].chunks(2) {
        let [OscType::String(plugin_id), OscType::String(name)] = pair else {
            return Err("overrides must be (plugin_id:s, mode:s) pairs".to_string());
        };
        match HostingMode::parse(name) {
            Some(mode) => {
                policy.overrides.insert(plugin_id.clone(), mode);
            }
            None => warn!(
                "Ignoring hosting override for {}: unknown mode '{}'",
                plugin_id, name
            ),
        }
    }
    Ok(policy)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::ipc::HostingMode;
    use crate::osc::parse::test_support::string;

    #[test]
    fn hosting_policy_parses_mode_and_overrides() {
        let policy = parse_hosting_policy(&[
            string("by_plugin"),
            string("crashy.synth"),
            string("individually"),
            string("other.fx"),
            string("bogus"),
        ])
        .unwrap();
        assert_eq!(policy.mode, HostingMode::ByPlugin);
        assert_eq!(
            policy.overrides.get("crashy.synth"),
            Some(&HostingMode::Individually)
        );
        assert!(!policy.overrides.contains_key("other.fx"));
    }

    #[test]
    fn hosting_policy_rejects_bad_messages() {
        assert!(parse_hosting_policy(&[]).is_err());
        assert!(parse_hosting_policy(&[string("within_engine")]).is_err());
        assert!(parse_hosting_policy(&[string("together"), string("dangling.id")]).is_err());
    }
}
