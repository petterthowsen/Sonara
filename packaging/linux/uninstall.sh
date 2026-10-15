#!/usr/bin/env bash
# Remove everything install.sh added. Your projects (~/Documents/Sonara), settings
# (~/.config/sonara), caches and logs are left in place.
#
# SONARA_DATA_HOME / SONARA_BIN_DIR override the locations (for tests).
set -euo pipefail

DATA_HOME="${SONARA_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}"
BIN_DIR="${SONARA_BIN_DIR:-$HOME/.local/bin}"
APP_DIR="$DATA_HOME/sonara"

main() {
echo "Removing Sonara from $APP_DIR"

# The command, only when it still points at our install.
if [ -L "$BIN_DIR/sonara" ] && [ "$(readlink "$BIN_DIR/sonara")" = "$APP_DIR/Sonara.x86_64" ]; then
    rm -f "$BIN_DIR/sonara"
fi

rm -f "$DATA_HOME/applications/sonara.desktop" \
      "$DATA_HOME/icons/hicolor/scalable/apps/sonara.svg" \
      "$DATA_HOME/mime/packages/sonara.xml"
rm -rf "$APP_DIR"

# The default-application line that install.sh's `xdg-mime default` wrote.
MIMEAPPS="${SONARA_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}/mimeapps.list"
if [ -f "$MIMEAPPS" ]; then
    sed -i '/^application\/x-sonara-project=sonara\.desktop;\?$/d' "$MIMEAPPS"
fi

if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database "$DATA_HOME/mime" || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DATA_HOME/applications" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "$DATA_HOME/icons/hicolor" 2>/dev/null || true
fi

echo "Done. Your projects and settings were not touched."
}

# Wrapped so deleting this very script (it lives in the install folder) is safe.
main "$@"
exit 0
