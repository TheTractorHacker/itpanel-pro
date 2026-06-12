# ITFlow Quick Ticket (macOS)

A menu bar app for macOS, equivalent to the [Windows tray app](../Windows),
letting end users submit an ITFlow support ticket — with an optional
screenshot — directly from the menu bar.

## Requirements

Requires **[ITFlow MSP — From TheTractorHacker](https://github.com/TheTractorHacker/itflow) v2.11.32 or later**
(multipart attachment support on `POST /api/v1/tickets`).

Screenshot capture uses Pillow's `ImageGrab.grab()`, which on macOS shells
out to the built-in `screencapture` tool (no extra install needed).

## Repo layout

- `tray_app.py` — entry point; shared UI/logic lives in `../common/core.py`
- `itflow_quick_ticket.spec` — PyInstaller spec, produces
  `ITFlowQuickTicket.app`
- `com.itflow.quickticket.plist` — LaunchAgent for autostart
- `install.sh` — installs the app to `/Applications`, writes
  `/Library/Application Support/ITFlowQuickTicket/config.json`, and
  registers the LaunchAgent
- `assets/` — branded icon

## Getting a build

### Option A: GitHub Actions

Push a tag like `v1.3.0` (or run the workflow manually) and GitHub Actions
builds on `macos-latest`, producing `ITFlowQuickTicket.app` (zipped) and
attaching it to the GitHub release.

### Option B: Build locally on macOS

```bash
cd macOS
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pyinstaller itflow_quick_ticket.spec
# app at dist/ITFlowQuickTicket.app
```

## Installing

```bash
sudo ./install.sh https://itflow.foleyit.com <API_KEY> <CLIENT_ID> [CONTACT_ID] [PRIORITY]
```

This installs `ITFlowQuickTicket.app` to `/Applications`, writes
`/Library/Application Support/ITFlowQuickTicket/config.json`, and registers
a LaunchAgent so the app appears in the menu bar for every user on login.

### Upgrading

Re-run `install.sh`. It stops any running instance, replaces the `.app`
bundle, and — if you omit the connection-setting arguments — keeps the
existing config.json.

### Gatekeeper note

Since this build isn't notarized/signed, first launch may require
right-click > Open, or running:

```bash
xattr -dr com.apple.quarantine /Applications/ITFlowQuickTicket.app
```

## Config reference (`config.json`)

Same fields as the [Windows app](../Windows/README.md#config-reference-configjson):
`itflow_base_url`, `api_key`, `client_id`, `contact_id` (optional, or
`null`), `priority`, plus the optional `include_system_info`,
`check_for_updates`, `accent_color`, and `branding_logo` fields.

Config is read from, in order:

1. `/Library/Application Support/ITFlowQuickTicket/config.json` (system-wide,
   written by `install.sh`)
2. `~/Library/Application Support/ITFlowQuickTicket/config.json` (per-user
   override)
3. `config.json` next to the app bundle

## Quick Tools notes

The tray menu's "Restart Print Service" tool runs
`launchctl stop/start org.cups.cupsd`, which normally requires root —
since the app runs in the user's menu bar this will usually show a
permissions error. The other Quick Tools (public IP, ping, list printers
via `lpstat`) work without elevated privileges.
