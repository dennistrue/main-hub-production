#!/usr/bin/env python3
"""Generate the wired factory-provisioning blob for the ESP32 factory partition."""

from __future__ import annotations

import argparse
import binascii
import os
import struct
import sys


MAGIC = 0x46504346  # 'FCPF' => Factory Config Payload
VERSION = 1
SERIAL_FIELD_LEN = 32
PASSWORD_FIELD_LEN = 64
RESERVED_LEN = 48
HEADER_STRUCT = struct.Struct("<IHH")
CRC_STRUCT = struct.Struct("<I")


def sanitize_serial(value: str) -> str:
    filtered = []
    for char in value:
        if char.isalnum() or char in "_-":
            filtered.append(char)
    sanitized = "".join(filtered)[:28]
    if not sanitized:
        raise ValueError("Serial suffix must contain at least one valid character (alphanumeric/_/-).")
    return sanitized


def validate_password(value: str) -> str:
    if not (8 <= len(value) <= 63):
        raise ValueError("Password must be between 8 and 63 characters.")
    if any(ord(ch) < 32 or ord(ch) > 126 for ch in value):
        raise ValueError("Password must contain printable ASCII characters only.")
    return value


def build_payload(serial_suffix: str, password: str) -> bytes:
    flags = 0x01  # reserved for future use
    serial_bytes = serial_suffix.encode("ascii")
    password_bytes = password.encode("ascii")

    body = bytearray()
    body.extend(HEADER_STRUCT.pack(MAGIC, VERSION, flags))
    body.extend(serial_bytes.ljust(SERIAL_FIELD_LEN, b"\x00"))
    body.extend(password_bytes.ljust(PASSWORD_FIELD_LEN, b"\x00"))
    body.extend(b"\x00" * RESERVED_LEN)

    crc = binascii.crc32(body) & 0xFFFFFFFF
    body.extend(CRC_STRUCT.pack(crc))
    return bytes(body)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Factory serial suffix (alphanumeric/_/-, <=28 chars).")
    parser.add_argument("--password", required=True, help="SoftAP password (8-63 printable ASCII).")
    parser.add_argument("--output", required=True, help="Output file path for the partition image.")
    parser.add_argument(
        "--partition-size",
        default="0x10000",
        help="Total partition size in bytes (default: 0x10000).",
    )
    args = parser.parse_args(argv)

    try:
        partition_size = int(str(args.partition_size), 0)
    except ValueError as exc:
        raise SystemExit(f"Invalid partition size: {args.partition_size}") from exc
    if partition_size <= 0:
        raise SystemExit("Partition size must be positive.")

    try:
        serial_suffix = sanitize_serial(args.serial)
    except ValueError as exc:
        raise SystemExit(f"Serial validation failed: {exc}") from exc

    try:
        password = validate_password(args.password)
    except ValueError as exc:
        raise SystemExit(f"Password validation failed: {exc}") from exc

    payload = build_payload(serial_suffix, password)
    if len(payload) > partition_size:
        raise SystemExit(
            f"Payload ({len(payload)} bytes) does not fit in partition ({partition_size} bytes). "
            "Increase the partition size."
        )

    blob = bytearray(b"\xFF" * partition_size)
    blob[: len(payload)] = payload

    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "wb") as fh:
        fh.write(blob)

    print(
        f"Wrote factory payload: serial={serial_suffix} password_len={len(password)} "
        f"size={partition_size} bytes -> {args.output}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
