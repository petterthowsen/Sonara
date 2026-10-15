# Beta Release — Requirements

## Problem

Sonara can only be run from a source checkout today. The developer builds the engine and starts it
by hand, then starts the Godot UI separately. Nothing is versioned, and logs are written into the
source tree. There's no About dialog, no way to find the logs, no installable package, and no way
for users to learn that a newer build exists. User files are spread out: projects sit flat in
`~/Documents/Sonara`, note maps are under `~/.config`, and regenerable caches are mixed in with
settings. Before a public beta, a user should be able to download one package, install it, open a
`.sonara` file from the file manager and get a working UI and engine, with no terminal.

## Scope

| | |
|---|---|
| Subsystem | both, plus packaging scripts and CI |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | yes: engine version/identity reply and graceful quit. `docs/subsystems/osc-protocol.md` is part of done |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no file format changes. Storage *locations* change (see REQ-001–REQ-004 and Open questions on migration) |

## Requirements

### Storage locations

### REQ-001 — User content under the Documents folder

The UI shall keep user-created content under `<Documents>/Sonara/`, where `<Documents>` is the
desktop's documents folder (the XDG user dir, e.g. `~/Dokumenter` on a Norwegian desktop). There
are three subfolders: `projects/`, `presets/` and `note_maps/`.

- **Acceptance:** a headless test with an overridden home shows the three default paths resolve
  under the documents folder. Live: saving a new project, a device preset and a note map puts
  each one in its subfolder.
- **Example:** File > Save on a new project named `demo` → the save dialog opens in
  `~/Documents/Sonara/projects/`, and the result is `demo.sonara` (with `demo.aichat/` beside it).

### REQ-002 — Settings under the config folder

The UI shall keep settings and internal state (`config.json`, `plugins.json`, `assets.json`,
device layouts, the startup project, AI conversations) under `$XDG_CONFIG_HOME/sonara/`, which
defaults to `~/.config/sonara/`.

- **Acceptance:** a test with `XDG_CONFIG_HOME` set to a scratch dir shows the config path follows
  it.

### REQ-003 — Regenerable data under the cache folder

The UI shall keep data that is rebuilt automatically when it's missing (asset scan caches and
temporary AI media files) under `$XDG_CACHE_HOME/sonara/`, which defaults to `~/.cache/sonara/`.

- **Acceptance:** deleting `~/.cache/sonara/` and restarting loses no settings or user content,
  and the caches are rebuilt.

### REQ-004 — Logs under the state folder

The engine and the UI shall write their logs under `$XDG_STATE_HOME/sonara/logs/`, which defaults
to `~/.local/state/sonara/logs/`, in separate `engine/` and `ui/` subfolders. Neither may write
logs relative to the working directory or into the install folder. Engine log rotation keeps its
current behaviour (5 newest sessions).

- **Acceptance:** start the installed build from a read-only working directory. Logs appear in the
  state folder and nothing is written elsewhere.

### Version

### REQ-005 — One version for the whole release

Every release shall carry one version number, shared by the UI and the engine. Each build shall
also know the git commit it was built from.

- **Acceptance:** the UI and engine of one build report identical version and commit strings.
- **Example:** `0.1.0-beta.1`, commit `380d9b0`.

### REQ-006 — Version check on connect

WHEN the UI connects to an engine, the UI shall learn the engine's version and protocol number.
IF the protocol number differs from its own, THEN the UI shall show a warning naming both versions
and stay connected.

- **Acceptance:** a headless test feeds a mismatched identity reply and sees the warning. Live: a
  matching engine shows no warning.

### Engine lifecycle

### REQ-007 — UI starts the engine

WHEN the UI starts and no engine answers on the OSC port within a short probe window, the UI shall
start the engine binary from its own install folder.

- **Acceptance:** live: launch the packaged UI with no engine running. The UI reaches "Connected"
  without a terminal.

### REQ-008 — Attach to a running engine

WHEN the UI starts and an engine already answers on the OSC port, the UI shall attach to that
engine and not start a second one.

- **Acceptance:** live: start `./run_engine.sh`, then the UI. Only one engine process exists.
  This is the current developer workflow and must keep working.

### REQ-009 — Restart the engine from the UI

WHILE the engine is disconnected, the UI shall offer a control to start (or restart) the engine.

- **Acceptance:** live: kill the engine. The engine panel offers Start Engine, and clicking it
  reconnects and re-syncs the open project.

### REQ-010 — Graceful engine shutdown

WHEN the UI quits, the UI shall stop the engine it started through a graceful quit. The engine
then runs its normal shutdown, which restores the PipeWire forced quantum. IF the engine is still
running after a timeout, THEN the UI shall force-kill it. An engine the UI attached to (REQ-008)
shall be left running.

- **Acceptance:** live: quit the UI. The engine process exits within the timeout, and
  `pw-metadata -n settings | grep force-quantum` shows the quantum restored.

### REQ-011 — No orphaned engine

IF the UI process dies without shutting down (crash or SIGKILL), THEN an engine the UI started
shall exit by itself within a few seconds.

- **Acceptance:** live: `kill -9` the UI. Within 5 s, no engine process remains and port 7000 is
  free.

### Help menu

### REQ-012 — About dialog

WHEN the user picks Help > About Sonara, the UI shall show a dialog containing: the app name and
icon, the UI version and commit, the engine version (or "not connected"), links to the GitHub
repository and the itch.io page that open in the browser, and a way to view the license and
third-party licenses.

- **Acceptance:** headless test that the dialog builds and shows the version strings. Live: both
  links open in the browser.

### REQ-013 — Open logs folder

WHEN the user picks Help > Open Logs Folder, the UI shall open the logs folder (REQ-004) in the
system file manager.

- **Acceptance:** live: the file manager opens on `~/.local/state/sonara/logs/`.

### Packaging and install

### REQ-014 — Release archive

Each release shall be published as one `sonara-<version>-linux-x86_64.tar.gz` holding the UI, the
engine, the plugin host, an install script, an uninstall script, the license files and a
desktop entry with an icon. It shall come with a SHA-256 checksum file.

- **Acceptance:** extract the archive on a clean Ubuntu 22.04 VM or container that has PipeWire
  and none of the build-only packages, run the UI from the extracted folder, and it reaches
  "Connected".

### REQ-015 — Install script

WHEN the user runs the install script without root, it shall install Sonara for the current user:
an application-menu entry with an icon, the `.sonara` file type registered to open in Sonara, and
a `sonara` command on the user's PATH. Running it again over an existing install shall upgrade it
in place without touching user content or settings.

- **Acceptance:** run it on a clean VM. Sonara shows in the app menu, and double-clicking a
  `.sonara` file in the file manager opens it.

### REQ-016 — Uninstall script

WHEN the user runs the uninstall script, it shall remove everything the install script added and
leave user content, settings and logs in place.

- **Acceptance:** after uninstall, the menu entry, file association and install folder are gone,
  and `~/Documents/Sonara` and `~/.config/sonara` are untouched.

### REQ-017 — Open a project from the command line

WHEN the UI is started with a `.sonara` path as an argument, the UI shall open that project and
not the startup project.

- **Acceptance:** `sonara ~/Documents/Sonara/projects/demo.sonara` opens `demo`.

### REQ-018 — Second launch

IF the UI is started while another Sonara UI is already running, THEN the new instance shall not
start a second engine. It shall tell the user that Sonara is already running and exit.

- **Acceptance:** live: with Sonara open, double-click a `.sonara` file. A message appears, the
  first instance is unaffected, and only one engine runs.

### Release automation

### REQ-019 — Automated release build

WHEN a version tag (`v*`) is pushed to GitHub, CI shall build the engine and the UI export on a
fixed old-LTS Linux base, assemble the release archive and checksum (REQ-014), and attach them to
a GitHub Release for that tag. CI shall also be startable by hand without a tag, in which case it
keeps the archive as a downloadable build artifact and publishes nothing.

- **Acceptance:** a manual run produces a downloadable archive that passes REQ-014.

### REQ-020 — itch.io upload

WHERE an itch.io API key is set up as a repository secret, CI shall also upload the archive to the
itch.io page on tagged releases.

- **Acceptance:** after a tagged release, the itch.io page lists the new version.

### Update check

### REQ-021 — Update notification

WHEN the UI starts, and the update check is enabled and hasn't run in the last 24 hours, the UI
shall ask GitHub for the latest release in the background. IF that release is newer than the
running version, THEN the UI shall show a non-blocking notice with the new version and a button
that opens the release page.

- **Acceptance:** headless test with a stubbed response (newer, same, older, network error). Only
  "newer" shows the notice, and a network error is logged quietly and shows nothing.

### REQ-022 — Update check setting and channel

The update check shall be a user setting. It shall only run in builds from the GitHub release
channel. itch.io builds (updated by the itch app) and development runs never check.

- **Acceptance:** a dev run (`godot --path Godot`) makes no request. Turning the setting off stops
  the request in a release build.

## Non-functional

- **Real-time safety:** unchanged. Nothing here runs on the audio callback.
- **Compatibility:** no automatic migration of files to the new locations. Existing pre-beta files
  are moved by hand (see Decisions). Pre-beta builds don't report a version, and the UI must treat
  that as "unknown version", not as a failure.
- **Startup:** launching the engine shall not delay the UI's first frame. The probe and launch run
  without blocking the main thread.

## Out of scope

- Downloading and installing updates from inside the app. REQ-021 only notifies; an in-place
  updater is a follow-up.
- AppImage, Flatpak, .deb and other package formats.
- Running more than one Sonara at a time (configurable OSC ports).
- Forwarding a file opened on a second launch to the running instance. REQ-018 only refuses.
- Windows and macOS.
- Code signing.

## Decisions

- **First beta version:** `0.1.0-beta.1`.
- **Moving existing files:** done by hand, with no migration code. Only the developer's machine
  has files in the old layout. The design lists the `mv` commands to run.
- **Repo is public.** The update check uses the public GitHub Releases API.
- **itch.io page:** `https://thowsenmedia.itch.io/sonara`. It's in draft mode for now, so the
  About link only works once it's published.
- **The update check is on by default** in release-channel builds and can be turned off in
  Settings.

## Open questions

None.
