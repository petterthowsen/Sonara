# Beta Release — Design

Implements [requirements.md](./requirements.md).

## Context

Engine:
- `Engine/src/main.rs` — `main()`. It takes no command-line arguments. It calls
  `logging::init(&status_tx)`, then installs a `ctrlc` handler (feature `termination`, so it also
  catches SIGTERM). That handler restores PipeWire's forced quantum through
  `engine.forced_clock()` and calls `exit(0)`. Finally it runs `OscServer::new(7000, …)` and
  `osc_server.run(…)` until the receiver thread stops.
- `Engine/src/logging/mod.rs` — `init()` hard-codes `logs/last_{info,warn,combined}.log`
  relative to the working directory. `LogWriters` holds the three file handles.
- `Engine/src/logging/rotate.rs` — `rotate_log_files()` and `enforce_retention()` hard-code
  `logs/`.
- `Engine/src/audio/ipc/process/launch.rs` — `plugin_log_dir()` uses `current_dir()/logs/plugins`.
  `main.rs` `prune_plugin_logs()` calls it.
- `Engine/src/osc/server.rs` — `OscServer` and its `run()` loop.
  `Engine/src/osc/routes/mod.rs` `handle_message` dispatches `audio | engine` to
  `routes/audio.rs` `route()`, which already serves `/engine/perf/*` and `/engine/threads/set`.
- `Engine/src/osc/routes/project.rs` — `/project/init` answers `/status/connected 1` straight
  through `cx.server.send_message`.
- `Engine/src/osc/status.rs` — sends `/status/heartbeat` every second to `127.0.0.1:7001`,
  whether or not a client is connected.
- `Engine/Cargo.toml` — `version = "0.1.0"` and `libc` already present. There's no `build.rs`.

Godot:
- `Godot/Sonara.gd` (first autoload) — `get_config_dir()` (`$HOME/.config/sonara`),
  `get_projects_dir()` (`$HOME/Documents/Sonara`), `_ensure_projects_dir()`,
  `get_startup_project_path()`.
- `Godot/support/Log.gd` — `log_file_path := "res://logs/last.log"`, opened in `_static_init()`
  before any autoload runs. `Godot/components/PerfRecorder.gd` writes `perf_*.txt` beside it.
- `Godot/settings/Settings.gd` — `DEFAULT_PRESETS_PATH := "~/Documents/Sonara/presets"`,
  `migrate_presets_dir()`, `_register(Setting.new(…))`, `CATEGORY_BEHAVIOR`.
- `Godot/data/NoteMapLibrary.gd` — dir is `Sonara.get_config_dir().path_join("note_maps")`.
- `Godot/browser/FileScanAssetProvider.gd` — the cache file is
  `Sonara.get_config_dir().path_join(_cache_file_name())`. This covers `samples_cache.json`,
  `sfz_cache.json` and `preset_cache.json`.
- `Godot/ai/openrouter/MediaEncode.gd` — `TMP_SUBDIR := "aichat/tmp"` under the config dir.
- `Godot/core/AudioEngineOSC.gd` — `ENGINE_SEND_PORT = 7000`, `ENGINE_RECEIVE_PORT = 7001`,
  signals `engine_connected` and `engine_disconnected`, special handling of `/status/connected`.
- `Godot/data/Project.gd` — `connect_to_engine()` handshake with retry and `connection_failed`.
- `Godot/editor/Editor.gd` — `_ready()` opens a blank project, then `_load_startup_project()`.
  `_connect_project_to_engine()` waits for `AudioEngineOSC._is_ready`. `request_quit()` →
  `quit()` → `get_tree().quit()`. `show_error(title, body, actions)` uses `PopupMessage`.
- `Godot/editor/EnginePanel.gd` — `_on_connect_button_pressed()` and
  `_on_connection_failed()` ("Is the engine running? Click to retry.").
- `Godot/editor/MainMenu.gd` — `_help_menu` with `HELP_ITEMS { Perf_Capture }`.
- `Godot/core/Utils.gd` — `expand_path()`, `is_test_mode()`, `reveal_in_file_manager()`.
- `Godot/project.godot` — `config/version="0.1"`.
- `Godot/export_presets.cfg` — one `Linux Release` preset (embedded pck) added with the spec.
- `scripts/gen_third_party_licenses.sh` — generates `THIRD_PARTY_LICENSES`.

## Approach

**Paths.** A new static class, `AppPaths`, is the only place that knows the folder layout. It's
static because `Log._static_init()` runs before `Sonara` exists. `Sonara.get_config_dir()` and
`get_projects_dir()` become thin wrappers around it, so their existing callers keep working, and
every other hard-coded path (`NoteMapLibrary`, `FileScanAssetProvider`, `MediaEncode`, `Log`, the
presets default) switches to it. The documents root comes from
`OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)`, which reads the XDG user dirs, with
`$HOME/Documents` as the fallback. The XDG base dirs come from `XDG_CONFIG_HOME`,
`XDG_CACHE_HOME` and `XDG_STATE_HOME`, each falling back to its standard default.

**Engine logs.** The engine gets a log directory: `--log-dir <path>` when given, otherwise the
same XDG state default the UI computes (`…/sonara/logs/engine`). `logging::init` and the rotation
code take that directory instead of the literal `logs/`. The engine puts the directory into
`SONARA_LOG_DIR` before any thread starts, so plugin hosts (child processes) inherit it, and
`plugin_log_dir()` reads it. Dev runs also log to the state folder, so there's one logs location
everywhere. AGENTS.md and `engine-debugging.md` are updated to match. Rejected alternative:
keeping `Engine/logs/` for dev and the state folder for releases. Two locations means Help > Open
Logs Folder is wrong half the time, and agents look in the wrong place.

**Version.** A root `VERSION` file holds the version and is the single source of truth.
`Engine/build.rs` reads `../VERSION` and `git rev-parse --short HEAD` and exposes them as
`SONARA_VERSION` and `SONARA_COMMIT`. The Godot side can't read outside `res://` once exported,
so `scripts/stamp_version.sh` writes `Godot/build_info.json` (gitignored) with the version and
commit before export, and also updates `config/version` in `project.godot` and `version` in
`Cargo.toml` so the metadata agrees. The new class `BuildInfo` reads `res://build_info.json`. When
the file is missing (dev run), it reads `../VERSION` next to the project folder and reports
commit `dev`. The release channel is a plain file named `channel` next to the executable
(`github` or `itch`). A missing file means `dev`. This way the same export serves both stores.

**Engine identity and quit.** `/project/init` already answers `/status/connected`. Right after
that it also sends `/status/engine_info s:version s:commit i:protocol`. An engine that never sends
it counts as "unknown". New `/engine/quit` sets an `AtomicBool` on `OscServer`. `run()` checks the
flag after each packet and returns `Ok(())`, so `main()` takes its normal path and calls
`forced_clock.restore()`.

**Launching the engine.** A new autoload, `EngineProcess`, owns the engine's lifetime from the UI
side. `ensure_running()` first tries to bind UDP `127.0.0.1:7000` with `PacketPeerUDP`:
- If the bind fails, something already owns the engine port. The UI attaches and the `owned`
  flag stays false.
- If the bind succeeds, the UI releases the port and starts the engine binary with
  `OS.create_process(path, ["--log-dir", <ui-computed engine log dir>, "--parent-pid", <own pid>])`.

The bind probe was chosen over waiting for a heartbeat because it takes no time; a heartbeat
probe would add about a second to every launch.

Where the binary comes from:
- exported build: next to `OS.get_executable_path()`;
- editor or dev run: `res://../Engine/target/release/engine`;
- neither exists: the connect flow fails as it does today, and the message tells you to start the
  engine.

Shutting down: `stop()` sends `/engine/quit` with its own `PacketPeerUDP`, so it doesn't depend
on `AudioEngineOSC` still being alive while autoloads tear down. It then polls
`OS.is_process_running(pid)` for up to 3 s, and falls back to `OS.kill(pid)`. `Editor.quit()`
calls it, and `EngineProcess._exit_tree()` calls it as a safety net. It only acts when `owned` is
true.

Orphans: with `--parent-pid`, the engine calls `prctl(PR_SET_PDEATHSIG, SIGTERM)` at start and
exits right away if `getppid()` already differs (the parent died before the call). The SIGTERM
reaches the existing `ctrlc` handler, which restores the PipeWire quantum. A heartbeat watchdog
was rejected: it would kill an engine that's simply waiting through a long UI stall, such as a big
project sync.

**Single instance.** `Sonara._ready()` (outside test mode) writes its PID to
`$XDG_RUNTIME_DIR/sonara/ui.pid`. If that file already names a live process whose
`/proc/<pid>/exe` (read with `readlink`) is the same executable as ours, the UI shows `OS.alert`
("Sonara is already running") and quits, and it sets `Sonara.is_duplicate_instance` so
`EngineProcess` never launches. Rejected alternative: a bind probe on 7001. Godot may set
`SO_REUSEADDR` on UDP sockets, which would make that probe unreliable.

**Command-line project.** `Sonara.cli_project_path()` returns the first argument in
`OS.get_cmdline_args()` or `OS.get_cmdline_user_args()` that ends in `.sonara` and exists.
`Editor._ready()` loads it instead of the startup project, through the same builtins wait.
`_load_startup_project()` becomes `_load_initial_project(path)`.

**Packaging.**
- `Godot/export_presets.cfg` (added by the developer) has one `Linux Release` preset: pck embedded in the binary (a single executable; there are no GDExtensions), exports to `Godot Exports/Sonara.x86_64` by default, excludes `tests/*` and
  `ai/tests/*`, and includes the non-resource files read at runtime: `ai/prompt/*.md` (`PromptTemplate.SHIPPED_PATH`) and `build_info.json`. `package_linux.sh` passes its own output path.
- `scripts/package_linux.sh` builds the engine with `-C link-arg=-Wl,-rpath,$ORIGIN/lib`, copies
  `libsndfile.so.1` and the codec libraries it pulls in (FLAC, vorbis, vorbisenc, opus, ogg,
  mpg123, mp3lame) into `lib/`, exports Godot, adds `packaging/linux/*`, the license files and the
  `channel` file, then makes the tarball and the `.sha256`. You can run it locally; CI runs the
  same script.
- `install.sh` copies into `~/.local/share/sonara/` and symlinks `~/.local/bin/sonara`. It writes
  `~/.local/share/applications/sonara.desktop` (`Exec=… %f`,
  `MimeType=application/x-sonara-project;`), the icon to
  `~/.local/share/icons/hicolor/scalable/apps/sonara.svg`, and the MIME type to
  `~/.local/share/mime/packages/sonara.xml` (glob `*.sonara`). It then runs
  `update-mime-database`, `update-desktop-database` and
  `xdg-mime default sonara.desktop application/x-sonara-project`, each only when present. It
  copies files over atomically (`install` writes a new inode), so upgrading while the app runs is
  safe. `uninstall.sh` removes exactly those files.

**CI.** `.github/workflows/release.yml` runs on `push: tags: v*` and on `workflow_dispatch`:
1. Uses a `debian:12` container (originally `ubuntu:22.04`; see Risks) on `ubuntu-latest`. Installs the build prerequisites from
   AGENTS.md.
2. Restores the cargo cache. Downloads Godot 4.7-stable and its export templates from
   `godotengine/godot-builds`.
3. Checks that the tag equals `v$(cat VERSION)`, runs `stamp_version.sh` and
   `package_linux.sh`.
4. On a tag, creates a GitHub Release (not a prerelease, see Risks) with the tarball and checksum.
5. If the `BUTLER_API_KEY` secret exists, pushes the extracted folder (with `channel` = `itch`)
   to `thowsenmedia/sonara:linux` with `--userversion $(cat VERSION)`.
6. A manual run stops after uploading the folder as a workflow artifact.

**Update check.** `UpdateChecker` is a node the Editor creates in non-test mode. It runs only when
`BuildInfo.channel() == "github"`, the `updates/check_enabled` setting is on, and
`updates/last_check_unix` (internal state, `Sonara.set_config`) is more than 24 h old. It requests
`https://api.github.com/repos/petterthowsen/Sonara/releases?per_page=10` through `HTTPRequest`,
ignores drafts, and picks the highest version with `BuildInfo.compare_versions()` (semver with
prerelease ordering). If that's newer, it calls `Sonara.editor.show_error("Update available", …)`
with an "Open release page" action that runs `OS.shell_open(html_url)`. Failures go to the log at
INFO level only. The list endpoint is used instead of `/releases/latest` because `latest`
excludes prereleases.

**Help menu.**
- `AboutDialog` is built in code, like `QuitPromptDialog`. It shows the icon, `BuildInfo`
  version and commit, the engine version from `AudioEngineOSC.engine_version` (or "not
  connected"), and GitHub and itch.io link buttons (`OS.shell_open`). A Licenses button opens a
  read-only `TextEdit` window with `LICENSE` and `THIRD_PARTY_LICENSES` from
  `BuildInfo.install_dir()` (the repo root in dev).
- Open Logs Folder calls `OS.shell_open(AppPaths.log_dir())`. It opens the folder itself, not a
  selection in its parent, which is what `reveal_in_file_manager` would do.

**Version mismatch.** `AudioEngineOSC` stores `engine_version`, `engine_commit` and
`engine_protocol`, and emits `engine_info_received`. The Editor compares the protocol with
`BuildInfo.PROTOCOL`. On a mismatch it shows a warning naming both versions and stays connected.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `OscServer::quit_requested: AtomicBool` | engine main thread (OSC server) | set by the `/engine/quit` route, read by `run()` on the same thread | not on the audio path |
| Log directory | engine main, set once before threads start | `SONARA_LOG_DIR` env (plugin hosts), `LogWriters.dir` (rotation on main thread) | not on the audio path |
| `PR_SET_PDEATHSIG` | kernel → SIGTERM → `ctrlc` handler thread | existing handler | unchanged |
| `EngineProcess` pid / owned | Godot main thread | `Editor`, `EnginePanel` | n/a |

Nothing touches the audio callback.

## Data and protocol changes

**OSC** (each one goes into `docs/subsystems/osc-protocol.md`, and the Connection Handshake
section gets updated):
- `/engine/quit` (Godot → Rust), no args. Handled in `routes/audio.rs` `route()`. The OSC server
  stops and the engine exits after restoring PipeWire settings. It isn't an `AudioCommand`, since
  nothing goes to the command thread.
- `/status/engine_info s:version s:commit i:protocol` (Rust → Godot). Sent from
  `routes/project.rs` right after `/status/connected`. The protocol starts at `1`
  (`engine::build_info::PROTOCOL`, `BuildInfo.PROTOCOL` in Godot). Bump it on any incompatible
  OSC change.

**Engine CLI:** `--log-dir <path>`, `--parent-pid <pid>`, `--version` (prints and exits). Unknown
arguments get a warning and are ignored. Parsing lives in `Engine/src/cli.rs` so it can be tested.

**Setting:** `updates/check_enabled`, `Type.BOOL`, default `true`, `CATEGORY_BEHAVIOR`, sub
"Updates", with the description "Check GitHub for a newer Sonara release at startup (at most
once a day). Only sends a request for the release list." Internal config key:
`updates/last_check_unix` (int).

**Presets default:** `DEFAULT_PRESETS_PATH` becomes `Settings.default_presets_path()`, which
returns `AppPaths.presets_dir()`. A saved `presets/path` still wins.
`migrate_presets_dir()` keeps working with the new default.

**Files:** `.sonara`, `.sonpreset` and note map formats are unchanged.

## File-by-file change list

| File | Change |
|---|---|
| `VERSION` | New: `0.1.0-beta.1`. |
| `Engine/build.rs` | New: reads `../VERSION` and the git short hash, emits `cargo:rustc-env=SONARA_VERSION/SONARA_COMMIT`, and `rerun-if-changed` on `../VERSION` and `../.git/HEAD`. |
| `Engine/Cargo.toml` | `version` = `0.1.0-beta.1` (kept in sync by `stamp_version.sh`). |
| `Engine/src/build_info.rs` | New: `VERSION`, `COMMIT`, `PROTOCOL: i32 = 1`. |
| `Engine/src/cli.rs` | New: `CliArgs { log_dir: Option<PathBuf>, parent_pid: Option<i32>, print_version: bool }`, `parse(impl Iterator<Item=String>)`, plus tests. |
| `Engine/src/lib.rs` | `pub mod build_info; pub mod cli;`. |
| `Engine/src/main.rs` | Parse args. Handle `--version`. `--parent-pid` → `prctl(PR_SET_PDEATHSIG, SIGTERM)` and the `getppid()` check. Resolve the log dir (`logging::default_log_dir()` when not given), set `SONARA_LOG_DIR`, pass it to `logging::init`. Log the version at start. |
| `Engine/src/logging/mod.rs` | `init(status_tx, dir: &Path)`. Add `default_log_dir()` (XDG state + `sonara/logs/engine`). `LogWriters` gets `dir: PathBuf`. |
| `Engine/src/logging/rotate.rs` | Use `log_writers.dir` instead of `"logs/"`. `enforce_retention(dir, …)`. |
| `Engine/src/audio/ipc/process/launch.rs` | `plugin_log_dir()` = `$SONARA_LOG_DIR/plugins`, falling back to `default_log_dir()/plugins`. Update the doc comment. |
| `Engine/src/osc/server.rs` | `quit_requested: AtomicBool` field plus `request_quit()`. `run()` returns `Ok(())` once it's set. |
| `Engine/src/osc/routes/audio.rs` | `["engine", "quit"]` → `cx.server.request_quit()`. |
| `Engine/src/osc/routes/project.rs` | Send `/status/engine_info` after `/status/connected`. |
| `Engine/src/osc/routes/mod.rs` | Test: `/engine/quit` routes and sends no command. |
| `Godot/core/AppPaths.gd` | New static class: `documents_root()`, `projects_dir()`, `presets_dir()`, `note_maps_dir()`, `config_dir()`, `cache_dir()`, `state_dir()`, `log_dir()`, `ui_log_dir()`, `engine_log_dir()`, `runtime_dir()`. `static var env_override: Dictionary` for tests. |
| `Godot/core/BuildInfo.gd` | New static class: `PROTOCOL := 1`, `version()`, `commit()`, `channel()`, `install_dir()`, `compare_versions(a, b) -> int`. |
| `Godot/core/EngineProcess.gd` | New autoload: `ensure_running() -> bool` (async), `engine_binary_path()`, `is_owned()`, `stop()`, `_exit_tree()`. Does nothing in test mode or when `Sonara.is_duplicate_instance`. |
| `Godot/core/UpdateChecker.gd` | New node: `check_if_due()`, `_on_request_completed`, static `pick_newest(releases: Array, current: String) -> Dictionary` (testable). |
| `Godot/editor/AboutDialog.gd` | New `Window` built in code: versions, links, Licenses window. |
| `Godot/project.godot` | Add the `EngineProcess` autoload after `AudioEngineOSC`. `config/version` stamped. |
| `Godot/Sonara.gd` | Path getters delegate to `AppPaths`. `get_projects_dir()` → `projects/`. `_ensure_projects_dir()` unchanged. Single-instance PID file and `is_duplicate_instance`. `cli_project_path()`. Remove the PID file on exit. |
| `Godot/support/Log.gd` | `log_file_path` = `AppPaths.ui_log_dir()/last.log` outside test mode, unchanged `res://logs/last.log` in test mode. |
| `Godot/settings/Settings.gd` | `default_presets_path()` replaces the const where it's used. Register `updates/check_enabled`. |
| `Godot/data/NoteMapLibrary.gd` | Dir → `AppPaths.note_maps_dir()` (keeps any existing test override). |
| `Godot/browser/FileScanAssetProvider.gd` | Cache dir → `AppPaths.cache_dir()` (keeps `cache_dir_override`). |
| `Godot/ai/openrouter/MediaEncode.gd` | Temp dir → `AppPaths.cache_dir()/aichat/tmp`. |
| `Godot/core/AudioEngineOSC.gd` | Handle `/status/engine_info` → `engine_version`, `engine_commit`, `engine_protocol`, signal `engine_info_received`. Reset them on disconnect. |
| `Godot/editor/Editor.gd` | `_connect_project_to_engine()` awaits `EngineProcess.ensure_running()`. `_load_initial_project(path)` uses the CLI path first. `quit()` calls `EngineProcess.stop()`. Protocol mismatch warning. Creates `UpdateChecker`. |
| `Godot/editor/EnginePanel.gd` | When disconnected: show "Start Engine". The press awaits `EngineProcess.ensure_running()` before connecting. The failure text no longer says "Is the engine running?" when the UI launches the engine. |
| `Godot/editor/MainMenu.gd` | `HELP_ITEMS` += `About`, `Open_Logs`. Handlers open `AboutDialog` and `OS.shell_open(AppPaths.log_dir())`. |
| `Godot/export_presets.cfg` | Exists (`Linux Release`, embed pck). Add the include and exclude filters. |
| `scripts/stamp_version.sh` | New: VERSION → `Cargo.toml`, `project.godot`, `Godot/build_info.json`. |
| `scripts/package_linux.sh` | New: build, bundle libs, export, assemble, tar, sha256. Takes `--channel github\|itch`. |
| `packaging/linux/install.sh`, `uninstall.sh`, `sonara.desktop`, `sonara-mime.xml` | New. |
| `.github/workflows/release.yml` | New. |
| `.gitignore` | `Godot/build_info.json`, `dist/`, `Godot Exports/`. |
| `docs/subsystems/osc-protocol.md` | The two messages and the handshake section. |
| `docs/subsystems/engine-debugging.md`, `AGENTS.md` (Debugging section) | New log locations. |
| `docs/subsystems/godot-config-system.md` | New layout and `AppPaths`. |
| `docs/releasing.md` | New: how to cut a release (bump VERSION, tag, push) and the itch secret. |
| [`docs/adr/0022-ui-owns-engine-process.md`](../../adr/0022-ui-owns-engine-process.md) | New ADR: the UI launches, attaches to and stops the engine. Parent-death signal instead of a heartbeat watchdog. |
| `README.md` | Install section. |

## Migration and compatibility

There's no migration code, per the Decisions in requirements.md. Run these once on the dev
machine after the path changes land, with Sonara closed:

```bash
cd ~/Documents/Sonara && mkdir -p projects && mv *.sonara *.aichat projects/
mv ~/.config/sonara/note_maps ~/Documents/Sonara/note_maps
mkdir -p ~/.cache/sonara && mv ~/.config/sonara/{preset,samples,sfz}_cache.json ~/.cache/sonara/
```

Recent-project entries in `config.json` point at the old paths and show as missing. The existing
"Clear Recent" handles that. `startup.sonara` stays in `~/.config/sonara`. An engine without
`/status/engine_info` shows "unknown" in About, with no warning. `run_release.sh` and
`run_engine.sh` keep working unchanged (the UI attaches), and their logs now land in
`~/.local/state/sonara/logs/engine/`.

## Test plan

- **Unit (engine):**
  - `cargo test cli::` — parses `--log-dir`, `--parent-pid`, `--version`, and ignores unknown
    arguments.
  - `cargo test logging::` — new tests (there are none today): rotation and retention inside a temp dir, not `logs/`.
  - `cargo test osc::routes::tests::engine_quit` — `/engine/quit` sets the flag and sends no
    `AudioCommand`.
  - `cargo test build_info` — `VERSION` isn't empty and equals the `VERSION` file.
- **Godot** (`Godot/tests/`):
  - `test_app_paths.gd` — XDG overrides, documents fallback, the three content subfolders.
  - `test_build_info.gd` — `compare_versions` (`0.1.0-beta.1 < 0.1.0-beta.2 < 0.1.0 < 0.1.1`),
    and the dev fallback reads `VERSION`.
  - `test_update_checker.gd` — `pick_newest` with newer, same, older and draft entries, and empty
    or malformed JSON.
  - `test_engine_info.gd` — a fed `/status/engine_info` sets the fields, and a protocol mismatch
    is detected.
  - `test_about_dialog.gd` — builds and shows the version strings.
- **Live:** the acceptance steps of REQ-007–011, 013 and 015–018, using the packaged tarball in
  a Debian 12 VM (REQ-014) and the dev machine. For REQ-010, check
  `pw-metadata -n settings | grep force-quantum` after quitting. Per the live-check memory, ask
  before touching the system-wide quantum.

## Risks

| Risk | Mitigation |
|---|---|
| `OS.kill` on Linux sends SIGKILL, which skips the quantum restore. | Graceful `/engine/quit` first, and kill only after 3 s. Even after a SIGKILL, the restore is what's lost, nothing else. |
| `PacketPeerUDP.bind` on 7000 succeeds even though the engine holds it (`SO_REUSEADDR` on both sides). | The Rust socket doesn't set `SO_REUSEADDR`, so the bind should fail. A task verifies this live before anything builds on it. Fallback: wait up to 1.2 s for a heartbeat. |
| Ubuntu 22.04's PipeWire (0.3.48) is too old for cpal's PipeWire backend. | **Happened:** cpal enables pipewire-rs `v0_3_53`, so `libspa` fails to compile on 22.04. Chose `debian:12` (glibc 2.36, PipeWire 0.3.65) over the 24.04 fallback (glibc 2.39) for the lower floor. Record the choice in `releasing.md`. |
| Godot treats the positional `.sonara` argument as something else. | Verify `OS.get_cmdline_args()` in an exported build early (task). If needed, use `Exec=sonara -- %f` in the desktop file, which makes it a user arg. |
| Bundled codec libraries pull in more `.so` files. | `package_linux.sh` walks `ldd` for `libsndfile`, copies everything not on an allowlist of system libraries (glibc, X11, pipewire, alsa, dbus, systemd), and fails if `ldd` on the bundle reports anything "not found". |
| An itch.io build updates through a draft page that can't be downloaded. | Butler upload only runs when the secret is set. Publishing the page is a manual step in `releasing.md`. |

## Open questions

None.
