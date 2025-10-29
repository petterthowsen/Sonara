# Repository Guidelines

## Project Structure & Module Organization
The repo centers on `Engine/`, a Rust crate that holds all real-time audio code. Core DSP lives under `Engine/src/audio/` (submodules for devices, IO, and IPC), while OSC networking is in `Engine/src/osc/`. Binary entry points reside in `Engine/src/bin/` with `main.rs` orchestrating startup. Godot UI work-in-progress assets live under `Godot/`; treat them as experimental until the Rust side exposes the needed hooks. Shared scripts, docs, and quickstart helpers sit at the repository root.

## Build, Test, and Development Commands
- `./run_engine.sh` — builds the engine in release mode and launches it with default audio backends.
- `cargo build` / `cargo build --release` (run inside `Engine/`) — standard debug or optimized builds.
- `cargo test` — executes unit and integration tests for the engine crate.
- `./test_osc.sh`, `./test_plugin_osc.sh`, `./test_sfizz.sh` — smoke tests that fire OSC scenarios; expect audible cues.

## Coding Style & Naming Conventions
Follow idiomatic Rust: four-space indentation, `snake_case` for modules/functions, `UpperCamelCase` for types, and `SCREAMING_SNAKE_CASE` for constants. Run `cargo fmt` before every commit; keep diffs clean. Favor explicit module paths (`crate::audio::devices`) to make cross-thread interactions obvious. When you touch public APIs, document them with `///` comments describing real-time safety expectations.

## Testing Guidelines
All Rust code must include targeted unit tests near the implementation (`mod tests` at the bottom of the file). Use `cargo test -- --nocapture` when debugging timing-sensitive paths. Trigger the OSC scripts whenever changing transport or device code—capture results in logs under `Engine/logs/`. If a change impacts external tools, note expected OSC commands in the PR description.

## Commit & Pull Request Guidelines
Commits should stay focused with <80-char, present-tense summaries mirroring existing history (`improve timeline drag behavior`). Reference issues in the body (`Refs #42`) and describe any audible or UX impact. Pull requests need: problem statement, implementation notes (highlight threading or allocation trade-offs), test evidence (command output or log snippets), and, when UI changes land, short screen recordings or GIFs. Tag reviewers responsible for audio or Godot subsystems to keep cross-team context flowing.
