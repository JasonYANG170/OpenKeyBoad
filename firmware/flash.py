#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Flash the RS2 3.0 application through its Sonix ROM ISP."""

import argparse
import hashlib
from pathlib import Path
import struct
import sys
import time


FIRMWARE = Path(__file__).resolve().parents[1] / "firmware"
IMAGE = FIRMWARE / "RS2-VIA-0.3.0.bin"
IMAGE_SIZE = 256 * 1024
REPORT_SIZE = 64
GET_VERSION, ERASE, PROGRAM, CHECKSUM, RUN = 1, 4, 5, 6, 7
HEADER = b"\xaa\x55\x00"


def read_image(path, manifest):
    entries = (line.split(maxsplit=1) for line in manifest.read_text(encoding="ascii").splitlines())
    matches = [entry[0] for entry in entries if len(entry) == 2 and entry[1] == path.name]
    image = path.read_bytes()
    if len(matches) != 1 or len(image) != IMAGE_SIZE or hashlib.sha256(image).hexdigest() != matches[0]:
        raise RuntimeError(f"Image size or SHA-256 verification failed for {path.name}")
    stack, reset = struct.unpack_from("<II", image)
    if not 0x20000000 < stack <= 0x20008000 or (reset & 1) == 0 or reset >= IMAGE_SIZE:
        raise RuntimeError("Invalid SN32F29x Cortex-M vector table")
    return image


def send(device, payload):
    report = b"\0" + payload.ljust(REPORT_SIZE, b"\0")
    if len(report) != REPORT_SIZE + 1 or device.send_feature_report(report) != len(report):
        raise RuntimeError("The ISP interface did not accept the report")


def receive(device, opcode, timeout=12):
    expected = bytes((opcode,)) + HEADER + b"\xfa" * 4
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            report = bytes(device.get_feature_report(0, REPORT_SIZE + 1))
            if len(report) == REPORT_SIZE + 1 and report[1:9] == expected:
                return report[1:]
        except OSError:
            pass
        time.sleep(0.075)
    raise RuntimeError(f"No verified ACK for ISP command {opcode:02X}")


def command(device, opcode, fields=b"", timeout=12):
    send(device, bytes((opcode,)) + HEADER + fields)
    return receive(device, opcode, timeout)


def read_checksum(device):
    return struct.unpack_from("<H", command(device, CHECKSUM), 8)[0]


def flash(device, image):
    info = command(device, GET_VERSION)
    if info[8:12] != b"\x20\x05\x00\x00":
        raise RuntimeError("Unexpected ISP chip signature")
    protection = struct.unpack_from("<H", info, 14)[0]
    if protection not in (0x5A5A, 0xFFFF, 0):
        raise RuntimeError(f"Unexpected ISP code-protection status {protection:04X}")
    target_sum = sum(value for (value,) in struct.iter_unpack("<H", image)) & 0xFFFF
    print(f"SN32F29x ISP, current checksum {read_checksum(device):04X}, image {target_sum:04X}", flush=True)

    # Preserve the device's code-protection option while replacing the application.
    erased = command(device, ERASE, struct.pack("<II", 0, 256), timeout=35)
    if struct.unpack_from("<H", erased, 8)[0] or read_checksum(device):
        raise RuntimeError("Application flash did not pass the blank checksum check")

    chunks = len(image) // REPORT_SIZE
    command(device, PROGRAM, struct.pack("<II", 0, chunks))
    for chunk in range(chunks):
        offset = chunk * REPORT_SIZE
        send(device, image[offset:offset + REPORT_SIZE])
        if (chunk + 1) % 512 == 0:
            print(f"Transferred {chunk + 1}/{chunks} reports", flush=True)
    result = receive(device, PROGRAM, timeout=35)
    ack_sum = struct.unpack_from("<H", result, 8)[0]
    if result[-4:] != image[-4:] or ack_sum != target_sum or read_checksum(device) != target_sum:
        raise RuntimeError("Programmed image did not pass the checksum check")
    print(f"Verified programmed flash checksum {target_sum:04X}", flush=True)
    send(device, bytes((RUN,)) + HEADER)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, nargs="?", default=IMAGE)
    parser.add_argument("--checksums", type=Path, default=FIRMWARE / "SHA256SUMS")
    args = parser.parse_args()
    image = read_image(args.image, args.checksums)
    import hid

    devices = [
        item for item in hid.enumerate(0x0C45, 0x7140)
        if (item["usage_page"], item["usage"]) == (0xFF13, 1)
    ]
    if len(devices) != 1:
        raise RuntimeError(f"Expected one RS2 Sonix ROM ISP interface, got {len(devices)}")
    device = hid.device()
    device.open_path(devices[0]["path"])
    try:
        flash(device, image)
    finally:
        device.close()


if __name__ == "__main__":
    try:
        main()
    except (ImportError, OSError, RuntimeError) as error:
        sys.exit(str(error))
