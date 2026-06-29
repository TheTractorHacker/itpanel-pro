#!/bin/bash
# ITPanel Pro - macOS installer
#
# Installs the prebuilt ITPanelPro.app to /Applications, writes
# /Library/Application Support/ITPanelPro/config.json, and registers
# a LaunchAgent so it starts in the menu bar for every user on login.
#
# Usage (run as root, e.g. via RMM):
#   ./install.sh <itflow_base_url> <api_key> <client_id> [contact_id] [priority]
#
# Example:
#   ./install.sh https://itflow.foleyit.com XXXXXXXXXXXXXXXX 5 12 Medium
#
# Re-running this script upgrades an existing install: it stops any running
# instance, replaces the .app, and (unless new values are passed) keeps the
# existing config.json. If a previous "ITFlow Quick Ticket" install is found,
# it is removed and its config.json is migrated.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ITPanelPro.app"
APP_DEST="/Applications/$APP_NAME"
CONFIG_DIR="/Library/Application Support/ITPanelPro"
CONFIG_PATH="$CONFIG_DIR/config.json"
LAUNCH_AGENT_DEST="/Library/LaunchAgents/com.foleyit.itpanelpro.plist"

OLD_APP_DEST="/Applications/ITFlowQuickTicket.app"
OLD_CONFIG_PATH="/Library/Application Support/ITFlowQuickTicket/config.json"
OLD_LAUNCH_AGENT_DEST="/Library/LaunchAgents/com.itflow.quickticket.plist"

ITFLOW_BASE_URL="${1:-}"
API_KEY="${2:-}"
CLIENT_ID="${3:-}"
CONTACT_ID="${4:-}"
PRIORITY="${5:-Medium}"

SRC_APP=""
if [ -d "$SCRIPT_DIR/dist/$APP_NAME" ]; then
    SRC_APP="$SCRIPT_DIR/dist/$APP_NAME"
elif [ -d "$SCRIPT_DIR/$APP_NAME" ]; then
    SRC_APP="$SCRIPT_DIR/$APP_NAME"
else
    echo "$APP_NAME not found next to install.sh (expected ./$APP_NAME or ./dist/$APP_NAME)" >&2
    exit 1
fi

# Stop any running instance so the bundle can be replaced cleanly.
pkill -f "$APP_DEST/Contents/MacOS/ITPanelPro" 2>/dev/null || true
launchctl bootout system/com.foleyit.itpanelpro 2>/dev/null || true

# Remove a previous "ITFlow Quick Ticket" install, migrating its config first.
if [ -d "$OLD_APP_DEST" ] || [ -f "$OLD_LAUNCH_AGENT_DEST" ]; then
    echo "Removing previous ITFlow Quick Ticket install..."
    pkill -f "$OLD_APP_DEST/Contents/MacOS/ITFlowQuickTicket" 2>/dev/null || true
    launchctl bootout system/com.itflow.quickticket 2>/dev/null || true
    rm -f "$OLD_LAUNCH_AGENT_DEST"
    rm -rf "$OLD_APP_DEST"
fi

if [ -f "$OLD_CONFIG_PATH" ] && [ ! -f "$CONFIG_PATH" ]; then
    mkdir -p "$CONFIG_DIR"
    cp "$OLD_CONFIG_PATH" "$CONFIG_PATH"
    rm -f "$OLD_CONFIG_PATH"
fi

rm -rf "$APP_DEST"
cp -R "$SRC_APP" "$APP_DEST"

mkdir -p "$CONFIG_DIR"

if [ -n "$ITFLOW_BASE_URL" ] && [ -n "$API_KEY" ] && [ -n "$CLIENT_ID" ]; then
    if [ -n "$CONTACT_ID" ]; then
        CONTACT_JSON="$CONTACT_ID"
    else
        CONTACT_JSON="null"
    fi

    python3 -c "
import json, sys
data = {
    'itflow_base_url': sys.argv[1],
    'api_key': sys.argv[2],
    'client_id': int(sys.argv[3]),
    'contact_id': int(sys.argv[4]) if sys.argv[4] != 'null' else None,
    'priority': sys.argv[5],
}
with open(sys.argv[6], 'w') as f:
    json.dump(data, f, indent=4)
    f.write('\n')
" "$ITFLOW_BASE_URL" "$API_KEY" "$CLIENT_ID" "$CONTACT_JSON" "$PRIORITY" "$CONFIG_PATH"
    chmod 600 "$CONFIG_PATH"
elif [ ! -f "$CONFIG_PATH" ]; then
    echo "No config.json exists and no connection settings were passed." >&2
    echo "Usage: $0 <itflow_base_url> <api_key> <client_id> [contact_id] [priority]" >&2
    exit 1
else
    echo "Keeping existing $CONFIG_PATH"
fi

install -m 644 "$SCRIPT_DIR/com.foleyit.itpanelpro.plist" "$LAUNCH_AGENT_DEST"
launchctl bootstrap system "$LAUNCH_AGENT_DEST" 2>/dev/null || true

echo "ITPanel Pro installed to $APP_DEST"
echo "It will start automatically in the menu bar for every user on login."
