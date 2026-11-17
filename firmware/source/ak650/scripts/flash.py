#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Flash an AK650 VIA release image through the SN32 ROM bootloader."""

import argparse
import hashlib
from pathlib import Path
import struct
import sys
import time
import hid

REPORT_SIZE = 64
ACK = b"\xfa" * 4
GET_VERSION, SET_PROGRAMMING_OPTION, ERASE, PROGRAM, CHECKSUM, RUN = 1, 3, 4, 5, 6, 7
FIRMWARE = Path(__file__).resolve().parents[1] / "firmware"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("image", type=Path, nargs="?", default=FIRMWARE / "AK650-VIA-0.3.5.bin")
parser.add_argument("--checksums", type=Path, default=FIRMWARE / "SHA256SUMS",
                    help="checksum file for the image")
args = parser.parse_args()
path = args.image
firmware = path.read_bytes()
entries = (line.split(maxsplit=1) for line in args.checksums.read_text(encoding="ascii").splitlines())
matches = [entry[0] for entry in entries if len(entry) == 2 and entry[1] == path.name]
if len(matches) != 1:
    parser.error(f"Expected one checksum for {path.name} in {args.checksums}")
if len(firmware) != 256 * 1024 or hashlib.sha256(firmware).hexdigest() != matches[0]:
    raise SystemExit("The AK650 image did not pass size and SHA-256 verification")
checksum = sum(value for (value,) in struct.iter_unpack("<H", firmware)) & 0xFFFF

devices = hid.enumerate(0x0C45, 0x7140)
if len(devices) != 1:
    raise SystemExit(f"Expected one AK650 wired ISP interface, got {len(devices)}")

device = hid.device()
device.open_path(devices[0]["path"])
stage = "preflight"

def send(payload):
    report = bytes((0,)) + payload
    if len(report) != REPORT_SIZE + 1 or device.send_feature_report(report) != len(report):
        raise RuntimeError("HID feature write was not accepted")

def receive(opcode, timeout=12.0):
    expected = bytes((opcode, 0xAA, 0x55, 0))
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = bytes(device.get_feature_report(0, REPORT_SIZE + 1))
            if len(last) == REPORT_SIZE + 1 and last[1:5] == expected and last[5:9] == ACK:
                return last[1:]
        except OSError as exc:
            last = str(exc)
        time.sleep(0.075)
    if isinstance(last, bytes):
        last = last[:20].hex(" ")
    raise RuntimeError(f"ISP opcode {opcode:02X} did not return a verified ACK: {last}")

def command(opcode, fields=()):
    packet = bytearray(REPORT_SIZE)
    packet[:4] = bytes((opcode, 0xAA, 0x55, 0))
    for offset, fmt, value in fields:
        struct.pack_into(fmt, packet, offset, value)
    send(packet)

def read_checksum():
    command(CHECKSUM)
    return struct.unpack_from("<H", receive(CHECKSUM), 8)[0]

try:
    command(GET_VERSION)
    response = receive(GET_VERSION)
    if response[8:12] != bytes((0x20, 5, 0, 0)):
        raise RuntimeError(f"Unexpected ISP chip family: {response[8:12].hex()}")
    option, protection = struct.unpack_from("<HH", response, 12)
    if protection not in (0x5A5A, 0xFFFF, 0):
        raise RuntimeError(f"Unexpected code security mode: {protection:04X}")
    print(f"AK650 / SN32F29x, 256 KiB. Original checksum {read_checksum():04X}. Image checksum {checksum:04X}.", flush=True)
    if protection == 0x5A5A:
        # Standard SonixFlasherC programming option command, before erase.
        stage = "standard programming setup"
        command(SET_PROGRAMMING_OPTION, ((4, "<H", option), (6, "<H", 0xFFFF)))
        receive(SET_PROGRAMMING_OPTION)
        time.sleep(1)

    stage = "erase and blank verification"
    print("Erasing application flash", flush=True)
    command(ERASE, ((4, "<H", 0), (8, "<H", 256)))
    erase_response = receive(ERASE, timeout=35)
    if struct.unpack_from("<H", erase_response, 8)[0] != 0 or read_checksum() != 0:
        raise RuntimeError("Device did not pass the SN32F29x blank checksum check")

    stage = "programming"
    chunks = len(firmware) // REPORT_SIZE
    command(PROGRAM, ((4, "<I", 0), (8, "<I", chunks)))
    receive(PROGRAM)
    for i in range(chunks):
        start = i * REPORT_SIZE
        send(firmware[start:start + REPORT_SIZE])
        if (i + 1) % 512 == 0:
            print(f"Transferred {i + 1}/{chunks} reports", flush=True)

    stage = "checksum verification"
    result = receive(PROGRAM, timeout=35)
    if result[-4:] != firmware[-4:]:
        raise RuntimeError("Device final chunk does not match the image")
    if struct.unpack_from("<H", result, 8)[0] != checksum or read_checksum() != checksum:
        raise RuntimeError("Checksum verification failed")
    print(f"Verified programmed flash checksum: {checksum:04X}", flush=True)

    stage = "reboot"
    command(RUN)
    print("Reboot to application requested", flush=True)
except Exception as exc:
    print(f"Flash stopped during {stage}: {exc}", file=sys.stderr, flush=True)
    sys.exit(1)
finally:
    device.close()
