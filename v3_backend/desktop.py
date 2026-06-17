"""Desktop launcher for Catfolio.

Runs the FastAPI app in-process (uvicorn in a background thread) and shows it in a
native macOS window via pywebview / WKWebView — no browser, no command line.
Once bundled with PyInstaller this is the app entry point.

Data is written to ~/Library/Application Support/Catfolio (CATFOLIO_DATA_DIR), never into
the read-only app bundle.

Set CATFOLIO_DESKTOP_SELFTEST=1 to start the server, verify it responds, and exit
without opening a window (used for headless verification / CI).
"""

import os
import socket
import sys
import threading
import time
from pathlib import Path


def default_data_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "Catfolio"


def free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_for_port(port: int, timeout: float = 15.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def main():
    # Choose the writable data dir *before* importing the app (settings reads it at import).
    data_dir = os.environ.get("CATFOLIO_DATA_DIR") or os.environ.get("HELM_DATA_DIR") or str(default_data_dir())
    os.environ.setdefault("CATFOLIO_DATA_DIR", data_dir)
    os.environ.setdefault("HELM_DATA_DIR", data_dir)
    Path(data_dir).mkdir(parents=True, exist_ok=True)

    # Make the app package + scripts importable when launched from here or bundled.
    here = Path(__file__).resolve().parent
    if str(here) not in sys.path:
        sys.path.insert(0, str(here))

    import uvicorn
    from app.main import app

    port = free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()

    if not wait_for_port(port):
        print("Catfolio: server failed to start", file=sys.stderr)
        sys.exit(1)

    url = f"http://127.0.0.1:{port}/"

    if os.environ.get("CATFOLIO_DESKTOP_SELFTEST") == "1" or os.environ.get("HELM_DESKTOP_SELFTEST") == "1":
        import urllib.request
        with urllib.request.urlopen(url, timeout=40) as resp:
            ok = resp.status == 200
        print(f"selftest: data_dir={data_dir} port={port} home_ok={ok}")
        server.should_exit = True
        thread.join(timeout=3)
        sys.exit(0 if ok else 1)

    import webview
    webview.create_window("Catfolio", url, width=1440, height=920, min_size=(1024, 700))
    webview.start()  # blocks on the main thread until the window is closed

    server.should_exit = True
    thread.join(timeout=3)


if __name__ == "__main__":
    main()
