#!/usr/bin/env python3
"""alertmanager-shim — HMAC-sign Alertmanager webhook POSTs and forward
to hermes-webhook.

Alertmanager's webhook_config supports no custom headers and no body-derived
HMAC. Hermes's _validate_signature requires either X-Hub-Signature-256
(body HMAC) or X-Gitlab-Token (static-shared-secret). This shim bridges the
gap: receive POST on /alert → compute HMAC-SHA256(body, WEBHOOK_HMAC_SECRET)
→ re-POST to http://hermes-webhook.hermes:8644/webhooks/alertmanager with
X-Hub-Signature-256.

Stdlib only — no pip, no venv, no init container. The Deployment runs
python:3.12-slim directly.
"""

import hashlib
import hmac
import json
import logging
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("alertmanager-shim")

SECRET = os.environ["WEBHOOK_HMAC_SECRET"].encode()
TARGET = os.environ.get(
    "TARGET_URL", "http://hermes-webhook.hermes:8644/webhooks/alertmanager"
)
PORT = int(os.environ.get("PORT", "8080"))
MAX_BODY_BYTES = 1_048_576  # 1 MiB cap to bound memory


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log.info("%s - %s", self.client_address[0], fmt % args)

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/alert":
            self._send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_BODY_BYTES:
            self._send_json(413, {"error": "body too large or empty"})
            return
        body = self.rfile.read(length)
        sig = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        req = urllib.request.Request(
            TARGET,
            data=body,
            headers={
                "Content-Type": self.headers.get(
                    "Content-Type", "application/json"
                ),
                "X-Hub-Signature-256": sig,
                "X-Alertmanager-Shim": "1",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                resp_body = resp.read(4096)
                log.info(
                    "forwarded alert: hermes returned %s (%d bytes)",
                    resp.status,
                    len(resp_body),
                )
                self._send_json(200, {"status": "ok"})
                return
        except urllib.error.HTTPError as exc:
            tail = exc.read(512).decode("utf-8", errors="replace")
            log.warning("hermes rejected alert: %d %s", exc.code, tail)
            self._send_json(502, {"error": "upstream rejected", "code": exc.code})
        except Exception as exc:  # noqa: BLE001
            log.error("forward failed: %s", exc)
            self._send_json(502, {"error": "upstream unreachable"})


def main() -> int:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log.info("alertmanager-shim listening on :%d → %s", PORT, TARGET)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
