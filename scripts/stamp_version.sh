#!/usr/bin/env bash
# Stamp the release version (the root VERSION file) into everything that carries a copy of it:
#   Engine/Cargo.toml (+ the engine entry in Cargo.lock), Godot/project.godot config/version,
#   and Godot/build_info.json (gitignored; an exported Godot build can't read ../VERSION).
# The commit comes from $SONARA_COMMIT or `git rev-parse --short HEAD`, else "unknown".
# Run it before packaging; scripts/package_linux.sh does. Safe to run repeatedly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
if [ -z "$VERSION" ]; then
    echo "VERSION is empty" >&2
    exit 1
fi
COMMIT="${SONARA_COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)}"

# First `version = "..."` line of Cargo.toml is the [package] one.
sed -i "0,/^version = \".*\"/s//version = \"$VERSION\"/" "$ROOT/Engine/Cargo.toml"
# The engine package in Cargo.lock, so cargo doesn't rewrite the lock file on the next build.
sed -i "/^name = \"engine\"\$/{n;s/^version = .*/version = \"$VERSION\"/}" "$ROOT/Engine/Cargo.lock"
sed -i "s|^config/version=.*|config/version=\"$VERSION\"|" "$ROOT/Godot/project.godot"
printf '{\n\t"version": "%s",\n\t"commit": "%s"\n}\n' "$VERSION" "$COMMIT" > "$ROOT/Godot/build_info.json"

echo "Stamped version $VERSION (commit $COMMIT)"
