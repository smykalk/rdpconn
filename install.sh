#!/usr/bin/env bash
set -euo pipefail

BIN_HOME="$HOME/.local/bin"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
SCRIPT_SOURCE="rdpconn.sh"
CONFIG_SOURCE="rdpconn.conf"
TARGET_SCRIPT="$BIN_HOME/rdpconn"
TARGET_CONFIG="$CONFIG_HOME/rdpconn.conf"

log() {
    printf '%s\n' "$*"
}

log "Using config home: $CONFIG_HOME"
log "Installing script to: $TARGET_SCRIPT"
mkdir -p "$BIN_HOME"
cp "$SCRIPT_SOURCE" "$TARGET_SCRIPT"
chmod u+x "$TARGET_SCRIPT"
log "Script installed and made executable"

log "Installing config to: $TARGET_CONFIG"
mkdir -p "$CONFIG_HOME"
if [ -e "$TARGET_CONFIG" ]; then
    log "Config already exists, skipping copy"
else
    cp "$CONFIG_SOURCE" "$TARGET_CONFIG"
    log "Config installed"
fi
