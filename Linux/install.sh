#!/bin/bash
# ITPanel Pro - Linux installer
#
# Installs the prebuilt ITPanelPro binary to /opt/itpanel-pro,
# writes /etc/itpanel-pro/config.json, and registers it as an
# XDG autostart application for all users.
#
# Usage (run as root, e.g. via RMM):
#   ./install.sh <itflow_base_url> <api_key> <client_id> [contact_id] [priority]
#
# Example:
#   ./install.sh https://itflow.foleyit.com XXXXXXXXXXXXXXXX 5 12 Medium
#
# Re-running this script upgrades an existing install: it stops any running
# instance, replaces the binary, and (unless new values are passed) keeps the
# existing config.json. If a previous "ITFlow Quick Ticket" install is found,
# it is removed and its config.json is migrated.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/itpanel-pro"
CONFIG_DIR="/etc/itpanel-pro"
CONFIG_PATH="$CONFIG_DIR/config.json"
AUTOSTART_DIR="/etc/xdg/autostart"

OLD_INSTALL_DIR="/opt/itflow-quick-ticket"
OLD_CONFIG_PATH="/etc/itflow-quick-ticket/config.json"
OLD_AUTOSTART_FILE="$AUTOSTART_DIR/itflow-quick-ticket.desktop"

ITFLOW_BASE_URL="${1:-}"
API_KEY="${2:-}"
CLIENT_ID="${3:-}"
CONTACT_ID="${4:-}"
PRIORITY="${5:-Medium}"

# Stop any running instance so the binary can be replaced cleanly.
pkill -f "$INSTALL_DIR/ITPanelPro" 2>/dev/null || true

# Remove a previous "ITFlow Quick Ticket" install, migrating its config first.
if [ -d "$OLD_INSTALL_DIR" ] || [ -f "$OLD_AUTOSTART_FILE" ]; then
    echo "Removing previous ITFlow Quick Ticket install..."
    pkill -f "$OLD_INSTALL_DIR/ITFlowQuickTicket" 2>/dev/null || true
    rm -f "$OLD_AUTOSTART_FILE"
    rm -rf "$OLD_INSTALL_DIR"
fi

if [ -f "$OLD_CONFIG_PATH" ] && [ ! -f "$CONFIG_PATH" ]; then
    mkdir -p "$CONFIG_DIR"
    cp "$OLD_CONFIG_PATH" "$CONFIG_PATH"
    rm -rf "/etc/itflow-quick-ticket"
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$AUTOSTART_DIR"

if [ -f "$SCRIPT_DIR/dist/ITPanelPro" ]; then
    install -m 755 "$SCRIPT_DIR/dist/ITPanelPro" "$INSTALL_DIR/ITPanelPro"
elif [ -f "$SCRIPT_DIR/ITPanelPro" ]; then
    install -m 755 "$SCRIPT_DIR/ITPanelPro" "$INSTALL_DIR/ITPanelPro"
else
    echo "ITPanelPro binary not found next to install.sh (expected ./ITPanelPro or ./dist/ITPanelPro)" >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR/assets"
if [ -f "$SCRIPT_DIR/assets/icon.png" ]; then
    install -m 644 "$SCRIPT_DIR/assets/icon.png" "$INSTALL_DIR/assets/icon.png"
fi

install -m 644 "$SCRIPT_DIR/itpanel-pro.desktop" "$AUTOSTART_DIR/itpanel-pro.desktop"

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

echo "ITPanel Pro installed to $INSTALL_DIR"
echo "It will start automatically on next login for all users."

# Launch now for the current graphical session, if any.
if [ -n "${XDG_CURRENT_DESKTOP:-}" ] || [ -n "${DISPLAY:-}" ]; then
    nohup "$INSTALL_DIR/ITPanelPro" >/dev/null 2>&1 &
    disown || true
    echo "Launched ITPanelPro"
fi
