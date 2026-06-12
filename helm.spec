# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for Helm.app (macOS desktop build).

Run from the repo root:
    v3_backend/.venv/bin/pyinstaller helm.spec --clean

Output: dist/Helm.app
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
    name="Helm",
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
    name="Helm",
)

app = BUNDLE(
    coll,
    name="Helm.app",
    icon=None,            # TODO: add Helm.icns for a proper dock icon
    bundle_identifier="com.helm.portfolio",
    info_plist={
        "CFBundleName": "Helm",
        "CFBundleDisplayName": "Helm",
        "CFBundleVersion": "1.0.0",
        "CFBundleShortVersionString": "1.0.0",
        "NSHighResolutionCapable": True,
        "NSRequiresAquaSystemAppearance": False,  # supports dark mode
        "LSMinimumSystemVersion": "12.0",
        "NSHumanReadableCopyright": "MIT",
    },
)
