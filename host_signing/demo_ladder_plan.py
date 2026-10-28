#!/usr/bin/env python3
"""Select exactly the next signed HTTPS demo image from ONE live controller status.

Read-only planner. The sender performs certificate and image signature checks and
requires human confirmation; this module never sends firmware or changes Wi-Fi.
"""
from __future__ import annotations

import argparse
import re
import sys

CONTROLLER = re.compile(r"\brole=0 version=(\d+) noise=1 tls=1\b")
EDGE = {role: re.compile(rf"\b{role}_secure=v(\d+)_ota2_") for role in ("edge1", "edge2")}
OTA = re.compile(r"\bota=valid\b")


def select_next(status: str, target: str) -> tuple[int, int, int, str, str]:
    """Return role ID, installed version, next version, local image name, HTTPS route."""
    if target not in ("edge1", "edge2", "controller"):
        raise ValueError("Unknown target")
    if len(status) > 2048 or '\n' in status.strip('\n'):
        raise ValueError("Incomplete or suspicious controller status")
    controller = CONTROLLER.search(status)
    edges = {name: expression.search(status) for name, expression in EDGE.items()}
    if not controller or not OTA.search(status) or not all(edges.values()):
        raise ValueError("Require v11+ TLS/Noise controller valid and BOTH edges authenticated/valid")
    c = int(controller[1])
    current_edges = {name: int(match[1]) for name, match in edges.items()}
    if not (11 <= c <= 14) or any(not 9 <= ver <= 12 for ver in current_edges.values()):
        raise ValueError("Unexpected fleet versions; do not guess next image")
    if target == "controller":
        if c >= 14:
            raise ValueError("Prepared controller ladder ends at v14")
        # Edges before controller each round, as in the proven one-shot plan.
        if any(ver < c - 1 for ver in current_edges.values()):
            raise ValueError(f"Both edges must be at least v{c - 1} before controller v{c + 1}")
        return (0, c, c + 1, f"https_controller_v{c + 1}_demo", "update")
    edge_version = current_edges[target]
    if edge_version >= 12:
        raise ValueError(f"Prepared {target} ladder ends at v12")
    role = 1 if target == "edge1" else 2
    return (role, edge_version, edge_version + 1,
            f"{target}_reconnect_v{edge_version + 1}_demo", target)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("edge1", "edge2", "controller"))
    args = parser.parse_args()
    try:
        plan = select_next(sys.stdin.read(), args.target)
    except ValueError as error:
        parser.exit(1, f"STOP: {error}; no upload\n")
    print("\t".join(map(str, plan)))


if __name__ == "__main__":
    main()
