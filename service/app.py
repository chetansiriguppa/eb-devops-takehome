"""Minimal HTTP service for the take-home. Stdlib only: no third-party deps to patch."""

import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def info() -> dict:
    # Read env on every request so a ConfigMap change + pod restart is reflected immediately.
    return {
        "app": os.environ.get("APP_NAME", "unknown"),
        "version": os.environ.get("VERSION", "unknown"),
        "pod": socket.gethostname(),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "demo-service"

    def _send_json(self, status: int, body: dict) -> None:
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        if self.path == "/":
            self._send_json(200, info())
        elif self.path == "/healthz":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"listening on :{port} app={info()['app']} version={info()['version']}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
