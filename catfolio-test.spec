# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for Catfolio-test.app — a demo-mode build with no real user data.

Entry point is desktop_test.py (forces CATFOLIO_DEMO=1 + isolated data dir). Uses the
cat icon at assets/Catfolio.icns and names the bundle Catfolio-test.app.

Run from the repo root:
    v3_backend/.venv/bin/pyinstaller catfolio-test.spec --clean
Output: dist/Catfolio-test.app
"""

import os

_here = os.path.dirname(os.path.abspath(SPEC))  # repo root

a = Analysis(
    [os.path.join(_here, "v3_backend", "desktop_test.py")],
    pathex=[
        os.path.join(_here, "v3_backend"),   # makes `app` + `desktop` importable
        os.path.join(_here, "scripts"),      # makes build_trading212_v2 etc. importable
    ],
    binaries=[],
    datas=[
        (os.path.join(_here, "v3_backend", "app", "static"), "app/static"),
    ],
    hiddenimports=[
        "desktop",
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
        # ── modules imported lazily inside functions ──
        "app.alert_rules",
        "app.alerts",
        "app.ai",
        "app.analytics",
        "app.lab",
        "app.telegram_notify",
        "app.demo_data",
        # ── scripts imported at runtime via sys.path ──
        "build_trading212_v2",
        "enrich_trading212_data",
        "build_portfolio_html",
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
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
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
    name="Catfolio-test",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=True,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="Catfolio-test",
)

app = BUNDLE(
    coll,
    name="Catfolio-test.app",
    icon=os.path.join(_here, "assets", "Catfolio.icns"),
    bundle_identifier="com.catfolio.portfolio.test",
    info_plist={
        "CFBundleName": "Catfolio-test",
        "CFBundleDisplayName": "Catfolio-test",
        "CFBundleVersion": "1.2.0",
        "CFBundleShortVersionString": "1.2.0",
        "NSHighResolutionCapable": True,
        "NSRequiresAquaSystemAppearance": False,
        "LSMinimumSystemVersion": "12.0",
        "NSHumanReadableCopyright": "MIT",
    },
)
