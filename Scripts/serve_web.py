#!/usr/bin/env python3
"""
AIQuoty Local Web Dashboard Server

Serves the AIQuoty web dashboard from ./web and bridges
/api/status (and /api/status?demo=1) to `aiquoty-cli status --json`.

Usage:
  python3 Scripts/serve_web.py [--port 8787] [--host 127.0.0.1]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent
WEB_DIR = REPO_ROOT / "web"


def resolve_cli_command(demo: bool) -> list[str]:
    candidates = [
        REPO_ROOT / ".build" / "release" / "aiquoty-cli",
        REPO_ROOT / ".build" / "debug" / "aiquoty-cli",
    ]
    existing = [p for p in candidates if p.exists() and os.access(p, os.X_OK)]
    if existing:
        newest = max(existing, key=lambda p: p.stat().st_mtime)
        cmd = [str(newest), "status", "--json"]
        if demo:
            cmd.append("--demo")
        return cmd

    cmd = ["swift", "run", "aiquoty-cli", "status", "--json"]
    if demo:
        cmd.append("--demo")
    return cmd


class DashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/api/status":
            query = parse_qs(parsed.query)
            demo = query.get("demo", ["0"])[0] in ("1", "true", "yes")
            self.handle_api_status(demo=demo)
            return
        super().do_GET()

    def handle_api_status(self, demo: bool) -> None:
        cmd = resolve_cli_command(demo=demo)
        try:
            proc = subprocess.run(
                cmd,
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            if proc.returncode != 0:
                payload = {
                    "error": f"aiquoty-cli exited with {proc.returncode}",
                    "stderr": proc.stderr.strip(),
                }
                self._send_json(500, payload)
                return

            body = proc.stdout.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as exc:  # noqa: BLE001
            self._send_json(500, {"error": str(exc)})

    def _send_json(self, code: int, data: dict) -> None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> int:
    parser = argparse.ArgumentParser(description="Serve AIQuoty Web Dashboard")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8787, help="Bind port (default: 8787)")
    args = parser.parse_args()

    if not WEB_DIR.is_dir():
        print(f"Error: web directory not found at {WEB_DIR}", file=sys.stderr)
        return 1

    server = ThreadingHTTPServer((args.host, args.port), DashboardHandler)
    url = f"http://{args.host}:{args.port}"
    print(f"AIQuoty Web Dashboard running at {url}")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
