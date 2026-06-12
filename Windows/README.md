# ITFlow Quick Ticket (Windows)

A lightweight Windows tray app that lets end users submit an ITFlow support
ticket — with an optional full-screen screenshot — in a few clicks, with no
portal login.

## How it works

1. Runs in the system tray, starting on login.
2. Click the tray icon (or "New Ticket") to open a small popup:
   - Subject
   - Description
   - "Attach Screenshot" (captures the full screen, shows a thumbnail,
     can be retaken or removed)
3. "Submit" posts the ticket to ITFlow via the API, then the window closes
   after a brief success message.

## ITFlow API call

```
POST {itflow_base_url}/api/v1/tickets?api_key={api_key}
Content-Type: multipart/form-data

subject=...
details=...
client_id=...
contact_id=...      (optional)
priority=Medium
file=@screenshot.png (optional)
```

This requires ITFlow **v2.11.32 or later**, which added multipart/form-data
support (with an optional `file`/`files[]` attachment) to ticket creation —
see `agent` repo commit "API: support file attachments on ticket creation,
replies, and unify attachment storage". On older versions, ticket creation
only accepts a JSON body and has no attachment support.

The `api_key` is a **legacy API key** (Admin > API Keys in ITFlow). Note:

- It must be sent as a `?api_key=` query string parameter — for
  multipart/form-data POST bodies, the JSON-body fallback does not apply.
- The legacy key authenticates as the first active admin user (ITFlow does
  not currently scope legacy-key requests to `api_key_client_id`); the
  `client_id` field in `config.json` is what actually assigns the ticket
  to the right client.
- Treat the API key as a shared secret across all machines it's deployed
  to — anyone with it can create tickets for any client via this endpoint.

## Files

- `tray_app.py` — the application (pystray + tkinter + Pillow + requests)
- `config.json` — config template, deployed to
  `%ProgramData%\ITFlowQuickTicket\config.json`
- `itflow_quick_ticket.spec` — PyInstaller spec, produces a single
  windowed `.exe` (no console)
- `requirements.txt` — Python dependencies
- `deploy/deploy_quickticket.ps1` — TacticalRMM deployment script (silently
  runs the installer with per-client config)
- `assets/icon.ico` — branded tray/installer icon
- `../installer/ITFlowQuickTicket.iss` — Inno Setup script that builds the
  configurable installer
- `../.github/workflows/build.yml` — CI: builds the exe + installer on
  every push, and attaches both to a GitHub release for tags `v*`

## Getting a build

### Option A: GitHub Actions (no Windows machine needed)

Push a tag like `v1.0.0` (or just push to `master` / run the workflow
manually) and GitHub Actions will build on a `windows-latest` runner and
upload:

- `ITFlowQuickTicket.exe` — the bare tray app
- `ITFlowQuickTicketSetup.exe` — the full installer (recommended)

For tag pushes (`v*`), both files are also attached to a GitHub release.

### Option B: Build locally on Windows

```powershell
cd Windows
pip install -r requirements.txt
pyinstaller itflow_quick_ticket.spec
# Output: Windows\dist\ITFlowQuickTicket.exe

# Then build the installer (requires Inno Setup 6: https://jrsoftware.org/isdl.php)
cd ..\installer
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" ITFlowQuickTicket.iss
# Output: installer\Output\ITFlowQuickTicketSetup.exe
```

To rebrand the tray icon, replace `Windows/assets/icon.ico` (also used as
the installer icon) before building.

## Installer (`ITFlowQuickTicketSetup.exe`)

Running the installer prompts for the ITFlow connection settings (base URL,
API key, Client ID, Contact ID, Priority) on a dedicated wizard page, then:

- Installs `ITFlowQuickTicket.exe` to `C:\Program Files\ITFlowQuickTicket`
- Writes `C:\ProgramData\ITFlowQuickTicket\config.json` from the entered
  values
- Adds a shortcut to the All Users Startup folder so it launches on every
  login
- Offers to launch the app immediately

### Unattended / silent install

All wizard fields can be supplied as command-line parameters, which also
pre-fill the wizard if shown:

```
ITFlowQuickTicketSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /ItflowBaseUrl=https://itflow.foleyit.com ^
  /ApiKey=XXXXXXXXXXXXXXXX ^
  /ClientId=5 ^
  /ContactId=12 ^
  /Priority=Medium
```

## Deploying via TacticalRMM

1. Get `ITFlowQuickTicketSetup.exe` from a GitHub release (Option A above)
   and host it somewhere TacticalRMM can download it from — the direct
   release asset URL works fine, e.g.:

   ```
   https://github.com/TheTractorHacker/itflow-quick-ticket/releases/latest/download/ITFlowQuickTicketSetup.exe
   ```

2. In TacticalRMM, add `deploy/deploy_quickticket.ps1` as a script (type
   **PowerShell**, run as **System**), then set its **Script Arguments**
   to a single line per client, e.g.:

   ```
   -InstallerUrl "https://github.com/TheTractorHacker/itflow-quick-ticket/releases/latest/download/ITFlowQuickTicketSetup.exe" -ItflowBaseUrl "https://itflow.foleyit.com" -ApiKey "XXXXXXXXXXXXXXXX" -ClientId 5 -ContactId 12 -Priority "Medium"
   ```

   | Argument | Value |
   |----------|-------|
   | `-InstallerUrl`  | URL to `ITFlowQuickTicketSetup.exe` (above) |
   | `-ItflowBaseUrl` | e.g. `https://itflow.foleyit.com` |
   | `-ApiKey`        | API key from Admin > API Keys |
   | `-ClientId`      | ITFlow `client_id` for this client |
   | `-ContactId`     | (optional) ITFlow `contact_id`, omit or use `0` |
   | `-Priority`      | (optional) `Low` / `Medium` / `High` / `Critical`, default `Medium` |

   This downloads and silently runs the installer with those settings,
   which installs the app, writes `config.json`, and sets up the Startup
   shortcut — then launches the app for the current session if one exists.

### Upgrading

Running the same installer again (manually, or by re-running the
TacticalRMM script above) upgrades an existing install in place: it closes
the running tray app, replaces the exe, and restarts it — no uninstall
step needed. If you don't pass connection settings on an upgrade run, the
existing `config.json` values are kept automatically.

## Config reference (`config.json`)

| Field             | Required | Description                                  |
|-------------------|----------|-----------------------------------------------|
| `itflow_base_url` | yes      | e.g. `https://itflow.foleyit.com`              |
| `api_key`         | yes      | Legacy API key from Admin > API Keys           |
| `client_id`       | yes      | ITFlow `client_id` this install belongs to     |
| `contact_id`      | no       | ITFlow `contact_id` to attach to the ticket    |
| `priority`        | no       | `Low` / `Medium` / `High` / `Critical` (default `Medium`) |
