"""Ed25519 signatures for the OTA1 binary manifest (109 bytes). Never commit a private key.

Wire format: b'OTA1' + role:u8 + version:u32le + image_size:u32le +
sha256(image):32 + ed25519_signature(previous_45_bytes):64.
"""
import argparse
import hashlib
import os
from pathlib import Path
import struct

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

HEADER = struct.Struct("<4sBII32s")
MANIFEST_SIZE = HEADER.size + 64
MAX_IMAGE = 0x140000


def digest_image(path: Path):
    size = 0
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(8192):
            size += len(chunk)
            if size > MAX_IMAGE:
                raise ValueError("Firmware exceeds the 1.25 MB OTA slot")
            sha.update(chunk)
    if size == 0:
        raise ValueError("Image is empty")
    return size, sha.digest()


def sign_image(image: Path, role: int, version: int, private_key: Ed25519PrivateKey) -> bytes:
    if role not in (0, 1, 2) or not 0 < version <= 0xFFFFFFFF:
        raise ValueError("Role must be 0..2; version must be a positive uint32")
    length, sha = digest_image(image)
    header = HEADER.pack(b"OTA1", role, version, length, sha)
    return header + private_key.sign(header)


def verify_image(image: Path, manifest: bytes, public_key: Ed25519PublicKey, expected_role: int,
                 current_version: int) -> tuple[int, int]:
    if len(manifest) != MANIFEST_SIZE:
        raise ValueError("Manifest must be exactly 109 bytes")
    magic, role, version, length, digest = HEADER.unpack(manifest[:HEADER.size])
    if magic != b"OTA1" or role != expected_role or version <= current_version:
        raise ValueError("Wrong format, role or non-increasing version")
    # Authenticate metadata first: never trust the image hash or version without its signature.
    try:
        public_key.verify(manifest[HEADER.size:], manifest[:HEADER.size])
    except InvalidSignature as exc:
        raise ValueError("Invalid Ed25519 signature") from exc
    actual_length, actual_digest = digest_image(image)
    if actual_length != length or actual_digest != digest:
        raise ValueError("Firmware length or SHA-256 does not match signed metadata")
    return role, version


def make_keys(private_path: Path, public_path: Path, header_path: Path):
    for path in (private_path, public_path, header_path):
        if path.exists():
            raise FileExistsError(f"Refusing to overwrite existing key file: {path}")
    key = Ed25519PrivateKey.generate()
    pub = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    private_path.parent.mkdir(parents=True, exist_ok=True)
    private_data = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                     serialization.NoEncryption())
    fd = os.open(private_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(private_data)
    public_path.write_bytes(pub)
    header_path.write_text("// Public key ONLY. Keep the matching private key off devices and out of Git.\n"
                           "#pragma once\n#include <stdint.h>\n"
                           "static const uint8_t OTA_TRUSTED_PUBLIC_KEY[32] = {\n    "
                           + ", ".join(f"0x{x:02x}" for x in pub) + "\n};\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    keys = sub.add_parser("keygen")
    keys.add_argument("--private", type=Path, default=Path("private_keys/demo.pem"))
    keys.add_argument("--public", type=Path, default=Path("private_keys/demo_public.bin"))
    keys.add_argument("--header", type=Path, default=Path("TrustedPublicKey.h"))
    sign = sub.add_parser("sign")
    sign.add_argument("--private", type=Path, default=Path("private_keys/demo.pem"))
    sign.add_argument("--image", type=Path, required=True)
    sign.add_argument("--role", type=int, choices=(0, 1, 2), required=True)
    sign.add_argument("--version", type=int, required=True)
    sign.add_argument("--output", type=Path)
    verify = sub.add_parser("verify")
    verify.add_argument("--public", type=Path, default=Path("private_keys/demo_public.bin"))
    verify.add_argument("--image", type=Path, required=True)
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--role", type=int, choices=(0, 1, 2), required=True)
    verify.add_argument("--current-version", type=int, required=True)
    args = parser.parse_args()
    if args.action == "keygen":
        make_keys(args.private, args.public, args.header)
        print("Key pair created. NEVER commit", args.private, "; public header:", args.header)
    elif args.action == "sign":
        key = serialization.load_pem_private_key(args.private.read_bytes(), password=None)
        if not isinstance(key, Ed25519PrivateKey):
            raise ValueError("Not an Ed25519 private key")
        result = sign_image(args.image, args.role, args.version, key)
        output = args.output or Path(str(args.image) + ".manifest")
        output.write_bytes(result)
        print(f"Wrote {output}: role={args.role} version={args.version} length={len(result)} bytes")
    else:
        key = Ed25519PublicKey.from_public_bytes(args.public.read_bytes())
        role, version = verify_image(args.image, args.manifest.read_bytes(), key, args.role, args.current_version)
        print(f"VALID: role={role} version={version}")


if __name__ == "__main__":
    main()
