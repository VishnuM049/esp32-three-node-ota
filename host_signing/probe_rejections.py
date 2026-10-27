"""Safely exercise metadata rejection on secure controller v3 (no firmware body is sent).

Run while Mac is joined to OTA-CLASS-DEMO. This script never activates an update.
"""
from pathlib import Path
import http.client
import socket
import struct

ROOT = Path(__file__).resolve().parent.parent
HOST = "192.168.4.1"


def get_status():
    conn = http.client.HTTPConnection(HOST, 80, timeout=5)
    try:
        conn.request("GET", "/status")
        response = conn.getresponse()
        body = response.read().decode("ascii", "replace").strip()
        if response.status != 200:
            raise RuntimeError(f"Status request failed: {response.status} {body}")
        return body
    finally:
        conn.close()


def attempt(manifest: bytes, expected_reason: str):
    # Send only headers. The ESP32 must reject before trying to read the image body.
    length = struct.unpack_from("<I", manifest, 9)[0]
    request = (f"POST /update HTTP/1.1\r\nHost: {HOST}\r\nContent-Length: {length}\r\n"
               f"X-OTA-Manifest: {manifest.hex()}\r\nConnection: close\r\n\r\n")
    with socket.create_connection((HOST, 80), timeout=5) as conn:
        conn.settimeout(5)
        conn.sendall(request.encode("ascii"))
        received = bytearray()
        while True:
            data = conn.recv(2048)
            if not data:
                break
            received.extend(data)
    response = received.decode("ascii", "replace")
    if not response.startswith("HTTP/1.1 403 ") or expected_reason not in response:
        raise RuntimeError(f"Unexpected response (wanted 403 {expected_reason!r}): {response[:400]!r}")
    print("PASS:", expected_reason)


def main():
    before = get_status()
    print("Before:", before)
    if "role=0 version=3" not in before:
        raise RuntimeError("Not secure controller v3. Will not test another firmware version.")
    good = (ROOT / "secure_firmware/controller_v4/ota_prototype.ino.bin.manifest").read_bytes()
    wrong_role = (ROOT / "secure_firmware/edge1_v4/ota_prototype.ino.bin.manifest").read_bytes()
    old = (ROOT / "secure_firmware/controller_v3/ota_prototype.ino.bin.manifest").read_bytes()
    if any(len(m) != 109 for m in (good, wrong_role, old)):
        raise RuntimeError("Expected exactly 109-byte manifests")

    bad_signature = bytearray(good)
    bad_signature[-1] ^= 1
    attempt(bytes(bad_signature), "Invalid developer signature")
    attempt(wrong_role, "Wrong target role")
    attempt(old, "Old or repeated version")
    changed_version = bytearray(good)
    changed_version[5] = 5
    attempt(bytes(changed_version), "Invalid developer signature")

    after = get_status()
    print("After: ", after)
    if "role=0 version=3" not in after:
        raise RuntimeError("Controller version changed unexpectedly!")
    print("PASS: all four requests rejected before receiving firmware bytes; controller remains v3")


if __name__ == "__main__":
    main()
