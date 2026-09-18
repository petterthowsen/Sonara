# Engine Build Guidance

## Overview

- Default to release builds (`cargo build --release`, `cargo run --release`) when building or running the engine; debug builds are too slow for real-time audio and cause dropouts.
- `cargo test` can use the default debug profile unless a test is timing- or performance-sensitive.

## Rules

- Build and run the engine with `--release` (or `Engine/run_release.sh` / `./run_engine.sh`).
- Use a debug build (`Engine/run.sh`, `cargo build`) only when you specifically need debug assertions or a debugger, and expect audio glitches.
- The crate produces two binaries: `engine` (default) and `plugin_host`. `ProcessManager` spawns `plugin_host` from the engine executable's own directory (e.g. `target/release/`), so both binaries must be built with the same profile. `run_release.sh`/`run.sh` build with `--bins` and exec the binary directly; a bare `cargo run` only builds `engine`, and CLAP loads then fail with "plugin_host binary not found".
