"""Loopback demo receiver: verify raw bodies and retain only bounded metadata."""

import argparse
from collections import OrderedDict
from datetime import datetime, timezone
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import re
import sys

MAX_BODY_BYTES = 1024 * 1024
MAX_DELIVERIES = 1000

DASHBOARD = b"""<!doctype html><html lang="en"><meta charset="utf-8">
<title>Signed webhook demo</title><h1>Signed webhook demo</h1>
<p>Local receiver. Only verified delivery metadata is retained, in memory.
Synthetic local tests are not proof of delivery from GitHub.</p>
<pre id="events">Loading...</pre><script>
async function refresh() {
  try {
    const response = await fetch('/deliveries');
    if (!response.ok) throw new Error('HTTP ' + response.status);
    document.getElementById('events').textContent =
      JSON.stringify(await response.json(), null, 2);
  } catch (error) { document.getElementById('events').textContent = String(error); }
}
refresh(); setInterval(refresh, 2000);
</script></html>"""


class Receiver(HTTPServer):
    def __init__(self, address, secret):
        super().__init__(address, Handler)
        self.secret = secret
        self.deliveries = OrderedDict()


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, format, *args):
        # Never log request paths, headers, bodies or signature values.
        pass

    def reply(self, status, data, content_type="application/json"):
        body = data if isinstance(data, bytes) else json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"status": "ok"})
        elif self.path == "/deliveries":
            self.reply(200, list(self.server.deliveries.values()))
        elif self.path == "/":
            self.reply(200, DASHBOARD, "text/html; charset=utf-8")
        else:
            self.reply(404, {"error": "not_found"})

    def reject(self, status, reason):
        self.close_connection = True
        print(json.dumps({"status": status, "error": reason}), flush=True)
        self.reply(status, {"error": reason})

    def do_POST(self):
        if self.path != "/webhook":
            self.reject(404, "not_found")
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get("Transfer-Encoding") or len(lengths) != 1 or not lengths[0].isdigit():
            self.reject(400, "content_length_required")
            return
        size = int(lengths[0])
        if size > MAX_BODY_BYTES:
            self.reject(413, "body_too_large")
            return
        if self.headers.get_content_type() != "application/json":
            self.reject(415, "json_required")
            return
        try:
            raw = self.rfile.read(size)
        except TimeoutError:
            self.reject(408, "body_timeout")
            return
        if len(raw) != size:
            self.reject(400, "incomplete_body")
            return
        signature = self.headers.get("X-Hub-Signature-256", "")
        expected = "sha256=" + hmac.new(self.server.secret, raw, hashlib.sha256).hexdigest()
        if not re.fullmatch(r"sha256=[a-fA-F0-9]{64}", signature) or not hmac.compare_digest(expected, signature):
            self.reject(401, "invalid_signature")
            return
        event = self.headers.get("X-GitHub-Event", "")
        delivery = self.headers.get("X-GitHub-Delivery", "")
        if not re.fullmatch(r"[a-z][a-z0-9_]{0,79}", event) or not re.fullmatch(r"[a-zA-Z0-9-]{1,80}", delivery):
            self.reject(400, "invalid_event_headers")
            return
        try:
            payload = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            self.reject(400, "invalid_json")
            return
        if not isinstance(payload, dict):
            self.reject(400, "json_object_required")
            return
        action = payload.get("action")
        if action is not None and (not isinstance(action, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,79}", action)):
            self.reject(400, "invalid_action")
            return
        if delivery in self.server.deliveries:
            self.reply(200, {"status": "duplicate", "delivery_id": delivery})
            return
        record = {
            "delivery_id": delivery,
            "event": event,
            "action": action,
            "signature_verified": True,
            "received_at": datetime.now(timezone.utc).isoformat(),
        }
        self.server.deliveries[delivery] = record
        if len(self.server.deliveries) > MAX_DELIVERIES:
            self.server.deliveries.popitem(last=False)
        print(json.dumps(record), flush=True)
        self.reply(202, {"status": "accepted", "delivery_id": delivery})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()
    secret = os.environ.get("WEBHOOK_SECRET", "")
    if not re.fullmatch(r"[a-fA-F0-9]{64}", secret):
        parser.error("WEBHOOK_SECRET must contain the 64-character generated hex secret.")
    try:
        with Receiver(("127.0.0.1", args.port), secret.encode("ascii")) as server:
            print(f"Listening on http://127.0.0.1:{args.port}", flush=True)
            server.serve_forever()
    except KeyboardInterrupt:
        return 0
    except OSError as error:
        print(f"Receiver failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
