//! Plugin hosting modes: how plugin instances are grouped into `plugin_host` processes (Phase 5).
//!
//! Every instance gets a host key; instances with the same key share one host process. Grouping
//! trades crash isolation for fewer processes and context switches. A per-plugin override wins
//! over the global mode, so a plugin known to crash can be kept on its own.

use std::collections::HashMap;

use super::protocol::InstanceId;

/// How plugin instances are grouped into host processes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum HostingMode {
    /// Every plugin in one host process.
    Together,
    /// One host process per plugin vendor.
    ByVendor,
    /// One host process per plugin (every instance of it).
    ByPlugin,
    /// One host process per instance: the most isolation.
    #[default]
    Individually,
}

impl HostingMode {
    /// Parse the OSC name (`together`, `by_vendor`, `by_plugin`, `individually`).
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "together" => Some(Self::Together),
            "by_vendor" => Some(Self::ByVendor),
            "by_plugin" => Some(Self::ByPlugin),
            "individually" => Some(Self::Individually),
            _ => None,
        }
    }

    /// The OSC name, as `parse` accepts it.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Together => "together",
            Self::ByVendor => "by_vendor",
            Self::ByPlugin => "by_plugin",
            Self::Individually => "individually",
        }
    }
}

/// Which host process an instance belongs in, and the mode that chose it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostAssignment {
    pub mode: HostingMode,
    pub key: String,
}

/// The global hosting mode plus per-plugin overrides, by plugin id.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostingPolicy {
    pub mode: HostingMode,
    pub overrides: HashMap<String, HostingMode>,
}

impl HostingPolicy {
    /// The mode that applies to `plugin_id`: its override, else the global mode.
    pub fn mode_for(&self, plugin_id: &str) -> HostingMode {
        self.overrides.get(plugin_id).copied().unwrap_or(self.mode)
    }

    /// The host an instance of `plugin_id` from `vendor` belongs in.
    pub fn assign(&self, plugin_id: &str, vendor: &str, instance_id: InstanceId) -> HostAssignment {
        let mode = self.mode_for(plugin_id);
        let key = match mode {
            HostingMode::Together => "all".to_string(),
            HostingMode::ByVendor => format!("vendor:{}", vendor),
            HostingMode::ByPlugin => format!("plugin:{}", plugin_id),
            HostingMode::Individually => individual_host_key(instance_id),
        };
        HostAssignment { mode, key }
    }
}

/// Host key that gives an instance a host process of its own.
pub fn individual_host_key(instance_id: InstanceId) -> String {
    format!("instance-{}", instance_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_round_trip_through_their_names() {
        for mode in [
            HostingMode::Together,
            HostingMode::ByVendor,
            HostingMode::ByPlugin,
            HostingMode::Individually,
        ] {
            assert_eq!(HostingMode::parse(mode.name()), Some(mode));
        }
        assert_eq!(HostingMode::parse("within_engine"), None);
    }

    #[test]
    fn keys_group_instances_by_mode() {
        let mut policy = HostingPolicy::default();
        assert_eq!(policy.assign("a.reverb", "Acme", 3).key, "instance-3");

        policy.mode = HostingMode::ByPlugin;
        assert_eq!(
            policy.assign("a.reverb", "Acme", 3).key,
            policy.assign("a.reverb", "Acme", 4).key,
            "two instances of one plugin share a host"
        );
        assert_ne!(
            policy.assign("a.reverb", "Acme", 3).key,
            policy.assign("a.delay", "Acme", 5).key
        );

        policy.mode = HostingMode::ByVendor;
        assert_eq!(
            policy.assign("a.reverb", "Acme", 3).key,
            policy.assign("a.delay", "Acme", 5).key
        );
        assert_ne!(
            policy.assign("a.reverb", "Acme", 3).key,
            policy.assign("b.eq", "Other", 6).key
        );

        policy.mode = HostingMode::Together;
        assert_eq!(policy.assign("b.eq", "Other", 6).key, "all");
    }

    #[test]
    fn an_override_wins_over_the_global_mode() {
        let mut policy = HostingPolicy {
            mode: HostingMode::Together,
            overrides: HashMap::new(),
        };
        policy
            .overrides
            .insert("crashy.synth".to_string(), HostingMode::Individually);

        let crashy = policy.assign("crashy.synth", "Acme", 9);
        assert_eq!(crashy.mode, HostingMode::Individually);
        assert_eq!(crashy.key, "instance-9");
        assert_eq!(policy.assign("a.reverb", "Acme", 3).key, "all");
    }
}
