"""Authenticated journal/media reads and capture-policy updates behind HTTPS."""
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
        server_version = "CodeGramArchive/5"

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

        def authorized(self):
            value = self.headers.get("Authorization", "")
            return hmac.compare_digest(value.encode(), ("Bearer " + token).encode())

        def account_id(self):
            with archive.connect() as db:
                return int(archive._meta(db,"account_id","0"))

        def envelope(self, value):
            return {**value,"account_id":self.account_id(),"server_id":archive.server_id,"server_version":5}

        def read_body(self, maximum=16384):
            size = int(self.headers.get("Content-Length","0"))
            if not 0<size<=maximum or self.headers.get("Transfer-Encoding") is not None:
                raise ValueError("Invalid body size")
            raw = self.rfile.read(size)
            if len(raw)!=size:
                raise ValueError("Incomplete body")
            value = json.loads(raw)
            if not isinstance(value,dict):
                raise ValueError("Expected object")
            return value

        def do_POST(self):
            if not self.authorized():
                self.send_json(401,{"error":"unauthorized"}); return
            if self.headers.get("X-CodeGram-Account-ID")!=str(self.account_id()):
                self.send_json(403,{"error":"account_mismatch"}); return
            if self.path!="/v1/video" or archive.social_videos is None:
                self.send_json(404,{"error":"not_found"}); return
            try:
                result = archive.social_videos.create(self.read_body().get("url"))
                self.send_json(200,self.envelope(result))
            except (ValueError,TypeError,UnicodeError):
                self.send_json(400,{"error":"invalid_video_link"})
            except BlockingIOError:
                self.send_json(429,{"error":"video_queue_busy"})
            except OSError:
                self.send_json(507,{"error":"insufficient_storage"})
            except Exception:
                self.send_json(503,{"error":"video_unavailable"})

        def do_PUT(self):
            from .policy import PolicyConflict
            if not self.authorized():
                self.send_json(401,{"error":"unauthorized"}); return
            profile_match = re.fullmatch(r"/v1/profiles/([0-9]{1,19})",self.path)
            if profile_match and archive.profiles is not None:
                if self.headers.get("X-CodeGram-Account-ID")!=str(self.account_id()):
                    self.send_json(403,{"error":"account_mismatch"}); return
                try:
                    result = archive.profiles.configure(profile_match[1],self.read_body())
                    self.send_json(200,self.envelope(result))
                except (ValueError,TypeError,UnicodeError):
                    self.send_json(400,{"error":"invalid_profile"})
                except Exception:
                    self.send_json(503,{"error":"archive_unavailable"})
                return
            if urlsplit(self.path).path!="/v1/policy" or archive.policy is None:
                self.send_json(404,{"error":"not_found"}); return
            if self.headers.get("X-CodeGram-Account-ID")!=str(self.account_id()):
                self.send_json(403,{"error":"account_mismatch"}); return
            try:
                size = int(self.headers.get("Content-Length","0"))
                if not 0<size<=256*1024 or self.headers.get("Transfer-Encoding") is not None:
                    self.send_json(413,{"error":"invalid_size"}); return
                raw = self.rfile.read(size)
                if len(raw)!=size: raise ValueError("Incomplete policy")
                result = archive.policy.update(json.loads(raw))
                self.send_json(200,{**result,"account_id":self.account_id(),"server_version":4})
            except PolicyConflict:
                self.send_json(409,{"error":"policy_changed"})
            except (ValueError,TypeError,UnicodeError):
                self.send_json(400,{"error":"invalid_policy"})
            except Exception:
                self.send_json(503,{"error":"archive_unavailable"})

        def do_GET(self):
            if not self.authorized():
                self.send_json(401, {"error": "unauthorized"})
                return
            route = urlsplit(self.path)
            profile_match = re.fullmatch(r"/v1/profiles(?:/([0-9]{1,19})(/history)?)?",route.path)
            if profile_match and archive.profiles is not None:
                try:
                    query = parse_qs(route.query,max_num_fields=8)
                    identifier,history = profile_match.groups()
                    result = archive.profiles.history(identifier,query.get("before",["0"])[0],query.get("limit",["30"])[0]) if history else archive.profiles.status(identifier)
                    self.send_json(200,self.envelope(result))
                except (ValueError,TypeError):
                    self.send_json(400,{"error":"invalid_request"})
                except Exception:
                    self.send_json(503,{"error":"archive_unavailable"})
                return
            video_match = re.fullmatch(r"/v1/video/([a-f0-9]{32})(/file)?",route.path)
            if video_match and archive.social_videos is not None:
                identifier,is_file = video_match.groups()
                try:
                    if not is_file:
                        self.send_json(200,self.envelope(archive.social_videos.status(identifier)))
                        return
                    if self.headers.get("X-Nikita-Archive-Epoch")!=archive.server_id:
                        self.send_json(409,{"error":"archive_changed"}); return
                    path,value = archive.social_videos.ready(identifier)
                    with path.open("rb") as source:
                        self.send_response(200)
                        self.send_header("Content-Type","video/mp4")
                        self.send_header("Content-Length",str(value["size"]))
                        self.send_header("Cache-Control","private, no-store")
                        self.send_header("X-Nikita-Archive-Epoch",archive.server_id)
                        self.send_header("X-Content-Type-Options","nosniff")
                        self.end_headers()
                        if self.command!="HEAD":
                            while True:
                                block = source.read(64*1024)
                                if not block: break
                                self.wfile.write(block)
                except KeyError:
                    self.send_json(404,{"error":"not_found"})
                except BlockingIOError:
                    self.send_json(409,{"error":"video_not_ready"})
                except (BrokenPipeError,ConnectionResetError):
                    pass
                return
            if route.path in ("/v1/policy","/v1/storage"):
                try:
                    query = parse_qs(route.query,max_num_fields=8)
                    if route.path=="/v1/policy" and archive.policy is not None:
                        result = archive.policy.current(include_dialogs=True,query=query.get("q",[""])[0])
                    elif route.path=="/v1/storage" and archive.media is not None:
                        result = archive.media.storage()
                    else:
                        self.send_json(404,{"error":"not_found"}); return
                    self.send_json(200,{**result,"account_id":self.account_id(),"server_id":archive.server_id,"server_version":4})
                except Exception:
                    self.send_json(503,{"error":"archive_unavailable"})
                return
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
