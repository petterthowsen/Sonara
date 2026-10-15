#!/usr/bin/env bash
# Install Sonara for the current user (no root): the app in ~/.local/share/sonara, a `sonara`
# command in ~/.local/bin, an application-menu entry with an icon, and the .sonara file type.
# Run it again from a newer archive to upgrade in place. User content (~/Documents/Sonara) and
# settings (~/.config/sonara) are never touched. Remove everything with uninstall.sh.
#
# SONARA_DATA_HOME / SONARA_BIN_DIR override the install locations (for tests).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_HOME="${SONARA_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}"
BIN_DIR="${SONARA_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="$DATA_HOME/sonara"
APPS_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
MIME_DIR="$DATA_HOME/mime/packages"
MANIFEST="$APP_DIR/.manifest"

if [ ! -x "$SRC/Sonara.x86_64" ] || [ ! -x "$SRC/engine" ]; then
    echo "Run install.sh from the extracted Sonara archive (Sonara.x86_64 and engine not found in $SRC)." >&2
    exit 1
fi

# Everything under the archive folder except install.sh and the desktop-integration sources.
# uninstall.sh is installed too, so removing Sonara doesn't need the archive.
app_files() {
    (cd "$SRC" && find . -type f \
        ! -name install.sh ! -name sonara.desktop \
        ! -name sonara-mime.xml ! -name sonara.svg | sed 's|^\./||' | sort)
}

echo "Installing Sonara to $APP_DIR"
mkdir -p "$APP_DIR" "$APPS_DIR" "$ICON_DIR" "$MIME_DIR" "$BIN_DIR"

NEW_MANIFEST="$(mktemp)"
trap 'rm -f "$NEW_MANIFEST"' EXIT
app_files > "$NEW_MANIFEST"

# `install` writes a new inode, so upgrading while Sonara runs is safe: the running process keeps
# its old files.
while IFS= read -r rel; do
    mode=644
    [ -x "$SRC/$rel" ] && mode=755
    mkdir -p "$APP_DIR/$(dirname "$rel")"
    install -m "$mode" "$SRC/$rel" "$APP_DIR/$rel"
done < "$NEW_MANIFEST"

# Files of the previous version that this one no longer ships.
if [ -f "$MANIFEST" ]; then
    while IFS= read -r rel; do
        grep -qxF -- "$rel" "$NEW_MANIFEST" || rm -f -- "$APP_DIR/$rel"
    done < "$MANIFEST"
fi
cp "$NEW_MANIFEST" "$MANIFEST"
find "$APP_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

# The `sonara` command. The symlink resolves to the real executable, so the engine is found
# next to it.
ln -sfn "$APP_DIR/Sonara.x86_64" "$BIN_DIR/sonara"

# Desktop integration.
EXEC="$APP_DIR/Sonara.x86_64"
sed "s|@EXEC@|$EXEC|g" "$SRC/sonara.desktop" > "$APPS_DIR/sonara.desktop.new"
mv -f "$APPS_DIR/sonara.desktop.new" "$APPS_DIR/sonara.desktop"
install -m 644 "$SRC/sonara.svg" "$ICON_DIR/sonara.svg"
install -m 644 "$SRC/sonara-mime.xml" "$MIME_DIR/sonara.xml"

if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database "$DATA_HOME/mime" || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" || true
fi
if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default sonara.desktop application/x-sonara-project || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "$DATA_HOME/icons/hicolor" 2>/dev/null || true
fi

echo "To remove it again: $APP_DIR/uninstall.sh"
echo "Done. Start Sonara from the application menu, or run: sonara"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH, so the 'sonara' command needs the full path." ;;
esac
