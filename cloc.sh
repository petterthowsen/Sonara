#!/usr/bin/env bash
set -euo pipefail

# cloc helper: count only Rust (.rs) and Godot GDScript (.gd) code
# Directories scanned: Engine/ and Godot/
# Excludes: build artifacts and third-party addons

# Determine repo root (directory of this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v cloc >/dev/null 2>&1; then
    echo "Error: cloc not found. Install it (e.g., sudo apt install cloc) and retry." >&2
    exit 1
fi

cd "$SCRIPT_DIR"

# Only count Rust and GDScript files
INCLUDE_EXT="rs,gd"

# Ignore build outputs and external addons
EXCLUDE_DIRS="target,addons,.godot"

# Allow extra args to be passed through to cloc
EXTRA_ARGS=("$@")

exec cloc \
  --include-ext="$INCLUDE_EXT" \
  --exclude-dir="$EXCLUDE_DIRS" \
  "${EXTRA_ARGS[@]}" \
  Engine Godot


