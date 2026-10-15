# Beta Release — Tasks

Implements [design.md](./design.md). Tracking issue: #146.

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified

Engine commands run from `Engine/`. Godot tests: `Godot/tests/run_all.sh <words>`.
Live checks follow the live-check memory: the user's engine may hold port 7000, and the PipeWire
forced quantum is system-wide, so ask before changing it.

## Phase 0 — de-risk the assumptions

- [x?] **T-001** [REQ-007, REQ-008] Confirm the bind probe detects a running engine.
  - _Files_: a throwaway script in the scratchpad (not committed)
  - _Output_: a recorded result in this task: does `PacketPeerUDP.bind(7000, "127.0.0.1")` fail
    while `./run_engine.sh` holds the port, and succeed when the engine is stopped?
  - _Verify_: run the script both ways with `godot --headless -s`. If the probe gives a false
    "free", switch the design to the heartbeat fallback through the divergence protocol before T-020.
  - _Depends on_: —
  - _Result_: the Rust engine binds with plain `std::net::UdpSocket::bind` (`Engine/src/osc/server.rs:120`), no `SO_REUSEADDR`/`SO_REUSEPORT`, no socket2. Emulated with a Python plain-socket holder on 127.0.0.1:17000 and a headless Godot script calling `PacketPeerUDP.bind(17000, "127.0.0.1")`: while held, `bind` returned error 2 (ERR_UNAVAILABLE, "HELD"); after release it returned OK ("FREE"). No false "free". The real engine on 7000 was not touched. The check against the real engine is still a live item (T-024 step 2).

## Phase 1 — version and engine foundations

- [x?] **T-002** [REQ-005] `VERSION` file, `Engine/build.rs` and `build_info.rs`.
  - _Files_: `VERSION`, `Engine/build.rs`, `Engine/src/build_info.rs`, `Engine/src/lib.rs`,
    `Engine/Cargo.toml`
  - _Output_: `engine::build_info::{VERSION, COMMIT, PROTOCOL}`. `Cargo.toml` version is `0.1.0-beta.1`.
  - _Verify_: `cargo test build_info` passes (`VERSION` matches the file and `COMMIT` isn't empty), and
    `cargo build --release` passes
  - _Depends on_: —
  - Verified: `cargo test build_info` passes, `cargo build --release --bins` passes, and `engine --version` prints `0.1.0-beta.1 (<commit>)`.

- [x?] **T-003** [REQ-004, REQ-010, REQ-011] Engine CLI parsing.
  - _Files_: `Engine/src/cli.rs`, `Engine/src/lib.rs`
  - _Output_: `CliArgs` and `parse()`, with tests for `--log-dir`, `--parent-pid`, `--version` and an
    unknown argument
  - _Verify_: `cargo test cli::` passes
  - _Depends on_: —
  - Verified: `cargo test cli::` passes (6 tests). Also records unknown/malformed arguments so `main` can warn once logging is up.

- [x?] **T-004** [REQ-004] Engine logs go to a configurable directory.
  - _Files_: `Engine/src/logging/mod.rs`, `Engine/src/logging/rotate.rs`,
    `Engine/src/audio/ipc/process/launch.rs`, `Engine/src/main.rs`
  - _Output_: `default_log_dir()`. `init(status_tx, dir)`. `LogWriters.dir`. Rotation and retention
    use it. `SONARA_LOG_DIR` is set before threads start, and `plugin_log_dir()` reads it.
  - _Verify_: `cargo test logging::` passes (new rotation and retention tests in a temp dir). Running
    `./run_release.sh` from `Engine/` creates `~/.local/state/sonara/logs/engine/last_combined.log`,
    and nothing new appears in `Engine/logs/`.
  - _Depends on_: T-003
  - Verified: `cargo test logging::` passes (default dir from XDG/HOME, rotation and retention in a temp dir). **Pending live:** run `./run_release.sh` and check `~/.local/state/sonara/logs/engine/last_combined.log` exists and `Engine/logs/` stays untouched. Note: `cargo test` itself now writes a plugin-host log (`vst3-test-*.log`) under `~/.local/state/sonara/logs/engine/plugins/`, because `plugin_log_dir()` falls back to the default dir when `SONARA_LOG_DIR` is unset.

- [x?] **T-005** [REQ-011] `--parent-pid` → `PR_SET_PDEATHSIG` plus the `getppid()` check, and
  `--version`.
  - _Files_: `Engine/src/main.rs`
  - _Output_: the engine exits on SIGTERM when its parent dies. `engine --version` prints
    `0.1.0-beta.1 (<commit>)`.
  - _Verify_: `sh -c 'target/release/engine --parent-pid $$ & sleep 3; kill -9 $$'` from a
    wrapper shell. The engine's log ends with "Termination signal received" and no engine process
    remains.
  - _Depends on_: T-002, T-003
  - Verified: `target/release/engine --version` prints and exits in 25 ms before any logging, audio or OSC init. **Pending live:** the wrapper-shell kill -9 test (it starts a real engine on 7000).

- [x?] **T-006** [REQ-010] `/engine/quit`.
  - _Files_: `Engine/src/osc/server.rs`, `Engine/src/osc/routes/audio.rs`,
    `Engine/src/osc/routes/mod.rs` (test)
  - _Output_: `OscServer::request_quit()` and the `quit_requested` flag. `run()` returns, and `main`
    restores the forced clock.
  - _Verify_: `cargo test osc::routes::tests::engine_quit` passes. Live: `oscsend localhost 7000 /engine/quit`
    makes the engine exit within 1 s, and the log shows the PipeWire restore.
  - _Depends on_: —
  - Verified: `cargo test osc::routes::tests::engine_quit` passes. **Pending live:** `oscsend localhost 7000 /engine/quit` and the PipeWire restore line in the log.

- [x?] **T-007** [REQ-006] `/status/engine_info` after `/status/connected`.
  - _Files_: `Engine/src/osc/routes/project.rs`
  - _Output_: the message carries `s:version s:commit i:protocol`
  - _Verify_: `cargo test` passes. Live: `oscdump 7001` shows `/status/engine_info` after sending
    `/project/init`.
  - _Depends on_: T-002
  - Verified: `cargo test` passes (1178+ tests). **Pending live:** `oscdump 7001` after `/project/init`.

## Phase 2 — Godot paths and build info

- [x?] **T-008** [REQ-001–REQ-004] `AppPaths`.
  - _Files_: `Godot/core/AppPaths.gd`, `Godot/tests/test_app_paths.gd`
  - _Output_: the static path getters, plus `env_override` for tests
  - _Verify_: `Godot/tests/run_all.sh app_paths` passes (XDG overrides, documents fallback,
    subfolders)
  - _Depends on_: —
  - Verified: `test_app_paths.gd` passes.

- [x?] **T-009** [REQ-001, REQ-002] Point `Sonara`, the presets default and `NoteMapLibrary` at
  `AppPaths`.
  - _Files_: `Godot/Sonara.gd`, `Godot/settings/Settings.gd`, `Godot/data/NoteMapLibrary.gd`
  - _Output_: projects go to `projects/`, note maps to `<Documents>/Sonara/note_maps`, and the presets
    default comes from `default_presets_path()`
  - _Verify_: `Godot/tests/run_all.sh` passes. No `"/Documents/"` literal remains outside
    `AppPaths.gd` (`grep -rn '"/Documents' Godot --include=*.gd`).
  - _Depends on_: T-008
  - Verified: full `Godot/tests/run_all.sh -j2` passes except the pre-existing `test_modulators_ui.gd` (fails identically on master). `grep -rn '"/Documents' Godot --include=*.gd` finds nothing outside `AppPaths.gd`. Remaining `~/Documents/sonara/presets` literal in `Settings.gd` is the pre-#134 legacy path used only by `migrate_presets_dir`.
  - Also changed (not in the file list): `ai/prompt/PromptTemplate.gd`, `ai/chat/ConversationStore.gd` and `devices/simple_view/SimpleLayoutStore.gd` had their own `$HOME/.config/sonara` fallbacks; they now call `AppPaths.config_dir()`. `tests/test_presets_default_path.gd` was updated for the new default.

- [x?] **T-010** [REQ-003] Move caches and AI temp files to the cache dir.
  - _Files_: `Godot/browser/FileScanAssetProvider.gd`, `Godot/ai/openrouter/MediaEncode.gd`
  - _Output_: the `*_cache.json` files and `aichat/tmp` live under `~/.cache/sonara`
  - _Verify_: `Godot/tests/run_all.sh asset media` passes. Live: delete `~/.cache/sonara` and
    restart; the caches come back and nothing else is lost.
  - _Depends on_: T-008
  - Verified: asset/media tests pass in the full run. **Pending live:** delete `~/.cache/sonara` and restart.

- [x?] **T-011** [REQ-004] UI log under the state dir.
  - _Files_: `Godot/support/Log.gd`
  - _Output_: `~/.local/state/sonara/logs/ui/last.log` outside test mode. Tests keep
    `res://logs/last.log`. `PerfRecorder` follows automatically.
  - _Verify_: live: `godot --path Godot` writes the new file. `Godot/tests/run_all.sh` still passes.
  - _Depends on_: T-008
  - Verified: tests still pass (test mode keeps `res://logs/last.log`). **Pending live:** `godot --path Godot` writes `~/.local/state/sonara/logs/ui/last.log`.

- [x?] **T-012** [REQ-005] `BuildInfo` and the stamp script.
  - _Files_: `Godot/core/BuildInfo.gd`, `Godot/tests/test_build_info.gd`,
    `scripts/stamp_version.sh`, `.gitignore`, `Godot/project.godot`
  - _Output_: `version()`, `commit()`, `channel()`, `install_dir()` and `compare_versions()`. The
    script writes `build_info.json`, `config/version` and the `Cargo.toml` version.
  - _Verify_: `Godot/tests/run_all.sh build_info` passes. After running the script, `git status`
    shows only the expected changes and `build_info.json` stays ignored.
  - _Depends on_: T-002
  - Verified: `test_build_info.gd` passes. `scripts/stamp_version.sh` run: `git status` shows no change (values already in sync) and `Godot/build_info.json` is ignored.

- [x?] **T-013** [REQ-006] Godot receives `/status/engine_info`, and the Editor warns on a mismatch.
  - _Files_: `Godot/core/AudioEngineOSC.gd`, `Godot/editor/Editor.gd`,
    `Godot/tests/test_engine_info.gd`
  - _Output_: `engine_version`, `engine_commit`, `engine_protocol` and `engine_info_received`. A
    protocol mismatch triggers `show_error` with both versions.
  - _Verify_: `Godot/tests/run_all.sh engine_info` passes
  - _Depends on_: T-007, T-012
  - Verified: `test_engine_info.gd` passes (also checks the `/engine/quit` OSC byte encoding).

## Phase 3 — engine lifecycle in the UI

- [x?] **T-014** [REQ-007, REQ-008, REQ-010] The `EngineProcess` autoload.
  - _Files_: `Godot/core/EngineProcess.gd`, `Godot/project.godot`
  - _Output_: `ensure_running()` (probe, then attach or spawn with `--log-dir` and
    `--parent-pid`), `engine_binary_path()` (exported binary or dev path), `stop()` (quit, wait 3 s,
    kill), and `_exit_tree()`. It does nothing in test mode.
  - _Verify_: `Godot/tests/run_all.sh` passes (the autoload is inert headless). Live is checked in
    T-024.
  - _Depends on_: T-001, T-005, T-006
  - Verified: the autoload is inert in the headless suite. Live in T-024.

- [x?] **T-015** [REQ-007, REQ-009, REQ-010] Wire `EngineProcess` into the Editor and `EnginePanel`.
  - _Files_: `Godot/editor/Editor.gd`, `Godot/editor/EnginePanel.gd`
  - _Output_: `_connect_project_to_engine()` awaits `ensure_running()`. `quit()` calls `stop()`. When
    the engine is disconnected the panel shows "Start Engine", and pressing it launches the engine
    and reconnects.
  - _Verify_: live (T-024, steps 1–4)
  - _Depends on_: T-014
  - Implemented: `Editor._connect_project_to_engine` awaits `ensure_running()`, `quit()` awaits `EngineProcess.stop()`, `EnginePanel` shows "Start Engine" when the port is free and a binary exists. **Pending live (T-024).**

- [x?] **T-016** [REQ-018] Single-instance PID file.
  - _Files_: `Godot/Sonara.gd`, `Godot/core/EngineProcess.gd`
  - _Output_: `$XDG_RUNTIME_DIR/sonara/ui.pid`, `is_duplicate_instance`, the `OS.alert` and quit
    for a second launch, and the PID file removed on exit
  - _Verify_: live: start two `godot --path Godot`. The second one alerts and exits, and only one
    engine runs.
  - _Depends on_: T-014
  - Implemented as `core/SingleInstance.gd` (static, testable) called from `Sonara._ready`. A duplicate also skips `AudioEngineOSC._ready` and `Editor._ready` so it opens no sockets and sends nothing to the first instance's engine. Verified: `test_single_instance.gd` (stale pid, recycled pid, live pid). **Pending live:** two real launches.

- [x?] **T-017** [REQ-017] Open a `.sonara` file from the command line.
  - _Files_: `Godot/Sonara.gd`, `Godot/editor/Editor.gd`
  - _Output_: `cli_project_path()`. `_load_startup_project()` becomes `_load_initial_project(path)`,
    which prefers the CLI path.
  - _Verify_: live: `godot --path Godot -- ~/Documents/Sonara/projects/<x>.sonara` opens `<x>`. In
    the exported build this is re-checked in T-025.
  - _Depends on_: T-009
  - Implemented: `Sonara.cli_project_path()` reads both `OS.get_cmdline_args()` and `get_cmdline_user_args()`. Verified: `test_single_instance.gd` covers the path parsing. **Pending live:** `godot --path Godot -- <x>.sonara` and, in the export, a bare `sonara <x>.sonara`.

## Phase 4 — Help menu and update check

- [x?] **T-018** [REQ-012] About dialog.
  - _Files_: `Godot/editor/AboutDialog.gd`, `Godot/editor/MainMenu.gd`,
    `Godot/tests/test_about_dialog.gd`
  - _Output_: Help > About Sonara shows the UI and engine versions and the commit, GitHub and
    itch.io buttons, and a Licenses window
  - _Verify_: `Godot/tests/run_all.sh about_dialog` passes. Live: both links open the browser.
  - _Depends on_: T-012, T-013
  - Verified: `test_about_dialog.gd` passes. **Pending live:** the links.

- [x?] **T-019** [REQ-013] Help > Open Logs Folder.
  - _Files_: `Godot/editor/MainMenu.gd`
  - _Output_: the menu item opens `AppPaths.log_dir()`
  - _Verify_: live: the file manager opens on `~/.local/state/sonara/logs/`
  - _Depends on_: T-008
  - Implemented (creates the folder first, then `OS.shell_open`). **Pending live.**

- [x?] **T-020** [REQ-021, REQ-022] `UpdateChecker` and its setting.
  - _Files_: `Godot/core/UpdateChecker.gd`, `Godot/settings/Settings.gd`, `Godot/editor/Editor.gd`,
    `Godot/tests/test_update_checker.gd`
  - _Output_: `updates/check_enabled` (default on). The check runs at most once a day, only on the
    `github` channel. `pick_newest()`. The notice has an "Open release page" button.
  - _Verify_: `Godot/tests/run_all.sh update_checker` passes (newer, same, older, draft, and bad
    JSON). Live: a dev run makes no request (no "UpdateChecker" line in the UI log).
  - _Depends on_: T-012
  - Verified: `test_update_checker.gd` passes. Dev runs are the `dev` channel (`OS.has_feature("editor")`), so they never request or log.

## Phase 5 — packaging and CI

- [x?] **T-021** [REQ-014] Godot export preset.
  - _Files_: `Godot/export_presets.cfg`
  - _Output_: the developer's `Linux Release` preset (pck embedded) with filters: excludes `tests/*` and `ai/tests/*`, includes `ai/prompt/*.md` and `build_info.json`
  - _Verify_: `godot --headless --path Godot --export-release "Linux Release" <scratch>/Sonara.x86_64` produces a
    binary that starts and connects to a running engine, and the AI system prompt loads (no "SHIPPED_PATH" error in the UI log)
  - _Depends on_: T-012
  - Divergence: `Godot/export_presets.cfg` already contains the filters; nothing to change. **Not run:** export templates are not installed (`~/.local/share/godot/export_templates/` is empty), and none were downloaded. Pending: run the export command from the Verify line once templates exist.

- [x?] **T-022** [REQ-014, REQ-015, REQ-016] Install and uninstall scripts, desktop entry, MIME
  type.
  - _Files_: `packaging/linux/install.sh`, `packaging/linux/uninstall.sh`,
    `packaging/linux/sonara.desktop`, `packaging/linux/sonara-mime.xml`
  - _Output_: a user-level install into `~/.local`, upgrade in place, and an uninstall that removes
    only what the install added
  - _Verify_: `shellcheck` is clean. Live in T-025.
  - _Depends on_: —
  - Verified without `shellcheck` (not installed): `bash -n`, and a full install, in-place upgrade (a removed file disappears) and uninstall run in a scratch `HOME` with a stub archive; `~/Documents/Sonara` and `~/.config/sonara` stayed intact. `uninstall.sh` is installed into the app folder so it works without the archive, and it removes the `mimeapps.list` default line. Run `shellcheck` when available.

- [x?] **T-023** [REQ-014] `scripts/package_linux.sh`.
  - _Files_: `scripts/package_linux.sh`, `.gitignore`
  - _Output_: `dist/sonara-<v>-linux-x86_64.tar.gz` and its `.sha256`. The engine and plugin host
    use rpath `$ORIGIN/lib`, the libraries are bundled, and the `channel` file is written.
  - _Verify_: run locally. `ldd dist/…/engine` resolves `libsndfile` from `lib/`, and the script's
    "not found" check passes.
  - _Depends on_: T-021, T-022
  - Verified with a stub in place of Godot (`--godot fakegodot.sh`; export templates are not installed): the engine builds into `dist/target` with a DT_RPATH `$ORIGIN/lib`, bundles libsndfile, FLAC, vorbis, vorbisenc, opus, ogg, mpg123 and mp3lame, every bundled library resolves from `lib/`, and the tarball and `.sha256` check out. Divergence: the rpath is DT_RPATH (`-Wl,--disable-new-dtags`), not the default DT_RUNPATH, because a RUNPATH on the engine does not apply to libsndfile's own dependencies. Divergence: the script builds into `dist/target` (not `Engine/target`) so dev builds aren't invalidated by the changed RUSTFLAGS. **Pending:** a run with the real Godot export (needs export templates).

- [ ] **T-024** [REQ-007–REQ-011, REQ-013, REQ-018] Live check of the engine lifecycle on the dev
  machine.
  - _Files_: — (record results in this task)
  - _Output_: each step passes, or a gap is filed as a new task
  - _Verify_:
    1. no engine running → `godot --path Godot` → "Connected";
    2. `./run_engine.sh` first → the UI attaches and only one `engine` process exists;
    3. `kill` the engine → "Start Engine" → it reconnects and the project resyncs;
    4. quit the UI → the engine exits within 3 s. Ask before touching the quantum, then check
       `pw-metadata -n settings`;
    5. `kill -9` the UI → the engine is gone within 5 s;
    6. Open Logs Folder opens the right folder;
    7. a second launch shows the alert.
  - _Depends on_: T-015, T-016, T-019

- [ ] **T-025** [REQ-014–REQ-017] Clean-machine install test.
  - _Files_: — (record results here and in `docs/releasing.md`)
  - _Output_: the tarball works on Ubuntu 22.04 with no build packages
  - _Verify_: in a VM:
    1. extract and run → "Connected";
    2. `install.sh` → there's a menu entry and the `sonara` command works;
    3. double-click a `.sonara` file → it opens;
    4. run `install.sh` again (upgrade) → still works;
    5. `uninstall.sh` → everything it added is gone and user data is intact.
  - _Depends on_: T-023, T-017

- [ ] **T-026** [REQ-019, REQ-020] GitHub Actions release workflow.
  - _Files_: `.github/workflows/release.yml`
  - _Output_: tag and manual triggers, an `ubuntu:22.04` container, a check that the tag matches
    `VERSION`, a Release upload, and an optional butler push
  - _Verify_: a manual run (`gh workflow run release.yml`) produces a downloadable artifact that
    passes T-025 step 1. The first tag `v0.1.0-beta.1` creates a Release with the tarball and
    checksum.
  - _Depends on_: T-023

## Phase 6 — docs

- [x?] **T-027** [REQ-006, REQ-010] `docs/subsystems/osc-protocol.md`: `/engine/quit`,
  `/status/engine_info`, and the updated Connection Handshake section.
  - _Files_: `docs/subsystems/osc-protocol.md`
  - _Output_: both messages documented with direction and argument types
  - _Verify_: `grep -n "engine/quit\|engine_info" docs/subsystems/osc-protocol.md` shows both
  - _Depends on_: T-006, T-007
  - Verified: grep shows both messages; the Connection Handshake section is updated.

- [x?] **T-028** [REQ-001–REQ-004] Path and log docs.
  - _Files_: `AGENTS.md`, `docs/subsystems/engine-debugging.md`,
    `docs/subsystems/godot-config-system.md`
  - _Output_: the new locations, `AppPaths`, `--log-dir`, and the fact that the UI starts the engine
  - _Verify_: `grep -rn "Engine/logs\|Godot/logs" AGENTS.md docs/subsystems` returns nothing stale
  - _Depends on_: T-004, T-011
  - Verified: `grep -rn "Engine/logs\|Godot/logs" AGENTS.md docs/subsystems` shows only the intentional mentions that headless tests keep `Godot/logs`. `CONTEXT.md`, `README.md`, the run scripts' comments and `test_plugin_osc.sh` were updated too.

- [x?] **T-029** [REQ-007–REQ-011] ADR 0022: the UI owns the engine process.
  - _Files_: `docs/adr/0022-ui-owns-engine-process.md`
  - _Output_: context, decision, the rejected heartbeat watchdog, consequences
  - _Verify_: the file exists, follows the format of the existing ADRs, and is linked from the
    design
  - _Depends on_: T-015
  - Verified: the ADR exists in the 0021 format. Linked from the design? Not yet: design.md was left untouched (one-line link to add when the spec is next edited).

- [ ] **T-030** [REQ-014, REQ-015, REQ-019, REQ-020] `docs/releasing.md` and the README install
  section.
  - _Files_: `docs/releasing.md`, `README.md`
  - _Output_: how to cut a release (bump `VERSION`, run `gen_third_party_licenses.sh`, tag, push),
    the `BUTLER_API_KEY` secret, publishing the itch page, the CI base image choice, and install
    instructions for users
  - _Verify_: following the doc from a clean checkout produces a release (exercised in T-026)
  - _Depends on_: T-026

## Phase 7 — converge

- [ ] **T-031** [REQ-all] Compare `git diff` with this file and with requirements.md. Add a task
  for every gap, or report "converged".
  - _Files_: —
  - _Output_: the convergence report
  - _Verify_: every REQ has a `[x]` task. `cargo test`, `cargo fmt --check` and
    `Godot/tests/run_all.sh` all pass.
  - _Depends on_: T-024, T-025, T-026, T-027–T-030
