# Releasing Sonara

How to cut a Linux release. The design is in [spec 046](specs/046-beta-release/design.md).

## Version

The root `VERSION` file is the only source of truth (e.g. `0.1.0-beta.1`). The engine reads it at
build time (`Engine/build.rs`). `scripts/stamp_version.sh` copies it into `Engine/Cargo.toml`,
`Engine/Cargo.lock`, `Godot/project.godot` and the gitignored `Godot/build_info.json`, and
`scripts/package_linux.sh` runs it for you.

Bump `BuildInfo.PROTOCOL` (Godot) and `build_info::PROTOCOL` (engine) together on any
incompatible OSC change. The UI warns when they differ.

## Cut a release

1. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [<version>] - <date>` and add a fresh empty
   `## [Unreleased]` above it. Update `VERSION`, then run `scripts/stamp_version.sh` and commit
   `CHANGELOG.md`, `VERSION`, `Engine/Cargo.toml`, `Engine/Cargo.lock` and `Godot/project.godot`.
   The workflow fails early when the changelog has no entry for `VERSION`
   (`scripts/changelog_section.sh <version>` checks it locally). The itch devlog is written from
   the same section.
2. If dependencies changed, run `scripts/gen_third_party_licenses.sh` (needs
   `cargo install cargo-about --locked --features cli`) and commit `THIRD_PARTY_LICENSES`.
3. Optional: build locally first with `scripts/package_linux.sh` and try
   `dist/sonara-<version>-linux-x86_64/Sonara.x86_64`.
4. Tag and push:
   ```bash
   git tag v$(cat VERSION)
   git push origin master v$(cat VERSION)
   ```
5. The **Release** workflow (`.github/workflows/release.yml`) checks that the tag matches `VERSION`,
   builds the archive, and creates a GitHub Release with
   `sonara-<version>-linux-x86_64.tar.gz` and its `.sha256`. The release notes are the
   `CHANGELOG.md` section for `VERSION`. Edit them on GitHub afterwards if you like.

To test the build without publishing anything, start the workflow by hand: Actions > Release > Run
workflow, or `gh workflow run release.yml --ref <branch>`. The archive is kept as a workflow
artifact for 14 days (`gh run download <run-id>`).

## Release channels

A file named `channel` next to the executable says where the build came from:

| `channel` | Built by | Update check |
|---|---|---|
| `github` | the GitHub Release archive | on (setting `updates/check_enabled`, at most once a day) |
| `itch` | the itch.io upload | off (the itch app updates it) |
| missing | dev runs (`godot --path Godot`, the editor) | off |

The update check reads `https://api.github.com/repos/petterthowsen/Sonara/releases` and offers
the newest non-draft release that's newer than the running version. Prereleases count.

## itch.io

The page is `https://thowsenmedia.itch.io/sonara` (draft until it's published).

1. Create an API key at itch.io > Settings > API keys.
2. Add it as the repository secret `BUTLER_API_KEY` (Settings > Secrets and variables > Actions).
3. On tagged releases, the workflow pushes the extracted folder with `channel` = `itch` to
   `thowsenmedia/sonara:linux` with `--userversion <VERSION>`. Without the secret, this step is
   skipped.
4. Publishing the page is a manual step on itch.io. The About dialog's itch.io link only works once
   the page is public.

## Build environment

CI builds in a `debian:12` container (glibc 2.36, PipeWire 0.3.65), so the binaries run on
Debian 12, Ubuntu 24.04, Linux Mint 22, Fedora 37 and newer, and on Arch. Ubuntu 22.04 (glibc 2.35,
PipeWire 0.3.48) can't be the base: cpal's PipeWire backend requires PipeWire 0.3.53 or newer at
build time (it enables the pipewire-rs feature `v0_3_53`), and the first CI run failed to compile
`libspa` there. The engine and plugin host carry a DT_RPATH of
`$ORIGIN/lib`, and the archive bundles libsndfile and its codec libraries (FLAC, vorbis, vorbisenc,
opus, ogg, mpg123, mp3lame). Everything else (glibc, ALSA, PipeWire, D-Bus, X11/Wayland) comes
from the user's system.

Moving the base forward (e.g. to `ubuntu:24.04`, glibc 2.39) raises the floor for users, so
only do it when a dependency needs it, and update this section and the README.

## Clean-machine check

Before announcing a release, try the archive on a clean Debian 12 VM (or Ubuntu 24.04) with PipeWire and none of
the build packages (spec 046 T-025):

1. Extract it and run `./Sonara.x86_64`. The UI starts its engine and reaches "Connected".
2. Run `./install.sh`. Sonara shows up in the app menu and `sonara` works in a new terminal.
3. Double-click a `.sonara` file. It opens in Sonara.
4. Run `./install.sh` again (upgrade). Sonara still works.
5. Run `~/.local/share/sonara/uninstall.sh`. The menu entry, file type and install folder are
   gone, and `~/Documents/Sonara` and `~/.config/sonara` are untouched.
