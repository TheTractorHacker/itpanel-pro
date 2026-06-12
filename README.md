# ITFlow Quick Ticket

A lightweight tray/menu bar app that lets end users submit an ITFlow support
ticket — with an optional screenshot — in a few clicks, with no portal
login. Intended for mass deployment via RMM, with all connection settings
(ITFlow URL, API key, client ID, etc.) configured at install time so the
end user never sees credentials.

## Platforms

| Platform | Status | Docs |
|----------|--------|------|
| Windows  | Available | [Windows/README.md](Windows/README.md) |
| macOS    | Coming soon | [macOS/README.md](macOS/README.md) |
| Linux    | Coming soon | [Linux/README.md](Linux/README.md) |

## Requirements

Requires **[ITFlow MSP — From TheTractorHacker](https://github.com/TheTractorHacker/itflow) v2.11.32 or later** —
this is the version that added multipart/form-data attachment support to
`POST /api/v1/tickets` (used to submit the optional screenshot alongside the
ticket).

## Repo layout

- `Windows/` — tray app source (Python, pystray + tkinter), PyInstaller
  spec, branded icon, and TacticalRMM deploy script
- `installer/` — Inno Setup installer that prompts for per-install
  configuration and writes `config.json`
- `.github/workflows/` — CI that builds the Windows exe + installer and
  attaches them to GitHub releases
- `macOS/`, `Linux/` — placeholders for future ports
