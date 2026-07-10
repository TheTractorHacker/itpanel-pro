# -*- mode: python ; coding: utf-8 -*-
# Build with: pyinstaller itpanel_pro.spec
#
# Produces a single-file, windowed (no console) .exe. config.json is NOT
# bundled — it is deployed separately to %ProgramData%\ITPanelPro\.

import os

block_cipher = None

a = Analysis(
    ['tray_app.py'],
    pathex=['../common'],
    binaries=[],
    datas=[
        ('assets/icon.ico', 'assets'),
    ] if os.path.exists('assets/icon.ico') else [],
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
    name='ITPanelPro',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon='assets/icon.ico' if os.path.exists('assets/icon.ico') else None,
)
