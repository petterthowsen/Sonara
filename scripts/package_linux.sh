#!/usr/bin/env bash
# Build the Linux release archive: dist/sonara-<version>-linux-x86_64.tar.gz and its .sha256.
#
#   scripts/package_linux.sh [--channel github|itch] [--godot /path/to/godot] [--skip-build]
#
# Steps: stamp the version, build the engine and plugin host with rpath $ORIGIN/lib, bundle
# libsndfile and the codec libraries it pulls in, export the Godot UI (pck embedded), add the
# install scripts, desktop files, licenses and the `channel` file, then tar and checksum.
# CI runs this same script (.github/workflows/release.yml).
#
# Needs: cargo and the engine's build prerequisites (AGENTS.md), godot 4.7 with its export
# templates installed, ldd, tar, sha256sum. Builds into dist/ and its own cargo target dir, so
# your dev Engine/target is not rebuilt with different flags. Set CARGO_BUILD_JOBS to limit load.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANNEL=github
GODOT="${GODOT:-godot}"
SKIP_BUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --godot) GODOT="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$CHANNEL" in github|itch) ;; *) echo "--channel must be github or itch" >&2; exit 2 ;; esac

"$ROOT/scripts/stamp_version.sh"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
NAME="sonara-$VERSION-linux-x86_64"
DIST="$ROOT/dist"
STAGE="$DIST/$NAME"
TARGET_DIR="${PACKAGE_TARGET_DIR:-$DIST/target}"
BIN_DIR="$TARGET_DIR/release"

# System libraries that every desktop Linux has and that must not be bundled: glibc, the
# toolchain runtime, X11/Wayland, PipeWire, ALSA, D-Bus and systemd.
SYSTEM_LIB_REGEX='^(linux-vdso|ld-linux[^ ]*|lib(c|m|dl|pthread|rt|util|resolv|nsl|gcc_s|mvec|stdc\+\+|asound|dbus-1|systemd|cap|udev|GL|EGL|drm|gbm|fontconfig|freetype|xkbcommon[a-z-]*|wayland[a-z-]*|pipewire-0\.3|spa-0\.2|xcb[a-z0-9-]*|X[A-Za-z0-9]*|bsd|md|gcrypt|gpg-error|lz4|lzma|zstd))\.so'

rm -rf "$STAGE" "$DIST/$NAME.tar.gz" "$DIST/$NAME.tar.gz.sha256"
mkdir -p "$STAGE/lib"

if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "==> Building the engine (rpath \$ORIGIN/lib) into $TARGET_DIR"
    (
        cd "$ROOT/Engine"
        export CARGO_TARGET_DIR="$TARGET_DIR"
        # --disable-new-dtags makes it a DT_RPATH, which also applies to the libraries the engine
        # loads (libsndfile finds its codecs in lib/ too); a DT_RUNPATH would not.
        export RUSTFLAGS="${RUSTFLAGS:-} -C link-arg=-Wl,--disable-new-dtags -C link-arg=-Wl,-rpath,\$ORIGIN/lib"
        cargo build --release --bins
    )
fi
for bin in engine plugin_host; do
    [ -x "$BIN_DIR/$bin" ] || { echo "Missing $BIN_DIR/$bin" >&2; exit 1; }
    install -m 755 "$BIN_DIR/$bin" "$STAGE/$bin"
done

echo "==> Bundling libsndfile and its codec libraries"
SNDFILE="$(ldd "$STAGE/engine" | awk '/libsndfile\.so/ { print $3; exit }')"
if [ -z "$SNDFILE" ] || [ ! -f "$SNDFILE" ]; then
    echo "The engine does not link libsndfile dynamically; nothing to bundle?" >&2
    exit 1
fi
# Breadth-first walk of ldd output, copying everything that is not a system library.
declare -A SEEN=()
QUEUE=("$SNDFILE")
while [ ${#QUEUE[@]} -gt 0 ]; do
    lib="${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
    base="$(basename "$lib")"
    [ -n "${SEEN[$base]:-}" ] && continue
    SEEN[$base]=1
    install -m 644 "$(readlink -f "$lib")" "$STAGE/lib/$base"
    while read -r dep; do
        dep_base="$(basename "$dep")"
        [[ "$dep_base" =~ $SYSTEM_LIB_REGEX ]] && continue
        QUEUE+=("$dep")
    done < <(ldd "$lib" | awk '/=> \// { print $3 }')
done
echo "    bundled: $(ls "$STAGE/lib" | tr '\n' ' ')"

echo "==> Checking that the bundle resolves"
MISSING="$(ldd "$STAGE/engine" "$STAGE/plugin_host" | grep 'not found' || true)"
if [ -n "$MISSING" ]; then
    echo "Unresolved libraries (add them to the bundle or to the system allowlist):" >&2
    echo "$MISSING" >&2
    exit 1
fi
# Every bundled library must resolve from lib/, not from the build machine's system copy.
for bundled in "$STAGE"/lib/*.so*; do
    name="$(basename "$bundled")"
    if ! ldd "$STAGE/engine" | grep -F "$name" | grep -q "$STAGE/lib/"; then
        echo "$name does not resolve from lib/ (rpath problem)" >&2
        exit 1
    fi
done

echo "==> Exporting the Godot UI"
"$GODOT" --headless --path "$ROOT/Godot" --import >/dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT/Godot" --export-release "Linux Release" "$STAGE/Sonara.x86_64"
[ -x "$STAGE/Sonara.x86_64" ] || { echo "Godot export produced no Sonara.x86_64" >&2; exit 1; }

echo "==> Assembling $NAME"
install -m 755 "$ROOT/packaging/linux/install.sh" "$STAGE/install.sh"
install -m 755 "$ROOT/packaging/linux/uninstall.sh" "$STAGE/uninstall.sh"
install -m 644 "$ROOT/packaging/linux/sonara.desktop" "$STAGE/sonara.desktop"
install -m 644 "$ROOT/packaging/linux/sonara-mime.xml" "$STAGE/sonara-mime.xml"
install -m 644 "$ROOT/Godot/assets/sonara/icons/favicon.svg" "$STAGE/sonara.svg"
install -m 644 "$ROOT/LICENSE" "$STAGE/LICENSE"
if [ -f "$ROOT/THIRD_PARTY_LICENSES" ]; then
    install -m 644 "$ROOT/THIRD_PARTY_LICENSES" "$STAGE/THIRD_PARTY_LICENSES"
else
    echo "WARNING: THIRD_PARTY_LICENSES is missing (run scripts/gen_third_party_licenses.sh)" >&2
fi
install -m 644 "$ROOT/VERSION" "$STAGE/VERSION"
printf '%s\n' "$CHANNEL" > "$STAGE/channel"

(
    cd "$DIST"
    tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$NAME.tar.gz" "$NAME"
    sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
)
echo "==> Done"
ls -l "$DIST/$NAME.tar.gz" "$DIST/$NAME.tar.gz.sha256"
