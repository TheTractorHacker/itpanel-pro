"""
ITPanel Pro - shared core

Platform-specific entry points (Windows/tray_app.py, Linux/tray_app.py,
macOS/tray_app.py) import this module and call run_app() with a list of
config file locations to check (in order of preference) and the path to
the tray/window icon image.

This module contains everything that is identical across platforms: config
loading, the ttk styling, the ticket popup window, the recent-tickets
window, offline queueing, update checks, the Quick Tools troubleshooting
menu, and the tray icon / event loop wiring.
"""

import getpass
import io
import json
import os
import platform
import shlex


def _api_headers(config: dict) -> dict:
    """Return auth headers for ITFlow API requests.

    Passes the api_key in a header rather than a URL query parameter
    so it is never written to web server access logs.
    """
    return {"X-Api-Key": config["api_key"]}
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import webbrowser
import zipfile

import requests
from PIL import Image, ImageDraw, ImageGrab, ImageTk
import pystray
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

APP_NAME = "ITPanel Pro"
VERSION = "2.1.9"
GITHUB_REPO = "TheTractorHacker/itpanel-pro"


def _notify(icon, message: str, title: str = APP_NAME, chat: bool = False):
    """Show a desktop notification.

    pystray's Icon.notify() (a legacy Shell_NotifyIcon balloon) is
    unreliable on Windows 11: it can silently no-op depending on a per-app
    toggle hidden behind right-clicking the tray icon itself - separate
    from, and overriding, the "Notification Area Icons" Control Panel
    setting most people know to check - with no exception raised either
    way. See https://github.com/moses-palmer/pystray/issues/112. Show a
    real toast via winotify (WinRT's toast API, via a bundled PowerShell
    call) on Windows instead; macOS/Linux already notify reliably through
    pystray's native backends there.

    chat: use the IM notification sound instead of the generic default
    (winotify toasts are silent unless a sound is explicitly set).
    """
    if platform.system() == "Windows":
        try:
            from winotify import Notification, audio
            toast = Notification(app_id=APP_NAME, title=title, msg=message)
            toast.set_audio(audio.IM if chat else audio.Default, loop=False)
            toast.show()
            return
        except Exception:
            pass  # fall through to the pystray balloon as a last resort
    try:
        icon.notify(message, title=title)
    except Exception:
        pass

ACCENT = "#2563eb"
ACCENT_DARK = "#1d4ed8"
BG = "#f4f6fb"
CARD_BG = "#ffffff"
BORDER = "#d7dce5"
TEXT_MUTED = "#5b6573"


def app_dir():
    """Directory containing the running script, or the PyInstaller binary."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    # .../<Platform>/tray_app.py -> .../<Platform>
    return os.path.dirname(os.path.abspath(sys.argv[0]))


def data_dir():
    """Per-user writable directory for the offline queue and ticket tracking."""
    system = platform.system()
    if system == "Windows":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")
        path = os.path.join(base, "ITPanelPro")
    elif system == "Darwin":
        path = os.path.expanduser("~/Library/Application Support/ITPanelPro")
    else:
        base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
        path = os.path.join(base, "itpanel-pro")
    os.makedirs(path, exist_ok=True)
    return path


def load_config(extra_paths):
    """Return the first config.json found among extra_paths, then app_dir()."""
    candidates = list(extra_paths) + [os.path.join(app_dir(), "config.json")]
    for path in candidates:
        if path and os.path.isfile(path):
            with open(path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            cfg["_source"] = path
            return cfg
    raise FileNotFoundError(
        "config.json not found. Checked:\n" + "\n".join(c for c in candidates if c)
    )


def build_tray_icon_image(icon_path, branding_logo=None):
    """Load the branding logo or bundled tray icon, or fall back to a drawn one."""
    candidate = branding_logo or icon_path
    if candidate and os.path.isfile(candidate):
        return Image.open(candidate)

    size = 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.ellipse([2, 2, size - 3, size - 3], fill=(37, 99, 235, 255))
    draw.rectangle([14, 22, size - 15, size - 22], fill=(255, 255, 255, 255))
    return img


_badged_icon_cache = {}  # id(base image) -> badged copy, built lazily once


def _tray_icon_with_badge(base_image):
    cached = _badged_icon_cache.get(id(base_image))
    if cached is not None:
        return cached
    img = base_image.convert("RGBA").copy()
    w, h = img.size
    r = max(8, w // 4)
    draw = ImageDraw.Draw(img)
    draw.ellipse([w - r, 0, w, r], fill=(220, 38, 38, 255), outline=(255, 255, 255, 255), width=2)
    _badged_icon_cache[id(base_image)] = img
    return img


def set_chat_unread(icon, unread: bool):
    """Toggle a small red badge on the tray icon for unread live-chat messages.

    Reads the un-badged image from icon._base_image (set once in run_app)
    rather than taking it as a parameter, so callers that only have `icon`
    (poll_ticket_chat, _on_chat_event) don't need to thread it through.
    """
    base = getattr(icon, "_base_image", None)
    if base is None:
        return
    try:
        icon.icon = _tray_icon_with_badge(base) if unread else base
    except Exception:
        pass


def _darken(hex_color, factor=0.82):
    hex_color = hex_color.lstrip("#")
    r, g, b = (int(hex_color[i:i + 2], 16) for i in (0, 2, 4))
    r, g, b = (max(0, min(255, int(c * factor))) for c in (r, g, b))
    return f"#{r:02x}{g:02x}{b:02x}"


def setup_style(root, accent=None):
    """Configure a clean, modern ttk theme shared by every window.

    accent: optional hex color (e.g. "#16a34a") to override the default
    ITFlow blue, for MSPs that want their own branding color.
    """
    accent_color = accent or ACCENT
    accent_dark = _darken(accent_color) if accent else ACCENT_DARK

    style = ttk.Style(root)
    for theme in ("clam",):
        try:
            style.theme_use(theme)
            break
        except tk.TclError:
            continue

    base_font = ("Segoe UI", 10)
    bold_font = ("Segoe UI", 10, "bold")
    title_font = ("Segoe UI Semibold", 13)

    root.option_add("*Font", base_font)

    style.configure(".", font=base_font, background=BG)
    style.configure("Card.TFrame", background=CARD_BG)
    style.configure("TFrame", background=BG)
    style.configure("TLabel", background=BG, foreground="#1f2533")
    style.configure("Card.TLabel", background=CARD_BG, foreground="#1f2533")
    style.configure("Title.TLabel", background=BG, font=title_font, foreground="#1f2533")
    style.configure("Muted.TLabel", background=BG, foreground=TEXT_MUTED)
    style.configure("Muted.Card.TLabel", background=CARD_BG, foreground=TEXT_MUTED)
    style.configure("FieldLabel.TLabel", background=BG, font=bold_font, foreground="#374151")
    style.configure("TCheckbutton", background=BG, foreground="#1f2533")

    style.configure(
        "TEntry",
        padding=8,
        relief="flat",
        bordercolor=BORDER,
        lightcolor=BORDER,
        darkcolor=BORDER,
        fieldbackground=CARD_BG,
    )
    style.map("TEntry", bordercolor=[("focus", accent_color)])

    style.configure(
        "TCombobox",
        padding=6,
        relief="flat",
        fieldbackground=CARD_BG,
        background=CARD_BG,
    )
    style.map("TCombobox", bordercolor=[("focus", accent_color)])

    style.configure(
        "Accent.TButton",
        font=bold_font,
        background=accent_color,
        foreground="white",
        borderwidth=0,
        padding=(12, 10),
    )
    style.map(
        "Accent.TButton",
        background=[("active", accent_dark), ("disabled", "#9db4e8")],
    )

    style.configure(
        "Secondary.TButton",
        font=base_font,
        background="#e9edf6",
        foreground="#1f2533",
        borderwidth=0,
        padding=(10, 8),
    )
    style.map(
        "Secondary.TButton",
        background=[("active", "#dbe2f0")],
    )

    return style


# ── System info ───────────────────────────────────────────────────────────

def gather_system_info():
    try:
        hostname = socket.gethostname()
    except Exception:
        hostname = "unknown"

    try:
        username = getpass.getuser()
    except Exception:
        username = "unknown"

    local_ip = "unknown"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            local_ip = s.getsockname()[0]
        finally:
            s.close()
    except Exception:
        pass

    return {
        "hostname": hostname,
        "os": f"{platform.system()} {platform.release()}",
        "username": username,
        "local_ip": local_ip,
    }


def format_system_info_block(info):
    return (
        "\n\n--- System Info (auto-attached) ---\n"
        f"Hostname: {info['hostname']}\n"
        f"OS: {info['os']}\n"
        f"User: {info['username']}\n"
        f"Local IP: {info['local_ip']}"
    )


# ── Quick Tools (troubleshooting) ───────────────────────────────────────────

def get_public_ip():
    try:
        resp = requests.get("https://api.ipify.org?format=json", timeout=8)
        resp.raise_for_status()
        return resp.json().get("ip", "Unknown")
    except Exception as exc:
        return f"Could not determine public IP: {exc}"


def ping_host(host="google.com"):
    count_flag = "-n" if platform.system() == "Windows" else "-c"
    try:
        result = subprocess.run(
            ["ping", count_flag, "4", host],
            capture_output=True, text=True, timeout=20,
        )
        return (result.stdout or result.stderr).strip()
    except FileNotFoundError:
        return "ping command not available on this system."
    except Exception as exc:
        return f"Error pinging {host}: {exc}"


def list_printers():
    system = platform.system()
    try:
        if system == "Windows":
            result = subprocess.run(
                ["powershell", "-NoProfile", "-Command",
                 "Get-Printer | Select-Object -ExpandProperty Name"],
                capture_output=True, text=True, timeout=20,
            )
            names = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        else:
            result = subprocess.run(["lpstat", "-p"], capture_output=True, text=True, timeout=20)
            names = []
            for line in result.stdout.splitlines():
                if line.startswith("printer "):
                    names.append(line.split()[1])

        if not names:
            return "No printers found."
        return "\n".join(names)
    except FileNotFoundError:
        return "Printer listing tool not available on this system."
    except Exception as exc:
        return f"Error listing printers: {exc}"


def restart_print_spooler():
    system = platform.system()
    try:
        if system == "Windows":
            subprocess.run(["net", "stop", "spooler"], capture_output=True, text=True, timeout=30, check=True)
            subprocess.run(["net", "start", "spooler"], capture_output=True, text=True, timeout=30, check=True)
            return "Print spooler restarted successfully."
        elif system == "Darwin":
            subprocess.run(["launchctl", "stop", "org.cups.cupsd"], capture_output=True, text=True, timeout=30, check=True)
            subprocess.run(["launchctl", "start", "org.cups.cupsd"], capture_output=True, text=True, timeout=30, check=True)
            return "Print service (CUPS) restarted successfully."
        else:
            subprocess.run(["systemctl", "restart", "cups"], capture_output=True, text=True, timeout=30, check=True)
            return "Print service (CUPS) restarted successfully."
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc)).strip()
        return (
            "Couldn't restart the print service - this usually requires "
            "administrator/root privileges.\n\n" + detail
        )
    except FileNotFoundError:
        return "Print service control tool not available on this system."
    except Exception as exc:
        return f"Error restarting print service: {exc}"


def tool_public_ip():
    return f"Your public IP address is:\n\n{get_public_ip()}"


def tool_ping():
    return "Pinging google.com...\n\n" + ping_host("google.com")


def tool_list_printers():
    return "Installed printers:\n\n" + list_printers()


def tool_restart_spooler():
    return restart_print_spooler()


def open_network_adapters():
    """Open the OS's network adapters/connections settings UI."""
    system = platform.system()
    try:
        if system == "Windows":
            subprocess.Popen(["control.exe", "ncpa.cpl"])
        elif system == "Darwin":
            subprocess.Popen(["open", "x-apple.systempreferences:com.apple.preference.network"])
        else:
            for cmd in (["nm-connection-editor"], ["gnome-control-center", "network"]):
                try:
                    subprocess.Popen(cmd)
                    return
                except FileNotFoundError:
                    continue
    except Exception:
        pass


def run_quick_tool(root, title, func):
    """Run a (possibly slow/blocking) tool function in a background thread
    and show its result in a message box on the Tk main thread."""
    def worker():
        try:
            result = func()
        except Exception as exc:
            result = f"Error: {exc}"
        root.after(0, lambda: messagebox.showinfo(title, result))
    threading.Thread(target=worker, daemon=True).start()


# ── Offline queue ────────────────────────────────────────────────────────

def queue_dir():
    path = os.path.join(data_dir(), "queue")
    os.makedirs(path, exist_ok=True)
    return path


def save_to_queue(data, files_payload):
    """Persist a ticket submission to retry later.

    files_payload: list of (field_name, filename, bytes, content_type)
    """
    item_dir = os.path.join(queue_dir(), str(int(time.time() * 1000)))
    os.makedirs(item_dir, exist_ok=True)

    with open(os.path.join(item_dir, "payload.json"), "w", encoding="utf-8") as f:
        json.dump(data, f)

    manifest = []
    for i, (field_name, filename, content, content_type) in enumerate(files_payload):
        stored_as = f"file_{i}_{filename}"
        with open(os.path.join(item_dir, stored_as), "wb") as f:
            f.write(content)
        manifest.append({
            "field": field_name, "filename": filename,
            "stored_as": stored_as, "content_type": content_type,
        })

    with open(os.path.join(item_dir, "files.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f)


def flush_queue(config):
    """Try to resend queued tickets. Stops at the first failure (assumed
    still offline). Returns the number successfully sent."""
    qdir = queue_dir()
    sent = 0
    for name in sorted(os.listdir(qdir)):
        item_dir = os.path.join(qdir, name)
        payload_path = os.path.join(item_dir, "payload.json")
        if not os.path.isfile(payload_path):
            continue

        try:
            with open(payload_path, "r", encoding="utf-8") as f:
                data = json.load(f)

            files = None
            manifest_path = os.path.join(item_dir, "files.json")
            if os.path.isfile(manifest_path):
                with open(manifest_path, "r", encoding="utf-8") as f:
                    manifest = json.load(f)
                if manifest:
                    files = []
                    for entry in manifest:
                        with open(os.path.join(item_dir, entry["stored_as"]), "rb") as fh:
                            files.append((entry["field"], (entry["filename"], fh.read(), entry["content_type"])))

            base_url = config["itflow_base_url"].rstrip("/")
            resp = requests.post(
                f"{base_url}/api/v1/tickets",
                headers=_api_headers(config),
                data=data,
                files=files,
                timeout=30,
            )
            resp.raise_for_status()
            result = resp.json()
            if "id" in result:
                track_new_ticket(result["id"], result.get("number", "?"), data.get("subject", ""))

            shutil.rmtree(item_dir, ignore_errors=True)
            sent += 1
        except Exception:
            break

    return sent


# ── Ticket tracking (for status-change notifications) ──────────────────────

def tracked_tickets_path():
    return os.path.join(data_dir(), "tracked_tickets.json")


def load_tracked_tickets():
    path = tracked_tickets_path()
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return []
    return []


def save_tracked_tickets(tickets):
    with open(tracked_tickets_path(), "w", encoding="utf-8") as f:
        json.dump(tickets, f)


def track_new_ticket(ticket_id, number, subject, status="New"):
    tickets = load_tracked_tickets()
    tickets.append({"id": ticket_id, "number": number, "subject": subject, "status": status, "last_chat_id": 0})
    save_tracked_tickets(tickets[-20:])
    # Start an instant chat listener for this ticket right away, instead of
    # waiting for the next background_loop reconciliation pass.
    try:
        _ensure_chat_listeners()
    except Exception:
        pass


def poll_ticket_updates(config, icon):
    """Check tracked tickets for status changes and show a notification."""
    tickets = load_tracked_tickets()
    if not tickets:
        return

    base_url = config["itflow_base_url"].rstrip("/")
    changed = False
    for t in tickets:
        try:
            resp = requests.get(
                f"{base_url}/api/v1/tickets/{t['id']}",
                headers=_api_headers(config),
                timeout=15,
            )
            resp.raise_for_status()
            new_status = resp.json().get("status", t["status"])
            if new_status and new_status != t["status"]:
                _notify(
                    icon,
                    f"Ticket #{t['number']} \"{t['subject']}\" is now {new_status}",
                    title="ITFlow Ticket Update",
                )
                t["status"] = new_status
                changed = True
        except Exception:
            continue

    if changed:
        save_tracked_tickets(tickets)


def poll_ticket_chat(config, icon):
    """Check tracked tickets for new agent chat messages and notify."""
    tickets = load_tracked_tickets()
    if not tickets:
        return

    base_url = config["itflow_base_url"].rstrip("/")
    changed = False
    for t in tickets:
        last_chat_id = t.get("last_chat_id", 0)
        try:
            resp = requests.get(
                f"{base_url}/api/v1/tickets/{t['id']}/chat",
                params={"since_id": last_chat_id},
                headers=_api_headers(config),
                timeout=15,
            )
            if resp.status_code == 403:
                # Live chat module disabled on the server - nothing to do.
                continue
            resp.raise_for_status()
            messages = resp.json().get("data", [])
        except Exception:
            continue

        if not messages:
            continue

        agent_messages = [m for m in messages if m.get("sender_type") == "agent"]
        if agent_messages:
            if len(agent_messages) == 1:
                body = agent_messages[0].get("message", "")
            else:
                body = f"{len(agent_messages)} new messages"
            _notify(icon, f"Ticket #{t['number']}: {body}", title="ITFlow Live Chat", chat=True)
            set_chat_unread(icon, True)

        t["last_chat_id"] = messages[-1]["id"]
        changed = True

    if changed:
        save_tracked_tickets(tickets)


# ── Live chat (SSE) ──────────────────────────────────────────────────────
#
# poll_ticket_chat() above is a 300s safety-net fallback. The functions below
# subscribe to the same server-sent-events stream the web UI uses (backed by
# Redis pub/sub - see includes/sse_ticket_chat_stream.php) so new messages
# arrive within ~1-2 seconds instead of waiting for the next poll.

def _sse_chat_listen(config, ticket_id, on_message, stop_event):
    """Reconnecting SSE listener for one ticket's live chat channel.

    Calls on_message(event_dict) for every "chat" event received. Runs until
    stop_event is set. The server intentionally closes the connection every
    ~60s (see sse_ticket_chat_stream.php's $max_runtime) so a short pause and
    reconnect on any disconnect is the expected steady state, not an error.
    """
    base_url = config["itflow_base_url"].rstrip("/")
    url = f"{base_url}/api/v1/tickets/{ticket_id}/chat"
    params = {"stream": 1}

    while not stop_event.is_set():
        try:
            resp = requests.get(url, params=params, headers=_api_headers(config), stream=True, timeout=(10, 75))
            if resp.status_code == 403:
                # Live chat module disabled server-side - no point retrying.
                return
            if resp.status_code != 200:
                stop_event.wait(15)
                continue

            event_name = None
            for line in resp.iter_lines(decode_unicode=True):
                if stop_event.is_set():
                    return
                if line is None or line == "":
                    event_name = None
                    continue
                if line.startswith("event:"):
                    event_name = line[len("event:"):].strip()
                elif line.startswith("data:") and event_name == "chat":
                    try:
                        on_message(json.loads(line[len("data:"):].strip()))
                    except Exception:
                        pass
        except Exception:
            pass

        stop_event.wait(2)


_chat_listeners = {}  # ticket_id -> threading.Event (set to stop)
_chat_listener_config = None
_chat_listener_icon = None


def _on_chat_event(icon, tracked_ticket, data):
    if data.get("sender_type") == "agent":
        _notify(
            icon,
            f"Ticket #{tracked_ticket['number']}: {data.get('message', '')}",
            title="ITFlow Live Chat",
            chat=True,
        )
        set_chat_unread(icon, True)

    # Keep last_chat_id in sync so the poll_ticket_chat() fallback doesn't
    # re-notify for messages already delivered live.
    chat_id = data.get("chat_id", 0)
    if not chat_id:
        return
    tickets = load_tracked_tickets()
    changed = False
    for t in tickets:
        if t["id"] == tracked_ticket["id"] and chat_id > t.get("last_chat_id", 0):
            t["last_chat_id"] = chat_id
            changed = True
    if changed:
        save_tracked_tickets(tickets)


def _ensure_chat_listeners():
    """Start an SSE listener thread for every tracked ticket that doesn't
    already have one, and stop listeners for tickets no longer tracked.

    Safe to call repeatedly (from the background loop, and immediately after
    track_new_ticket()) - it's a no-op for tickets already covered.
    """
    config = _chat_listener_config
    icon = _chat_listener_icon
    if not config or not icon:
        return

    tickets = load_tracked_tickets()
    tracked_ids = {t["id"] for t in tickets}

    for ticket_id in list(_chat_listeners):
        if ticket_id not in tracked_ids:
            _chat_listeners.pop(ticket_id).set()

    for t in tickets:
        ticket_id = t["id"]
        if ticket_id in _chat_listeners:
            continue
        stop_event = threading.Event()
        threading.Thread(
            target=_sse_chat_listen,
            args=(config, ticket_id, lambda data, t=t: _on_chat_event(icon, t, data), stop_event),
            daemon=True,
        ).start()
        _chat_listeners[ticket_id] = stop_event


# ── Update check ─────────────────────────────────────────────────────────

def _version_tuple(v):
    parts = []
    for p in v.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def check_for_update():
    """Return (latest_version, release_dict) if a newer release is available."""
    try:
        resp = requests.get(
            f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest", timeout=10
        )
        resp.raise_for_status()
        data = resp.json()
        tag = (data.get("tag_name") or "").lstrip("v")
        if tag and _version_tuple(tag) > _version_tuple(VERSION):
            return tag, data
    except Exception:
        return None
    return None


# ── Ticket entry window ─────────────────────────────────────────────────────

class TicketWindow:
    """The popup ticket-entry window. One instance reused per open."""

    def __init__(self, root, config, icon_path=None):
        self.root = root
        self.config = config
        self.icon_path = icon_path
        self.screenshot_bytes = None
        self.attached_file_path = None
        self.categories = []
        self.selected_category_id = 0
        self.window = None
        self._header_img = None
        self._thumb_image = None

    def show(self):
        if self.window is not None and self.window.winfo_exists():
            self.window.deiconify()
            self.window.lift()
            self.window.focus_force()
            return

        self.screenshot_bytes = None
        self.attached_file_path = None
        self.selected_category_id = 0

        win = tk.Toplevel(self.root)
        win.title(APP_NAME)
        win.resizable(False, False)
        win.configure(bg=BG)
        win.attributes("-topmost", True)
        win.protocol("WM_DELETE_WINDOW", win.destroy)
        if self.icon_path and os.path.isfile(self.icon_path):
            try:
                win.iconbitmap(self.icon_path)
            except tk.TclError:
                pass
        self.window = win

        outer = ttk.Frame(win, padding=20, style="TFrame")
        outer.pack(fill="both", expand=True)

        # Header: icon + title
        header = ttk.Frame(outer, style="TFrame")
        header.pack(fill="x", pady=(0, 16))

        if self.icon_path and os.path.isfile(self.icon_path):
            try:
                img = Image.open(self.icon_path)
                img = img.resize((32, 32))
                self._header_img = ImageTk.PhotoImage(img)
                ttk.Label(header, image=self._header_img, style="TLabel").pack(side="left", padx=(0, 10))
            except Exception:
                pass

        title_box = ttk.Frame(header, style="TFrame")
        title_box.pack(side="left", fill="x", expand=True)
        ttk.Label(title_box, text="New Support Ticket", style="Title.TLabel").pack(anchor="w")
        ttk.Label(title_box, text="We'll get back to you as soon as possible", style="Muted.TLabel").pack(anchor="w")

        # Subject
        ttk.Label(outer, text="Subject", style="FieldLabel.TLabel").pack(anchor="w", pady=(0, 4))
        self.subject_entry = ttk.Entry(outer, width=46)
        self.subject_entry.pack(fill="x", pady=(0, 14))

        # Category (only shown if the server has ticket categories configured)
        if self.categories:
            ttk.Label(outer, text="Category", style="FieldLabel.TLabel").pack(anchor="w", pady=(0, 4))
            self.category_var = tk.StringVar(value="Uncategorized")
            category_names = ["Uncategorized"] + [c["name"] for c in self.categories]
            self.category_combo = ttk.Combobox(
                outer, textvariable=self.category_var, values=category_names,
                state="readonly", width=43,
            )
            self.category_combo.pack(fill="x", pady=(0, 14))
            self.category_combo.bind("<<ComboboxSelected>>", self._on_category_selected)

        # Description
        ttk.Label(outer, text="Describe the issue", style="FieldLabel.TLabel").pack(anchor="w", pady=(0, 4))
        text_frame = tk.Frame(outer, bg=BORDER, padx=1, pady=1)
        text_frame.pack(fill="x", pady=(0, 14))
        self.details_text = tk.Text(
            text_frame,
            width=46,
            height=7,
            relief="flat",
            bg=CARD_BG,
            fg="#1f2533",
            insertbackground="#1f2533",
            font=("Segoe UI", 10),
            padx=8,
            pady=8,
            wrap="word",
        )
        self.details_text.pack(fill="both", expand=True)

        # System info checkbox
        self.include_sysinfo_var = tk.BooleanVar(value=self.config.get("include_system_info", True))
        ttk.Checkbutton(
            outer, text="Include system info (helps us diagnose faster)",
            variable=self.include_sysinfo_var,
        ).pack(anchor="w", pady=(0, 10))

        # Screenshot preview area
        preview_frame = tk.Frame(outer, bg=CARD_BG, highlightbackground=BORDER, highlightthickness=1)
        preview_frame.pack(fill="x", pady=(0, 10))
        self.preview_label = tk.Label(
            preview_frame,
            text="No screenshot attached",
            fg=TEXT_MUTED,
            bg=CARD_BG,
            font=("Segoe UI", 9),
            height=6,
        )
        self.preview_label.pack(fill="both", expand=True, padx=2, pady=2)

        # Screenshot buttons
        btn_row = ttk.Frame(outer, style="TFrame")
        btn_row.pack(fill="x", pady=(0, 10))
        btn_row.columnconfigure(0, weight=1)
        btn_row.columnconfigure(1, weight=1)

        self.screenshot_btn = ttk.Button(
            btn_row, text="Attach Screenshot", style="Secondary.TButton", command=self.take_screenshot
        )
        self.screenshot_btn.grid(row=0, column=0, sticky="we", padx=(0, 6))

        self.remove_btn = ttk.Button(
            btn_row, text="Remove Screenshot", style="Secondary.TButton", command=self.remove_screenshot, state="disabled"
        )
        self.remove_btn.grid(row=0, column=1, sticky="we", padx=(6, 0))

        # File attachment
        file_row = ttk.Frame(outer, style="TFrame")
        file_row.pack(fill="x", pady=(0, 14))
        self.attach_file_btn = ttk.Button(
            file_row, text="Attach File", style="Secondary.TButton", command=self.choose_file
        )
        self.attach_file_btn.pack(side="left")
        self.file_label = ttk.Label(file_row, text="No file attached", style="Muted.TLabel")
        self.file_label.pack(side="left", padx=(10, 0))

        # Status + submit
        self.status_label = ttk.Label(outer, text="", style="Muted.TLabel", wraplength=380)
        self.status_label.pack(fill="x", pady=(0, 8))

        self.submit_btn = ttk.Button(outer, text="Submit Ticket", style="Accent.TButton", command=self.submit)
        self.submit_btn.pack(fill="x")

        win.update_idletasks()
        # Center on screen
        w, h = win.winfo_width(), win.winfo_height()
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        win.geometry(f"+{(sw - w) // 2}+{(sh - h) // 2}")

        self.subject_entry.focus_set()

    def _on_category_selected(self, event=None):
        name = self.category_var.get()
        self.selected_category_id = next(
            (c["id"] for c in self.categories if c["name"] == name), 0
        )

    def choose_file(self):
        path = filedialog.askopenfilename(parent=self.window, title="Select a file to attach")
        if path:
            self.attached_file_path = path
            self.file_label.configure(text=os.path.basename(path))
            self.attach_file_btn.configure(text="Change File")

    def take_screenshot(self):
        # Hide our window so it isn't part of the capture
        self.window.withdraw()
        self.window.update()
        time.sleep(0.3)

        try:
            screenshot = ImageGrab.grab()
        except Exception as exc:
            self.window.deiconify()
            self.window.lift()
            messagebox.showerror(
                APP_NAME,
                "Couldn't capture a screenshot on this system:\n" + str(exc),
            )
            return
        finally:
            self.window.deiconify()
            self.window.lift()

        buf = io.BytesIO()
        screenshot.save(buf, format="PNG")
        self.screenshot_bytes = buf.getvalue()

        thumb = screenshot.copy()
        thumb.thumbnail((300, 140))
        self._thumb_image = ImageTk.PhotoImage(thumb)
        self.preview_label.configure(image=self._thumb_image, text="")

        self.screenshot_btn.configure(text="Retake Screenshot")
        self.remove_btn.configure(state="normal")

    def remove_screenshot(self):
        self.screenshot_bytes = None
        self._thumb_image = None
        self.preview_label.configure(image="", text="No screenshot attached")
        self.screenshot_btn.configure(text="Attach Screenshot")
        self.remove_btn.configure(state="disabled")

    def submit(self):
        subject = self.subject_entry.get().strip()
        details = self.details_text.get("1.0", "end").strip()

        if not subject:
            messagebox.showwarning(APP_NAME, "Please enter a subject.")
            return

        self.submit_btn.configure(state="disabled", text="Submitting...")
        self.status_label.configure(text="", style="Muted.TLabel")
        self.window.update()

        threading.Thread(
            target=self._submit_worker, args=(subject, details), daemon=True
        ).start()

    def _submit_worker(self, subject, details):
        try:
            result = self._send_ticket(subject, details)
            self.window.after(0, self._submit_success, result)
        except Exception as exc:
            self.window.after(0, self._submit_error, str(exc))

    def _send_ticket(self, subject, details):
        cfg = self.config
        base_url = cfg["itflow_base_url"].rstrip("/")
        url = f"{base_url}/api/v1/tickets"

        if self.include_sysinfo_var.get():
            details = details + format_system_info_block(gather_system_info())

        data = {
            "subject": subject,
            "details": details,
            "client_id": cfg["client_id"],
            "priority": cfg.get("priority", "Medium"),
            "hostname": socket.gethostname(),
        }
        if cfg.get("contact_id"):
            data["contact_id"] = cfg["contact_id"]
        if self.selected_category_id:
            data["category_id"] = self.selected_category_id

        files = []
        if self.screenshot_bytes:
            files.append(("files[]", ("screenshot.png", self.screenshot_bytes, "image/png")))
        if self.attached_file_path:
            with open(self.attached_file_path, "rb") as f:
                file_bytes = f.read()
            files.append(("files[]", (os.path.basename(self.attached_file_path), file_bytes, "application/octet-stream")))

        try:
            resp = requests.post(
                url,
                headers=_api_headers(cfg),
                data=data,
                files=files or None,
                timeout=30,
            )
            resp.raise_for_status()
            result = resp.json()
        except requests.exceptions.RequestException:
            files_payload = [(field, f[0], f[1], f[2]) for field, f in files]
            save_to_queue(data, files_payload)
            return {"queued": True}

        if "id" in result:
            track_new_ticket(result["id"], result.get("number", "?"), subject)
        return result

    def _submit_success(self, result=None):
        if result and result.get("queued"):
            self.status_label.configure(
                text="No connection right now - your ticket was saved and will be "
                     "submitted automatically once you're back online.",
                style="Card.TLabel", foreground="#b45309",
            )
        else:
            self.status_label.configure(text="Ticket submitted successfully!", style="Card.TLabel", foreground="#15803d")
        self.window.update()
        self.window.after(1800, self._close)

    def _submit_error(self, message):
        self.submit_btn.configure(state="normal", text="Submit Ticket")
        self.status_label.configure(text=f"Failed to submit: {message}", style="Card.TLabel", foreground="#b91c1c")

    def _close(self):
        if self.window is not None:
            self.window.destroy()
            self.window = None
        self.screenshot_bytes = None
        self.attached_file_path = None


# ── Recent tickets window ───────────────────────────────────────────────────

class RecentTicketsWindow:
    """Shows the most recent tickets for this client/contact."""

    def __init__(self, root, config, chat_window=None):
        self.root = root
        self.config = config
        self.chat_window = chat_window
        self.window = None
        self.tree = None
        self.status_label = None
        self.tickets_by_id = {}

    def show(self):
        if self.window is not None and self.window.winfo_exists():
            self.window.deiconify()
            self.window.lift()
            self.window.focus_force()
            self.refresh()
            return

        win = tk.Toplevel(self.root)
        win.title(f"{APP_NAME} - My Recent Tickets")
        win.configure(bg=BG)
        win.attributes("-topmost", True)
        win.protocol("WM_DELETE_WINDOW", win.destroy)
        self.window = win

        outer = ttk.Frame(win, padding=16, style="TFrame")
        outer.pack(fill="both", expand=True)

        ttk.Label(outer, text="My Recent Tickets", style="Title.TLabel").pack(anchor="w", pady=(0, 10))

        columns = ("number", "subject", "status", "created")
        self.tree = ttk.Treeview(outer, columns=columns, show="headings", height=10)
        self.tree.heading("number", text="#")
        self.tree.heading("subject", text="Subject")
        self.tree.heading("status", text="Status")
        self.tree.heading("created", text="Created")
        self.tree.column("number", width=60, anchor="center")
        self.tree.column("subject", width=280)
        self.tree.column("status", width=110, anchor="center")
        self.tree.column("created", width=140, anchor="center")
        self.tree.pack(fill="both", expand=True)
        self.tree.bind("<Double-1>", self._on_double_click)

        self.status_label = ttk.Label(outer, text="Loading... (double-click a ticket to open live chat)", style="Muted.TLabel")
        self.status_label.pack(anchor="w", pady=(8, 0))

        win.update_idletasks()
        w, h = 640, 380
        sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
        win.geometry(f"{w}x{h}+{(sw - w) // 2}+{(sh - h) // 2}")

        self.refresh()

    def refresh(self):
        self.status_label.configure(text="Loading...")
        threading.Thread(target=self._fetch, daemon=True).start()

    def _fetch(self):
        cfg = self.config
        base_url = cfg["itflow_base_url"].rstrip("/")
        params = {
            "api_key": cfg["api_key"],
            "status": "all",
            "limit": 15,
            "client_id": cfg["client_id"],
        }
        if cfg.get("contact_id"):
            params["contact_id"] = cfg["contact_id"]

        try:
            resp = requests.get(f"{base_url}/api/v1/tickets", params=params, timeout=20)
            resp.raise_for_status()
            tickets = resp.json().get("data", [])
        except Exception as exc:
            self.root.after(0, self._show_error, str(exc))
            return

        self.root.after(0, self._populate, tickets)

    def _populate(self, tickets):
        for row in self.tree.get_children():
            self.tree.delete(row)
        self.tickets_by_id = {}
        for t in tickets:
            ticket_id = t.get("id")
            self.tickets_by_id[str(ticket_id)] = t
            self.tree.insert("", "end", iid=str(ticket_id), values=(
                t.get("number"), t.get("subject"), t.get("status"), (t.get("created_at") or "")[:16],
            ))
        self.status_label.configure(
            text=(f"{len(tickets)} ticket(s) - double-click a ticket to open live chat" if tickets else "No tickets found.")
        )

    def _show_error(self, message):
        self.status_label.configure(text=f"Couldn't load tickets: {message}")

    def _on_double_click(self, event=None):
        item_id = self.tree.focus()
        if not item_id or not self.chat_window:
            return
        ticket = self.tickets_by_id.get(item_id)
        if not ticket:
            return
        self.chat_window.show(int(item_id), ticket.get("number"), ticket.get("subject"))


class TicketChatWindow:
    """Live chat window for a single ticket. One instance reused per open."""

    POLL_INTERVAL_MS = 15000

    def __init__(self, root, config, mark_read=None):
        self.root = root
        self.config = config
        self.mark_read = mark_read
        self.window = None
        self.text = None
        self.entry = None
        self.send_btn = None
        self.ticket_id = None
        self.ticket_number = None
        self.last_id = 0
        self._poll_job = None
        self._sse_stop_event = None
        self._seen_ids = set()

    def show(self, ticket_id, ticket_number, ticket_subject):
        if self.mark_read:
            self.mark_read()
        self._stop_sse()
        self.ticket_id = ticket_id
        self.ticket_number = ticket_number
        self.last_id = 0
        self._seen_ids = set()

        if self.window is not None and self.window.winfo_exists():
            self.window.deiconify()
            self.window.lift()
            self.window.focus_force()
        else:
            win = tk.Toplevel(self.root)
            win.configure(bg=BG)
            win.attributes("-topmost", True)
            win.protocol("WM_DELETE_WINDOW", self._on_close)
            self.window = win

            outer = ttk.Frame(win, padding=16, style="TFrame")
            outer.pack(fill="both", expand=True)

            self.title_label = ttk.Label(outer, text="", style="Title.TLabel")
            self.title_label.pack(anchor="w", pady=(0, 10))

            text_frame = tk.Frame(outer, bg=BORDER, padx=1, pady=1)
            text_frame.pack(fill="both", expand=True, pady=(0, 10))
            self.text = tk.Text(
                text_frame,
                width=60,
                height=16,
                relief="flat",
                bg=CARD_BG,
                fg="#1f2533",
                font=("Segoe UI", 10),
                padx=8,
                pady=8,
                wrap="word",
                state="disabled",
            )
            self.text.pack(fill="both", expand=True)

            entry_row = ttk.Frame(outer, style="TFrame")
            entry_row.pack(fill="x")
            self.entry = ttk.Entry(entry_row)
            self.entry.pack(side="left", fill="x", expand=True, padx=(0, 8))
            self.entry.bind("<Return>", lambda event: self.send())
            self.send_btn = ttk.Button(entry_row, text="Send", style="Accent.TButton", command=self.send)
            self.send_btn.pack(side="right")

            win.update_idletasks()
            w, h = 480, 420
            sw, sh = win.winfo_screenwidth(), win.winfo_screenheight()
            win.geometry(f"{w}x{h}+{(sw - w) // 2}+{(sh - h) // 2}")

        self.title_label.configure(text=f"Live Chat - Ticket #{ticket_number}: {ticket_subject}")
        self.text.configure(state="normal")
        self.text.delete("1.0", "end")
        self.text.insert("end", "Loading messages...\n")
        self.text.configure(state="disabled")

        self._load_history()
        self._schedule_poll()
        self._start_sse()
        self.entry.focus_set()

    def _on_close(self):
        if self._poll_job:
            self.root.after_cancel(self._poll_job)
            self._poll_job = None
        self._stop_sse()
        self.window.withdraw()

    def _start_sse(self):
        self._sse_stop_event = threading.Event()
        threading.Thread(
            target=_sse_chat_listen,
            args=(self.config, self.ticket_id, self._on_sse_message, self._sse_stop_event),
            daemon=True,
        ).start()

    def _stop_sse(self):
        if self._sse_stop_event:
            self._sse_stop_event.set()
            self._sse_stop_event = None

    def _on_sse_message(self, data):
        message = {
            "id": data.get("chat_id"),
            "sender_type": data.get("sender_type"),
            "sender_id": data.get("sender_id"),
            "sender_name": data.get("sender_name"),
            "message": data.get("message"),
            "created_at": data.get("created_at"),
        }
        self.root.after(0, self._append_messages, [message], False)

    def _schedule_poll(self):
        if self._poll_job:
            self.root.after_cancel(self._poll_job)
        self._poll_job = self.root.after(self.POLL_INTERVAL_MS, self._poll)

    def _poll(self):
        threading.Thread(target=self._fetch_messages, args=(self.ticket_id, self.last_id), daemon=True).start()
        self._schedule_poll()

    def _load_history(self):
        threading.Thread(target=self._fetch_messages, args=(self.ticket_id, 0), daemon=True).start()

    def _fetch_messages(self, ticket_id, since_id):
        cfg = self.config
        base_url = cfg["itflow_base_url"].rstrip("/")
        try:
            resp = requests.get(
                f"{base_url}/api/v1/tickets/{ticket_id}/chat",
                params={"since_id": since_id},
                headers=_api_headers(cfg),
                timeout=15,
            )
            resp.raise_for_status()
            messages = resp.json().get("data", [])
        except Exception as exc:
            if ticket_id == self.ticket_id and since_id == 0:
                self.root.after(0, self._show_error, str(exc))
            return

        if ticket_id != self.ticket_id:
            return

        self.root.after(0, self._append_messages, messages, since_id == 0)

    def _append_messages(self, messages, replace):
        if not messages and not replace:
            return

        self.text.configure(state="normal")
        if replace:
            self.text.delete("1.0", "end")
            self._seen_ids = set()
            if not messages:
                self.text.insert("end", "No messages yet. Say hello!\n")

        for m in messages:
            mid = m.get("id")
            if mid and mid in self._seen_ids:
                # Already shown - the periodic poll and the SSE listener can
                # both deliver the same message.
                continue
            if mid:
                self._seen_ids.add(mid)
            sender = m.get("sender_name") or ("Agent" if m.get("sender_type") == "agent" else "You")
            timestamp = (m.get("created_at") or "")[:16]
            self.text.insert("end", f"{sender} ({timestamp}):\n{m.get('message', '')}\n\n")
            self.last_id = max(self.last_id, mid or 0)

        self.text.configure(state="disabled")
        self.text.see("end")

    def _show_error(self, message):
        self.text.configure(state="normal")
        self.text.delete("1.0", "end")
        self.text.insert("end", f"Couldn't load chat: {message}\n")
        self.text.configure(state="disabled")

    def send(self):
        message = self.entry.get().strip()
        if not message or not self.ticket_id:
            return
        self.entry.delete(0, "end")
        threading.Thread(target=self._send_message, args=(self.ticket_id, message), daemon=True).start()

    def _send_message(self, ticket_id, message):
        cfg = self.config
        base_url = cfg["itflow_base_url"].rstrip("/")
        body = {"message": message}
        if cfg.get("contact_id"):
            body["contact_id"] = cfg["contact_id"]
        try:
            resp = requests.post(
                f"{base_url}/api/v1/tickets/{ticket_id}/chat",
                headers=_api_headers(cfg),
                json=body,
                timeout=15,
            )
            resp.raise_for_status()
        except Exception as exc:
            if ticket_id == self.ticket_id:
                self.root.after(0, lambda: messagebox.showerror(APP_NAME, f"Couldn't send message: {exc}"))
            return

        if ticket_id == self.ticket_id:
            self.root.after(0, self._poll)


def run_app(config_paths, icon_path=None):
    """Load config, build the tray icon + menu, and run the event loop.

    config_paths: list of config.json locations to check, in order of
                   preference (app_dir()/config.json is always checked last).
    icon_path:     path to the tray/window icon image (.ico or .png).
    """
    try:
        config = load_config(config_paths)
    except Exception as exc:
        # Show a one-off error dialog; the user has no way to fix config
        # themselves so just inform them clearly.
        root = tk.Tk()
        root.withdraw()
        messagebox.showerror(APP_NAME, str(exc))
        sys.exit(1)

    root = tk.Tk()
    root.withdraw()  # hidden root, used only to host Toplevel windows
    setup_style(root, accent=config.get("accent_color"))

    tray_image = build_tray_icon_image(icon_path, branding_logo=config.get("branding_logo"))

    def mark_chat_read():
        # `icon` is assigned further down in this function - safe since this
        # is only ever called later, from a chat window the user opened
        # (i.e. well after the tray icon exists and the event loop is running).
        set_chat_unread(icon, False)

    ticket_window = TicketWindow(root, config, icon_path=icon_path)
    chat_window = TicketChatWindow(root, config, mark_read=mark_chat_read)
    recent_window = RecentTicketsWindow(root, config, chat_window=chat_window)

    # Load ticket categories in the background so the dropdown is ready
    # by the time the user opens the New Ticket window.
    def load_categories():
        try:
            base_url = config["itflow_base_url"].rstrip("/")
            resp = requests.get(
                f"{base_url}/api/v1/ticket-categories",
                headers=_api_headers(config),
                timeout=15,
            )
            resp.raise_for_status()
            ticket_window.categories = resp.json() or []
        except Exception:
            pass
    threading.Thread(target=load_categories, daemon=True).start()

    def open_window(icon=None, item=None):
        root.after(0, ticket_window.show)

    def open_recent(icon=None, item=None):
        root.after(0, recent_window.show)

    def quit_app(icon, item):
        icon.stop()
        root.after(0, root.quit)

    def do_public_ip(icon=None, item=None):
        run_quick_tool(root, "Public IP Address", tool_public_ip)

    def do_ping(icon=None, item=None):
        run_quick_tool(root, "Ping Google", tool_ping)

    def do_printers(icon=None, item=None):
        run_quick_tool(root, "Installed Printers", tool_list_printers)

    def do_spooler(icon=None, item=None):
        run_quick_tool(root, "Restart Print Service", tool_restart_spooler)

    def do_network_adapters(icon=None, item=None):
        open_network_adapters()

    def do_open_portal(icon=None, item=None):
        base_url = config["itflow_base_url"].rstrip("/")
        webbrowser.open(f"{base_url}/client/")

    def _download_asset(url, dest):
        with requests.get(url, stream=True, timeout=120) as r:
            r.raise_for_status()
            with open(dest, "wb") as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)

    def do_self_update(tag, release):
        """Download and silently install the update for the current platform.

        Windows: Inno Setup silent install — CloseApplications=force handles
        closing this process and relaunching the updated app automatically.

        macOS / Linux: a detached shell script waits for this process to exit,
        replaces the binary/app bundle in-place (tries direct write first, falls
        back to sudo with cached credentials from the RMM tool), then relaunches.
        No password prompts, no browser, no dialogs.
        """
        system = platform.system()
        assets = release.get("assets", [])

        _notify(icon, f"Downloading v{tag} update...", title=APP_NAME)

        try:
            tmp_dir = tempfile.mkdtemp(prefix="itpanelpro_update_")

            if system == "Windows":
                asset = next((a for a in assets if a["name"].lower().endswith("setup.exe")), None)
                if not asset:
                    root.after(0, lambda: messagebox.showerror(APP_NAME, "Windows installer not found in release."))
                    return
                dest = os.path.join(tmp_dir, asset["name"])
                _download_asset(asset["browser_download_url"], dest)
                subprocess.Popen([dest, "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"])
                _notify(icon, f"Installing v{tag} — restarting...", title=APP_NAME)

            elif system == "Darwin" and getattr(sys, "frozen", False):
                # Derive the .app bundle path from the running executable:
                # .app/Contents/MacOS/ITPanelPro  ->  up three levels  -> .app
                app_bundle = os.path.normpath(
                    os.path.join(os.path.dirname(sys.executable), "..", "..")
                )
                asset = next((a for a in assets if a["name"].lower().endswith("-macos.zip")), None)
                if not asset:
                    root.after(0, lambda: messagebox.showerror(APP_NAME, "macOS update not found in release."))
                    return
                dest = os.path.join(tmp_dir, asset["name"])
                _download_asset(asset["browser_download_url"], dest)
                with zipfile.ZipFile(dest, "r") as z:
                    for name in z.namelist():
                        if ".." not in name and not name.startswith("/"):
                            z.extract(name, tmp_dir)
                new_app = os.path.join(tmp_dir, "ITPanelPro.app")
                if not os.path.isdir(new_app):
                    raise RuntimeError("ITPanelPro.app not found in update package")

                # Detached script: waits for us to exit, replaces bundle, relaunches
                updater = os.path.join(tmp_dir, "apply_update.sh")
                with open(updater, "w") as f:
                    f.write(f"""#!/bin/bash
sleep 2
rm -rf {shlex.quote(app_bundle)}
cp -R {shlex.quote(new_app)} {shlex.quote(app_bundle)} 2>/dev/null \\
  || sudo cp -R {shlex.quote(new_app)} {shlex.quote(app_bundle)}
open -a {shlex.quote(app_bundle)}
""")
                os.chmod(updater, 0o755)
                subprocess.Popen(["bash", updater])
                _notify(icon, f"Installing v{tag} — restarting...", title=APP_NAME)
                time.sleep(1)
                icon.stop()
                root.after(0, root.quit)

            elif system == "Linux" and getattr(sys, "frozen", False):
                current_binary = sys.executable  # e.g. /opt/itpanel-pro/ITPanelPro
                asset = next((a for a in assets if a["name"].lower().endswith("-linux.tar.gz")), None)
                if not asset:
                    root.after(0, lambda: messagebox.showerror(APP_NAME, "Linux update not found in release."))
                    return
                dest = os.path.join(tmp_dir, asset["name"])
                _download_asset(asset["browser_download_url"], dest)
                with tarfile.open(dest, "r:gz") as t:
                    for member in t.getmembers():
                        if ".." not in member.name and not member.name.startswith("/"):
                            t.extract(member, tmp_dir)
                new_binary = os.path.join(tmp_dir, "ITPanelPro")
                if not os.path.isfile(new_binary):
                    raise RuntimeError("ITPanelPro binary not found in update package")
                os.chmod(new_binary, 0o755)

                # Detached script: waits for our PID to exit, replaces binary, relaunches
                updater = os.path.join(tmp_dir, "apply_update.sh")
                with open(updater, "w") as f:
                    f.write(f"""#!/bin/bash
PID={os.getpid()}
while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
cp -f {shlex.quote(new_binary)} {shlex.quote(current_binary)} 2>/dev/null \\
  || sudo cp -f {shlex.quote(new_binary)} {shlex.quote(current_binary)}
chmod +x {shlex.quote(current_binary)}
nohup {shlex.quote(current_binary)} >/dev/null 2>&1 &
disown
""")
                os.chmod(updater, 0o755)
                subprocess.Popen(["bash", updater])
                _notify(icon, f"Installing v{tag} — restarting...", title=APP_NAME)
                time.sleep(1)
                icon.stop()
                root.after(0, root.quit)

            else:
                # Dev mode (not frozen) — just notify, can't self-replace interpreter
                _notify(icon, f"{APP_NAME} v{tag} available.", title=APP_NAME)

        except Exception as exc:
            root.after(0, lambda: messagebox.showerror(APP_NAME, f"Update failed: {exc}"))

    def do_check_update(icon=None, item=None):
        def worker():
            result = check_for_update()
            if not result:
                root.after(0, lambda: messagebox.showinfo(APP_NAME, f"You're up to date (v{VERSION})."))
                return
            tag, release = result
            def ask():
                if messagebox.askyesno(APP_NAME, f"A new version ({tag}) is available. Download and install now?"):
                    threading.Thread(target=do_self_update, args=(tag, release), daemon=True).start()
            root.after(0, ask)
        threading.Thread(target=worker, daemon=True).start()

    quick_tools_menu = pystray.Menu(
        pystray.MenuItem("My Public IP", do_public_ip),
        pystray.MenuItem("Ping Google", do_ping),
        pystray.MenuItem("List Printers", do_printers),
        pystray.MenuItem("Restart Print Service", do_spooler),
        pystray.MenuItem("Network Adapters", do_network_adapters),
    )

    menu = pystray.Menu(
        pystray.MenuItem("New Ticket", open_window, default=True),
        pystray.MenuItem("My Recent Tickets", open_recent),
        pystray.MenuItem("Open Client Portal", do_open_portal),
        pystray.MenuItem("Quick Tools", quick_tools_menu),
        pystray.MenuItem("Check for Updates", do_check_update),
        pystray.MenuItem("Exit", quit_app),
    )

    icon = pystray.Icon(APP_NAME, tray_image, APP_NAME, menu)
    icon._base_image = tray_image  # read by set_chat_unread() to build/clear the badge

    global _chat_listener_config, _chat_listener_icon
    _chat_listener_config = config
    _chat_listener_icon = icon

    tray_thread = threading.Thread(target=icon.run, daemon=True)
    tray_thread.start()

    # Background loop: retry queued (offline) tickets, poll for status
    # changes, and keep one live-chat SSE listener running per tracked
    # ticket (poll_ticket_chat is a 300s fallback in case Redis/SSE is down).
    def background_loop():
        time.sleep(5)
        _ensure_chat_listeners()
        while True:
            try:
                flush_queue(config)
            except Exception:
                pass
            try:
                poll_ticket_updates(config, icon)
            except Exception:
                pass
            try:
                poll_ticket_chat(config, icon)
            except Exception:
                pass
            try:
                _ensure_chat_listeners()
            except Exception:
                pass
            time.sleep(300)
    threading.Thread(target=background_loop, daemon=True).start()

    # Silent startup update check — auto-installs on all platforms, no dialogs
    if config.get("check_for_updates", True):
        def startup_check():
            result = check_for_update()
            if not result:
                return
            tag, release = result
            do_self_update(tag, release)
        threading.Thread(target=startup_check, daemon=True).start()

    root.mainloop()
