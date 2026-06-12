# -*- mode: python ; coding: utf-8 -*-
# Build with: pyinstaller itflow_quick_ticket.spec
#
# Produces ITFlowQuickTicket.app (a menu-bar-only "agent" app, no Dock icon).
# config.json is NOT bundled — it is deployed separately to
# /Library/Application Support/ITFlowQuickTicket/config.json (see install.sh).

import os

block_cipher = None

a = Analysis(
    ['tray_app.py'],
    pathex=['../common'],
    binaries=[],
    datas=[
        ('assets/icon.png', 'assets'),
    ] if os.path.exists('assets/icon.png') else [],
    hiddenimports=['PIL._tkinter_finder'],
    hookspath=[],
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='ITFlowQuickTicket',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

app = BUNDLE(
    exe,
    name='ITFlowQuickTicket.app',
    icon=None,
    bundle_identifier='com.itflow.quickticket',
    info_plist={
        'CFBundleName': 'ITFlow Quick Ticket',
        'CFBundleDisplayName': 'ITFlow Quick Ticket',
        'CFBundleShortVersionString': '1.4.0',
        'LSUIElement': True,  # menu-bar app, no Dock icon
        'NSHighResolutionCapable': True,
    },
)
