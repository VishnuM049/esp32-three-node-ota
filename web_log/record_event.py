#!/usr/bin/env python3
"""Record an OTA sender's *actual* result for the Mac-local, read-only log.

This is local presentation evidence, not a tamper-proof audit trail.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path

LOG = Path(__file__).resolve().parent.parent / "noise_experiments" / "web_log_events.jsonl"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("node", choices=("controller", "edge1", "edge2"))
    parser.add_argument("version", type=int)
    parser.add_argument("result", choices=("started", "accepted", "confirmed", "ambiguous"))
    args = parser.parse_args()
    if not 1 <= args.version <= 1000:
        parser.error("bad firmware version")
    descriptions = {
        "started": "Signed image upload started (result not yet known)",
        "accepted": "Signed transfer accepted; next boot not yet confirmed",
        "confirmed": "New firmware boot confirmed valid",
        "ambiguous": "No confirmed result; inspect status before any action",
    }
    event = {"at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
             "node": args.node, "kind": "upload", "detail": f"v{args.version} · {descriptions[args.result]}"}
    LOG.parent.mkdir(exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    fd = os.open(LOG, flags, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, ensure_ascii=True, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
