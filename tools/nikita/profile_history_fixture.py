#!/usr/bin/env python3
"""Loopback-only HTTP fixture for the native production history-feed check."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading
import time
from urllib.parse import parse_qs, urlsplit


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    lock = threading.Lock()
    state = {"events": [{"seq": i, "kind": "profile.changed", "observed_at": 1700000000+i,
                         "payload": {"field": "first_name", "after": "Record " + str(i)}} for i in range(1, 61)],
             "requests": 0, "delay_next": 0.0, "inflight_delays": 0, "epoch": "fixture-one"}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, value):
            data = json.dumps(value).encode()
            try:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self):
            route = urlsplit(self.path)
            if route.path == "/stats":
                with lock:
                    value = {"requests": state["requests"], "latest": state["events"][-1]["seq"],
                             "inflight_delays": state["inflight_delays"]}
                return self.reply(value)
            if route.path != "/history":
                self.send_error(404)
                return
            before = int(parse_qs(route.query).get("before", ["0"])[0])
            limit = max(1,min(100,int(parse_qs(route.query).get("limit", ["4"])[0])))
            with lock:
                state["requests"] += 1
                delay, state["delay_next"] = state["delay_next"], 0.0
                if delay:
                    state["inflight_delays"] += 1
            if delay:
                time.sleep(delay)
            with lock:
                if delay:
                    state["inflight_delays"] -= 1
                rows = [e for e in reversed(state["events"]) if not before or e["seq"] < before]
                page = rows[:limit]
                value = {"events": page, "next_before": page[-1]["seq"] if page else 0,
                         "server_id": state["epoch"], "account_id": 100, "server_version": 5,
                         "has_more": len(rows) > len(page),
                         "profiles": [{"peer_id": "100", "enabled": True, "title": "Fixture", "event_count": len(state["events"])}]}
            self.reply(value)

        def do_POST(self):
            route = urlsplit(self.path)
            query = parse_qs(route.query)
            with lock:
                if route.path == "/publish":
                    for _ in range(int(query.get("count", ["1"])[0])):
                        seq = state["events"][-1]["seq"] + 1
                        state["events"].append({"seq": seq, "kind": "stories.added", "observed_at": 1700000000+seq,
                                                "payload": {"after": {"caption": "Story " + str(seq)}},
                                                "media": [{"blob_id": "a"*64, "state": "pending", "size": 8, "mime": "image/jpeg"}]})
                elif route.path == "/ready":
                    state["events"][-1]["media"][0]["state"] = "ready"
                elif route.path == "/delay-next":
                    state["delay_next"] = float(query.get("seconds", ["1"])[0])
                elif route.path == "/reset-epoch":
                    state["epoch"] = "fixture-two"
                    state["events"] = [{"seq": i, "kind": "profile.changed", "observed_at": 1700000000+i,
                                        "payload": {"field": "first_name", "after": "New archive " + str(i)}} for i in range(1, 5)]
                else:
                    self.send_error(404)
                    return
                value = {"latest": state["events"][-1]["seq"]}
            self.reply(value)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    Path(args.port_file).write_text(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
