# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for Catfolio.app (macOS desktop build).

Run from the repo root:
    v3_backend/.venv/bin/pyinstaller catfolio.spec --clean

Output: dist/Catfolio.app
"""

import os

_here = os.path.dirname(os.path.abspath(SPEC))  # repo root

a = Analysis(
    [os.path.join(_here, "v3_backend", "desktop.py")],
    pathex=[
        os.path.join(_here, "v3_backend"),   # makes `app` package importable
        os.path.join(_here, "scripts"),      # makes build_trading212_v2 etc. importable
    ],
    binaries=[],
    datas=[
        # Static web assets (CSS, ECharts, LW Charts)
        (os.path.join(_here, "v3_backend", "app", "static"), "app/static"),
        # Public fund constituent baseline used for offline ETF look-through
        (os.path.join(_here, "v3_backend", "app", "data"), "app/data"),
    ],
    hiddenimports=[
        # ── app routes (dynamically assembled in main.py) ──
        "app.routes.api",
        "app.routes.home",
        "app.routes.lab",
        "app.routes.backtest",
        "app.routes.heatmap",
        "app.routes.returns",
        "app.routes.ai",
        "app.routes.settings",
        "app.routes.strategy",
        "app.routes.report",
        "app.routes.import_csv",
        "app.i18n",
        # ── modules imported lazily inside functions (PyInstaller can miss these) ──
        "app.alert_rules",
        "app.alerts",
        "app.ai",
        "app.analytics",
        "app.imap_mail_adapter",
        "app.mail_analysis",
        "app.mail_repository",
        "app.mail_service",
        "app.lab",
        "app.telegram_notify",
        # ── scripts imported at runtime via sys.path ──
        "build_trading212_v2",
        "enrich_trading212_data",
        # ── uvicorn internals ──
        "uvicorn.logging",
        "uvicorn.loops",
        "uvicorn.loops.auto",
        "uvicorn.loops.asyncio",
        "uvicorn.loops.uvloop",
        "uvicorn.protocols",
        "uvicorn.protocols.http",
        "uvicorn.protocols.http.auto",
        "uvicorn.protocols.http.h11_impl",
        "uvicorn.protocols.http.httptools_impl",
        "uvicorn.protocols.websockets",
        "uvicorn.protocols.websockets.auto",
        "uvicorn.protocols.websockets.wsproto_impl",
        "uvicorn.protocols.websockets.websockets_impl",
        "uvicorn.lifespan",
        "uvicorn.lifespan.on",
        # ── starlette / fastapi ──
        "starlette.routing",
        "starlette.staticfiles",
        "starlette.responses",
        "starlette.middleware.cors",
        "fastapi.routing",
        # ── pywebview macOS cocoa backend ──
        "webview.platforms.cocoa",
        # ── stdlib extras ──
        "sqlite3",
        "csv",
        "email.mime.multipart",
        "email.mime.text",
        "imap_tools",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # Not needed at runtime — cuts bundle size
        "tkinter",
        "matplotlib",
        "numpy",
        "pandas",
        "scipy",
        "IPython",
        "jupyter",
        "notebook",
        "pytest",
        "setuptools",
        "pip",
    ],
    noarchive=False,
    optimize=1,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="Catfolio",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,            # UPX can cause Gatekeeper issues on macOS; leave off
    console=False,        # no terminal window
    disable_windowed_traceback=False,
    argv_emulation=True,  # macOS: pass argv from Finder to the app
    target_arch=None,     # native arch (arm64 on Apple Silicon, x86_64 on Intel)
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="Catfolio",
)

app = BUNDLE(
    coll,
    name="Catfolio.app",
    icon=os.path.join(_here, "assets", "Catfolio.icns"),
    bundle_identifier="com.catfolio.portfolio",
    info_plist={
        "CFBundleName": "Catfolio",
        "CFBundleDisplayName": "Catfolio",
        "CFBundleVersion": "1.2.0",
        "CFBundleShortVersionString": "1.2.0",
        "NSHighResolutionCapable": True,
        "NSRequiresAquaSystemAppearance": False,  # supports dark mode
        "LSMinimumSystemVersion": "12.0",
        "NSHumanReadableCopyright": "MIT",
    },
)
