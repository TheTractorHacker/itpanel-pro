# ITFlow Quick Ticket (Linux)

A system tray app for Linux desktops, equivalent to the
[Windows tray app](../Windows), letting end users submit an ITFlow support
ticket — with an optional screenshot — directly from the tray.

## Requirements

Requires **[ITFlow MSP — From TheTractorHacker](https://github.com/TheTractorHacker/itflow) v2.11.32 or later**
(multipart attachment support on `POST /api/v1/tickets`).

The packaged binary is a self-contained PyInstaller build, but it still
depends on a few things being present on the target system:

- A system tray host that supports StatusNotifierItem/AppIndicator (e.g.
  GNOME's "AppIndicator and KStatusNotifierItem Support" extension — most
  other desktops like KDE/XFCE/Cinnamon support this out of the box).
- One of `scrot`, `grim`, `maim`, or `slurp` for the "Attach Screenshot"
  feature (used by Pillow's `ImageGrab.grab()`).

## Repo layout

- `tray_app.py` — entry point; shared UI/logic lives in `../common/core.py`
- `itflow_quick_ticket.spec` — PyInstaller spec, produces a single-file
  `ITFlowQuickTicket` binary
- `itflow-quick-ticket.desktop` — XDG autostart entry
- `install.sh` — installs the binary to `/opt/itflow-quick-ticket`, writes
  `/etc/itflow-quick-ticket/config.json`, and registers autostart
- `assets/` — branded icons

## Getting a build

### Option A: GitHub Actions

Push a tag like `v1.3.0` (or run the workflow manually) and GitHub Actions
builds on `ubuntu-latest`, producing `ITFlowQuickTicket` and attaching it
(plus a tarball with `install.sh` and assets) to the GitHub release.

### Option B: Build locally on Linux

```bash
cd Linux
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
pyinstaller itflow_quick_ticket.spec
# binary at dist/ITFlowQuickTicket
```

## Installing

```bash
sudo ./install.sh https://itflow.foleyit.com <API_KEY> <CLIENT_ID> [CONTACT_ID] [PRIORITY]
```

This installs the binary to `/opt/itflow-quick-ticket`, writes
`/etc/itflow-quick-ticket/config.json`, and adds an XDG autostart entry so
the tray app starts for every user on next login (and launches it
immediately if run from a graphical session).

### Upgrading

Re-run `install.sh`. It stops any running instance, replaces the binary,
and — if you omit the connection-setting arguments — keeps the existing
`/etc/itflow-quick-ticket/config.json`.

## Config reference (`config.json`)

Same fields as the [Windows app](../Windows/README.md#config-reference-configjson):
`itflow_base_url`, `api_key`, `client_id`, `contact_id` (optional, or
`null`), `priority`, plus the optional `include_system_info`,
`check_for_updates`, `accent_color`, and `branding_logo` fields.

Config is read from, in order:

1. `/etc/itflow-quick-ticket/config.json` (system-wide, written by `install.sh`)
2. `~/.config/itflow-quick-ticket/config.json` (per-user override)
3. `config.json` next to the binary

## Quick Tools notes

The tray menu's "Restart Print Service" tool runs `systemctl restart cups`.
Since the tray app runs as a normal user, this will normally fail with a
permissions error unless polkit/sudo is configured to allow it — the other
Quick Tools (public IP, ping, list printers via `lpstat`) work without
elevated privileges.
