//! What this build is: the release version, the git commit and the OSC protocol number (spec 046).

/// Release version, from the root `VERSION` file (see `build.rs`).
pub const VERSION: &str = env!("SONARA_VERSION");

/// Short git hash this build was made from, or `unknown` without git.
pub const COMMIT: &str = env!("SONARA_COMMIT");

/// OSC protocol number. Bump it on any incompatible OSC change; the UI warns when its own
/// differs. Keep in step with `BuildInfo.PROTOCOL` in Godot.
pub const PROTOCOL: i32 = 2;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_matches_the_version_file() {
        let file = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../VERSION"))
            .expect("VERSION file");
        assert!(!VERSION.is_empty());
        assert_eq!(VERSION, file.trim());
    }

    #[test]
    fn commit_is_not_empty() {
        assert!(!COMMIT.is_empty());
    }
}
