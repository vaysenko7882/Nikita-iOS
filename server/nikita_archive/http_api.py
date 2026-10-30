"""Read-only authenticated API, bound to loopback behind Caddy HTTPS."""
import hmac
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def make_server(archive, token: str, port: int = 8765):
    if len(token) < 32 or any(char.isspace() for char in token):
        raise ValueError("Use a random API token of at least 32 characters")

    class Handler(BaseHTTPRequestHandler):
        server_version = "NikitaArchive/2"

        def log_message(self, *args):
            pass  # Never log request paths, account identifiers or credentials.

        def send_json(self, status, payload):
            data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            value = self.headers.get("Authorization", "")
            if not hmac.compare_digest(value.encode(), ("Bearer " + token).encode()):
                self.send_json(401, {"error": "unauthorized"})
                return
            route = urlsplit(self.path)
            if route.path not in ("/v1/sync", "/v1/status"):
                self.send_json(404, {"error": "not_found"})
                return
            try:
                query = parse_qs(route.query, max_num_fields=8)
                after = int(query.get("after", ["0"])[0])
                limit = int(query.get("limit", ["100"])[0])
                result = archive.sync(after, server_id=query.get("server_id", [""])[0], limit=limit)
                if route.path == "/v1/status":
                    result.pop("events")
                self.send_json(200, result)
            except (ValueError, OverflowError):
                self.send_json(400, {"error": "invalid_request"})
            except Exception:
                self.send_json(503, {"error": "archive_unavailable"})

    class Server(ThreadingHTTPServer):
        daemon_threads = True

        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(15)
            return connection, address

    return Server(("127.0.0.1", port), Handler)
