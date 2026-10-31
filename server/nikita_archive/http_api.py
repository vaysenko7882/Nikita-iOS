"""Read-only authenticated API, bound to loopback behind Caddy HTTPS."""
import hmac
import hashlib
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def make_server(archive, token: str, port: int = 8765):
    if len(token) < 32 or any(char.isspace() for char in token):
        raise ValueError("Use a random API token of at least 32 characters")

    class Handler(BaseHTTPRequestHandler):
        server_version = "NikitaArchive/3"

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
            if self.command != "HEAD":
                self.wfile.write(data)

        def media(self, path):
            identifier = path.removeprefix("/v1/media/")
            if not archive.media or not re.fullmatch(r"[a-f0-9]{64}", identifier):
                self.send_json(404, {"error": "not_found"})
                return
            if self.headers.get("X-Nikita-Archive-Epoch", "") != archive.server_id:
                self.send_json(409, {"error": "archive_changed"})
                return
            state, item = archive.media.ready(identifier)
            if state != "ready":
                if state in ("pending", "downloading"):
                    self.send_response(503)
                    self.send_header("Retry-After", "3")
                    self.send_header("Content-Length", "0")
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                else:
                    self.send_json(410 if state == "failed" else 404, {"error": "media_unavailable"})
                return
            length = item["size"]
            start, end, status = 0, length - 1, 200
            requested = self.headers.get("Range")
            if requested is not None:
                match = re.fullmatch(r"bytes=([0-9]{1,20})-([0-9]{0,20})", requested)
                if not match:
                    self.send_json(400, {"error": "invalid_range"})
                    return
                start = int(match[1])
                end = min(length - 1, int(match[2])) if match[2] else length - 1
                if start >= length or end < start:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{length}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                # The client deliberately requests bounded chunks. Reject unbounded ranges.
                if end - start + 1 > 512 * 1024:
                    self.send_json(400, {"error": "range_too_large"})
                    return
                status = 206
            with item["path"].open("rb") as source:
                source.seek(start)
                digest = None
                if status == 206:
                    digest = hashlib.sha256(source.read(end - start + 1)).hexdigest()
                    source.seek(start)
                self.send_response(status)
                self.send_header("Content-Type", item["mime"])
                self.send_header("Content-Length", str(end - start + 1))
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Cache-Control", "private, no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("X-Nikita-Archive-Epoch", archive.server_id)
                self.send_header("ETag", '"' + item["sha256"] + '"')
                if digest:
                    self.send_header("X-Nikita-Range-SHA256", digest)
                    self.send_header("Content-Range", f"bytes {start}-{end}/{length}")
                self.end_headers()
                if self.command != "HEAD":
                    remaining = end - start + 1
                    while remaining:
                        block = source.read(min(64 * 1024, remaining))
                        if not block:
                            break
                        self.wfile.write(block)
                        remaining -= len(block)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            value = self.headers.get("Authorization", "")
            if not hmac.compare_digest(value.encode(), ("Bearer " + token).encode()):
                self.send_json(401, {"error": "unauthorized"})
                return
            route = urlsplit(self.path)
            if route.path.startswith("/v1/media/"):
                try:
                    self.media(route.path)
                except (BrokenPipeError, ConnectionResetError, TimeoutError):
                    pass
                except OSError:
                    self.send_json(503, {"error": "media_unavailable"})
                return
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
