#!/usr/bin/env python3
"""Loopback-only, read-only browser log for the three-node OTA demo.

Never accepts uploads or forwards firmware. Only GETs controller /status while the
Mac is on the demo AP; stores non-secret node status transitions locally.
"""
from __future__ import annotations

import argparse
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener

ROOT = Path(__file__).resolve().parent.parent
EVENTS_FILE = ROOT / "noise_experiments" / "web_log_events.jsonl"  # ignored
ASSETS = Path(__file__).resolve().parent
CONTROLLER_URL = "http://192.168.4.1/status"
CONTROLLER = re.compile(r"\brole=0 version=(\d+) noise=([01])\b")
TLS = re.compile(r"\btls=([01])\b") # newer controller: upload listener; /status remains HTTP
EDGE = re.compile(r"\bedge([12])_secure=(v(\d+)_ota(\d+)_minheap(\d+)_stack(\d+)_rttms(\d+)|unregistered|offline|auth_failed|bad_status|crypto_unavailable)\b")
OTA = re.compile(r"\bota=(valid|pending|unknown|invalid|aborted|new)\b")
MIN_HEAP = re.compile(r"\bminheap=(\d+)\b")
STACK = re.compile(r"\bstack_margin=(\d+)\b")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def demo_ip() -> bool:
    try:
        value = subprocess.check_output(["ipconfig", "getifaddr", "en0"], text=True,
                                        timeout=3, stderr=subprocess.DEVNULL).strip()
        return ipaddress.ip_address(value) in ipaddress.ip_network("192.168.4.0/24")
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def parse_status(raw: str) -> dict:
    if len(raw) > 2048 or "\n" in raw.strip("\n"):
        raise ValueError("Unexpected controller status format")
    controller, ota, tls = CONTROLLER.search(raw), OTA.search(raw), TLS.search(raw)
    if not controller or not ota:
        raise ValueError("Response was not a Noise controller status")
    edges = {}
    for match in EDGE.finditer(raw):
        role, text, version, ota_state, heap, stack, rtt = match.groups()
        edges[f"edge{role}"] = {
            "version": int(version) if version else None,
            "ota": "valid" if ota_state == "2" else "pending" if ota_state == "1" else
                   f"state {ota_state}" if ota_state else None,
            "secure": bool(version), "state": text if not version else "authenticated",
            "min_heap": int(heap) if heap else None,
            "stack_margin": int(stack) if stack else None,
            "rtt_ms": int(rtt) if rtt else None,
        }
    if set(edges) != {"edge1", "edge2"}:
        raise ValueError("Missing edge status; rejecting incomplete snapshot")
    heap = MIN_HEAP.search(raw)
    stack = STACK.search(raw)
    return {
        "controller": {"version": int(controller[1]), "noise": controller[2] == "1",
                       "tls": tls[1] == "1" if tls else False,
                       "ota": ota[1], "min_heap": int(heap[1]) if heap else None,
                       "stack_margin": int(stack[1]) if stack else None},
        "edges": edges,
        "raw": raw.strip(),
    }


class StatusLog:
    def __init__(self, path: Path = EVENTS_FILE, now=utc_now):
        self.path = path
        self.now = now
        self.lock = threading.Lock()
        self.events = deque(maxlen=250)
        self.snapshot = None
        self.last_seen = None
        self.error = "Waiting for the demo AP"
        self._read_existing()

    def _read_existing(self):
        if not self.path.is_file():
            return
        # Bounded read of small local records. Ignore partial last line after power loss.
        if self.path.stat().st_size > 2_000_000:
            raise ValueError("Local status log exceeds safe 2 MB limit; archive it before starting")
        self.events.clear()
        for line in self.path.read_text(encoding="utf-8").splitlines():
            try:
                event = json.loads(line)
                if isinstance(event, dict) and {"at", "node", "kind", "detail"} <= event.keys():
                    self.events.append(event)
            except json.JSONDecodeError:
                continue

    def _add(self, node: str, kind: str, detail: str):
        event = {"at": self.now(), "node": node, "kind": kind, "detail": detail}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as out:
            out.write(json.dumps(event, ensure_ascii=True, separators=(",", ":")) + "\n")
        self.events.append(event)

    def observe(self, raw: str):
        parsed = parse_status(raw)
        with self.lock:
            before = self.snapshot
            self.snapshot = parsed
            self.last_seen = self.now()
            if self.error and before is not None:
                self._add("fleet", "connection", "Controller status available again")
            self.error = None
            for name in ("controller", "edge1", "edge2"):
                new = parsed["controller"] if name == "controller" else parsed["edges"][name]
                old = (before["controller"] if name == "controller" else before["edges"][name]) if before else None
                if old is None:
                    if new.get("version") is not None:
                        self._add(name, "observed", f"Observed v{new['version']} · {new['ota']}")
                    else:
                        self._add(name, "connection", f"{new['state']}")
                else:
                    if old.get("version") != new.get("version"):
                        if new.get("version") is None:
                            self._add(name, "connection", f"Unreachable ({new['state']}); last seen v{old.get('version')}")
                        elif old.get("version") is None:
                            self._add(name, "connection", f"Authenticated again at v{new['version']} · {new['ota']}")
                        else:
                            self._add(name, "version", f"v{old['version']} → v{new['version']} · {new['ota']}")
                    elif old.get("ota") != new.get("ota") and new.get("version") is not None:
                        self._add(name, "confirmed" if new["ota"] == "valid" else "state",
                                  f"v{new['version']} · {new['ota']}")
                    elif not new.get("secure", True) and old.get("state") != new.get("state"):
                        self._add(name, "connection", f"{new['state']}")
        return parsed

    def unavailable(self, message: str):
        with self.lock:
            if self.error != message:
                self._add("fleet", "connection", message)
            self.error = message

    def data(self):
        with self.lock:
            self._read_existing() # includes events appended by the separate one-shot OTA sender
            return {"connected": self.error is None, "error": self.error,
                    "last_seen": self.last_seen, "snapshot": self.snapshot,
                    "events": list(reversed(self.events))}


def poll(log: StatusLog, interval: float = 8):
    opener = build_opener(ProxyHandler({}))  # never forward demo traffic through proxy
    while True:
        if not demo_ip():
            log.unavailable("Mac is not on OTA-CLASS-DEMO (192.168.4.x)")
        else:
            try:
                with opener.open(CONTROLLER_URL, timeout=20) as response:
                    raw = response.read(2049).decode("utf-8", "strict")
                log.observe(raw)
            except (OSError, URLError, UnicodeError, ValueError) as exc:
                log.unavailable("Controller status unavailable; check power and Wi-Fi")
        time.sleep(interval)


def handler_for(log: StatusLog):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/api/state":
                body = json.dumps(log.data(), ensure_ascii=True).encode("utf-8")
                kind = "application/json; charset=utf-8"
            elif path in {"/", "/index.html", "/style.css", "/app.js"}:
                asset = ASSETS / ("index.html" if path == "/" else path[1:])
                body = asset.read_bytes()
                kind = {".html": "text/html", ".css": "text/css", ".js": "text/javascript"}[asset.suffix] + "; charset=utf-8"
            else:
                self.send_error(404, "Not found")
                return
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'self'; connect-src 'self'; script-src 'self'; style-src 'self'; base-uri 'none'; object-src 'none'")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            self.send_error(405, "Read-only log; firmware upload is not available here")

        def log_message(self, format, *args):
            pass  # do not flood the terminal with 2-second browser polling

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765, help="localhost browser port (default 8765)")
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("port must be 1024..65535")
    log = StatusLog()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler_for(log))
    threading.Thread(target=poll, args=(log,), daemon=True).start()
    print(f"Read-only OTA log: http://127.0.0.1:{args.port}/", flush=True)
    print("This page never uploads firmware. Stop with Ctrl-C.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
