"""Local X25519 identity provisioning for PLANNED Noise KK controller-edge links.

This does NOT implement Noise, change devices, or encrypt OTA. Keep generated
private keys/headers under ignored private_keys/noise/ only; never print secrets.
"""
import argparse
import json
import os
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

ROLES = ("controller", "edge1", "edge2")
IDS = {"controller": 0, "edge1": 1, "edge2": 2}
ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIR = ROOT / "private_keys" / "noise"


def _public(private: X25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def _private_bytes(private: X25519PrivateKey) -> bytes:
    return private.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                 serialization.NoEncryption())


def _write_secret(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as output:
        output.write(data)


def provision(directory: Path) -> dict[str, str]:
    # Check EVERY path before generating or writing any material. Never rotate silently.
    private_files = [directory / f"{role}.x25519" for role in ROLES]
    pins_file = directory / "public_pins.json"
    headers_dir = directory / "generated"
    if any(path.exists() for path in [*private_files, pins_file]) or headers_dir.exists():
        raise FileExistsError("Existing identity/provisioning files: refusing to replace ANY key")
    if directory.is_symlink():
        raise ValueError("Refusing symlinked identity directory")
    directory.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    identities = {role: X25519PrivateKey.generate() for role in ROLES}
    pins = {role: _public(key).hex() for role, key in identities.items()}
    if len(set(pins.values())) != 3:
        raise RuntimeError("Duplicate public identity")
    for role in ROLES:
        _write_secret(directory / f"{role}.x25519", _private_bytes(identities[role]))
    # Public information; kept alongside private material until reviewed/pinned in firmware.
    pins_file.write_text(json.dumps(pins, indent=2, sort_keys=True) + "\n")
    return pins


def _as_c(name: str, data: bytes) -> str:
    return f"static const uint8_t {name}[32] = {{" + ", ".join(f"0x{b:02x}" for b in data) + "};\n"


def emit_header(directory: Path, role: str) -> Path:
    if role not in ROLES:
        raise ValueError("Unknown role")
    pins = json.loads((directory / "public_pins.json").read_text())
    if set(pins) != set(ROLES) or any(len(bytes.fromhex(pins[r])) != 32 for r in ROLES):
        raise ValueError("Incomplete/invalid public pin set")
    private_raw = (directory / f"{role}.x25519").read_bytes()
    if len(private_raw) != 32:
        raise ValueError("Invalid private key length")
    private = X25519PrivateKey.from_private_bytes(private_raw)
    if _public(private).hex() != pins[role]:
        raise ValueError("Private key does not match pinned role; refusing header")
    peer_roles = ("edge1", "edge2") if role == "controller" else ("controller",)
    text = ("// GENERATED SECRET: never commit, print, or share this header.\n"
            "#pragma once\n#include <stdint.h>\n"
            f"#define NOISE_LOCAL_ROLE {IDS[role]}\n")
    text += _as_c("NOISE_LOCAL_PRIVATE", private_raw)
    for peer in peer_roles:
        text += _as_c(f"NOISE_PINNED_{peer.upper()}", bytes.fromhex(pins[peer]))
    outdir = directory / "generated"
    outdir.mkdir(mode=0o700, exist_ok=True)
    output = outdir / f"{role}.h"
    _write_secret(output, text.encode("ascii"))
    return output


def emit_public_header(directory: Path, role: str) -> Path:
    """Public-only role pins for BOTH bootstrap and key-free OTA firmware."""
    if role not in ROLES:
        raise ValueError("Unknown role")
    pins = json.loads((directory / "public_pins.json").read_text())
    if set(pins) != set(ROLES) or any(len(bytes.fromhex(pins[r])) != 32 for r in ROLES):
        raise ValueError("Incomplete public pins")
    peers = ("edge1", "edge2") if role == "controller" else ("controller",)
    text = ("// PUBLIC X25519 pins ONLY. Do not include private key bytes here.\n"
            "#pragma once\n#include <stdint.h>\n"
            f"#define NOISE_LOCAL_ROLE {IDS[role]}\n")
    text += _as_c("NOISE_LOCAL_PUBLIC", bytes.fromhex(pins[role]))
    for peer in peers:
        text += _as_c(f"NOISE_PINNED_{peer.upper()}", bytes.fromhex(pins[peer]))
    outdir = directory / "generated_public"
    outdir.mkdir(mode=0o700, exist_ok=True)
    output = outdir / f"{role}.h"
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    with os.fdopen(fd, "w", encoding="ascii") as stream:
        stream.write(text)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "header", "public-header"))
    parser.add_argument("--directory", type=Path, default=DEFAULT_DIR)
    parser.add_argument("--role", choices=ROLES)
    args = parser.parse_args()
    if args.action == "init":
        if args.role:
            parser.error("--role is only for header generation")
        pins = provision(args.directory)
        print("Three distinct X25519 identities created in ignored local directory:", args.directory)
        print("Public fingerprints (first 12 hex characters, NOT secret):")
        for role, public in pins.items():
            print(f"  {role}: {public[:12]}")
    else:
        if not args.role:
            parser.error(f"{args.action} requires --role")
        if args.action == "header":
            print("Generated ignored secret bootstrap-only header:", emit_header(args.directory, args.role))
        else:
            print("Generated role public pins (no private bytes):", emit_public_header(args.directory, args.role))


if __name__ == "__main__":
    main()
