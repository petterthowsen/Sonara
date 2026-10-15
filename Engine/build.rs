//! Bakes the release version (the root `VERSION` file) and the git commit into the binaries as
//! `SONARA_VERSION` and `SONARA_COMMIT` (spec 046).

use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=../VERSION");
    println!("cargo:rerun-if-changed=../.git/HEAD");
    println!("cargo:rerun-if-env-changed=SONARA_COMMIT");

    let version = std::fs::read_to_string("../VERSION")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let version = if version.is_empty() {
        std::env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.0.0".into())
    } else {
        version
    };
    println!("cargo:rustc-env=SONARA_VERSION={version}");

    // CI or a source tarball without .git can pass the commit in the environment.
    let commit = std::env::var("SONARA_COMMIT")
        .ok()
        .filter(|c| !c.trim().is_empty())
        .or_else(|| {
            Command::new("git")
                .args(["rev-parse", "--short", "HEAD"])
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        })
        .filter(|c| !c.is_empty())
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=SONARA_COMMIT={commit}");
}
