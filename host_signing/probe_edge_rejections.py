"""Header-only negative tests on BOTH secure v4 edges. NO firmware bytes are sent.
Run while all three boards are powered and Mac is joined to OTA-CLASS-DEMO.
"""
from pathlib import Path
import http.client
import re
import socket
import struct

ROOT = Path(__file__).resolve().parent.parent
CONTROLLER = "192.168.4.1"


def status(host, port):
    conn = http.client.HTTPConnection(host, port, timeout=5)
    try:
        conn.request("GET", "/status")
        res = conn.getresponse()
        body = res.read().decode("ascii", "replace").strip()
        if res.status != 200:
            raise RuntimeError(f"Status failed: HTTP {res.status} {body}")
        return body
    finally:
        conn.close()


def reject(host, length, hex_manifest, reason):
    request = (f"POST /update HTTP/1.1\r\nHost: {host}\r\nContent-Length: {length}\r\n"
               + (f"X-OTA-Manifest: {hex_manifest}\r\n" if hex_manifest is not None else "")
               + "Connection: close\r\n\r\n")
    with socket.create_connection((host, 8080), timeout=5) as conn:
        conn.settimeout(5)
        conn.sendall(request.encode("ascii"))
        chunks = []
        while data := conn.recv(2048):
            chunks.append(data)
    response = b"".join(chunks).decode("ascii", "replace")
    if not response.startswith("HTTP/1.1 403 ") or reason not in response:
        raise RuntimeError(f"Expected 403 {reason!r}; got {response[:250]!r}")
    print("PASS:", reason)


def main():
    controller = status(CONTROLLER, 80)
    print("Controller:", controller)
    if "role=0 version=4" not in controller:
        raise RuntimeError("Not secure controller v4; refusing test")
    for role in (1, 2):
        match = re.search(rf"edge{role}=([0-9.]+)", controller)
        if not match or match.group(1) == "0.0.0.0":
            raise RuntimeError(f"Edge{role} is not registered")
        host = match.group(1)
        before = status(host, 8080)
        print(f"Edge{role} before:", before)
        if f"role={role} version=4" not in before:
            raise RuntimeError(f"Edge{role} is not secure v4")
        mine = (ROOT / f"secure_firmware/edge{role}_v4/ota_prototype.ino.bin.manifest").read_bytes()
        other_role = 2 if role == 1 else 1
        wrong = (ROOT / f"secure_firmware/edge{other_role}_v4/ota_prototype.ino.bin.manifest").read_bytes()
        if len(mine) != 109 or len(wrong) != 109:
            raise RuntimeError("Missing 109-byte manifests")
        reject(host, 4, None, "Missing or malformed signed manifest")
        reject(host, struct.unpack_from("<I", wrong, 9)[0], wrong.hex(), "Wrong target role")
        reject(host, struct.unpack_from("<I", mine, 9)[0], mine.hex(), "Old or repeated version")
        forged = bytearray(mine)
        forged[5] = 5  # change signed version without re-signing
        reject(host, struct.unpack_from("<I", forged, 9)[0], forged.hex(), "Invalid developer signature")
        after = status(host, 8080)
        if f"role={role} version=4" not in after:
            raise RuntimeError(f"Edge{role} version changed unexpectedly: {after}")
        print(f"PASS: Edge{role} remains secure v4")
    print("PASS: all header-only negative tests on BOTH edges")


if __name__ == "__main__":
    main()
