//! Plugin routes: `/plugin/*`, `/plugins/*` and `/builtin/*`.

use anyhow::Result;
use rosc::OscType;
use tracing::{info, warn};

use super::RouteCtx;
use crate::audio::AudioCommand;
use crate::osc::parse::Args;
use std::path::PathBuf;

use crate::audio::devices::DevicePath;

/// Handle plugin routes: `/plugin/*`, `/plugins/*` and `/builtin/*`. Returns false for an address this area doesn't
/// know, so the caller can try the next area or report an unknown address.
pub(super) fn route(parts: &[&str], args: &[OscType], cx: &mut RouteCtx) -> Result<bool> {
    let a = Args::new(cx.addr, args);
    match parts {
        // Plugin management - path-based: /plugin/{command}
        // /plugin/scan [clap_path:String]* ["--vst3" [vst3_path:String]*] — with no paths in a
        // section, the engine uses its built-in defaults (plus CLAP_PATH / VST3_PATH, if set).
        ["plugin", "scan"] => {
            let mut paths: Vec<PathBuf> = Vec::new();
            let mut vst3_paths: Vec<PathBuf> = Vec::new();
            let mut in_vst3 = false;
            for arg in args {
                if let OscType::String(s) = arg {
                    if s == "--vst3" {
                        in_vst3 = true;
                    } else if in_vst3 {
                        vst3_paths.push(PathBuf::from(s));
                    } else {
                        paths.push(PathBuf::from(s));
                    }
                }
            }
            info!(
                "Scan plugins: {} CLAP and {} VST3 configured path(s)",
                paths.len(),
                vst3_paths.len()
            );
            cx.commands
                .send(AudioCommand::ScanPlugins { paths, vst3_paths })?;
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
                cx.commands
                    .send(AudioCommand::SetPluginHosting { policy })?;
            }
            Err(e) => warn!("Ignoring /plugins/hosting: {}", e),
        },
        ["builtin", "request"] => {
            info!("Request builtin devices");
            cx.commands.send(AudioCommand::AdvertiseBuiltinDevices)?;
        }
        ["plugin", "get_parameters"] => {
            let (channel_id, device_position) = (a.int(0)?, a.int(1)?);
            info!(
                "Get plugin parameters: channel={} device={}",
                channel_id, device_position
            );
            cx.commands.send(AudioCommand::GetPluginParameters {
                channel_id: channel_id as usize,
                device_path: DevicePath::root(device_position as usize),
            })?;
        }
        _ => return Ok(false),
    }
    Ok(true)
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
