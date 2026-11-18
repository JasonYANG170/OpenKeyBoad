#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build AK650 definitions from the measured switch matrix and donor drivers."""

import json
from itertools import groupby
from pathlib import Path

BOARD = Path(__file__).resolve().parent
VID = "0x05AC"
PID = "0x024F"
DONOR = BOARD.parent / "ak820pro"
REFERENCE = BOARD / "reference"

# Matrix coordinates measured on the wired AK650, including the knob press.
MATRIX_KEYS = (
    (None,) * 15,
    ("ESC", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "MINS", "EQL", "BSPC", "KNOB"),
    ("TAB", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "LBRC", "RBRC", "BSLS", "DEL"),
    ("CAPS", "A", "S", "D", "F", "G", "H", "J", "K", "L", "SCLN", "QUOT", None, "ENT", "PGUP"),
    ("LSFT", None, "Z", "X", "C", "V", "B", "N", "M", "COMM", "DOT", "SLSH", "RSFT", "UP", "PGDN"),
    ("LCTL", "LGUI", "LALT", None, None, None, "SPC", None, None, None, "RALT", "FN", "LEFT", "DOWN", "RGHT"),
)

# Keep the LED channels verified by the all-keys RGB test. The RGB scan uses
# its own electrical coordinates even though QMK calls the field "matrix".
RGB_CELLS = {"ESC": [0, 0], "DEL": [0, 13], "PGUP": [2, 14], "PGDN": [3, 14], "FN": [5, 9]}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def via_layout(keys):
    keymap = []
    for _, physical_row in groupby(keys, key=lambda key: key["y"]):
        row = []
        x = 0
        for key in physical_row:
            width = key.get("w", 1)
            geometry = {}
            if key["x"] != x:
                geometry["x"] = key["x"] - x
            if width != 1:
                geometry["w"] = width
            if geometry:
                row.append(geometry)
            label = ",".join(str(index) for index in key["matrix"])
            if "encoder" in key:
                label += "\n" * 9 + f"e{key['encoder']}"
            row.append(label)
            x = key["x"] + width
        keymap.append(row)
    return keymap


def generate():
    keyboard = read_json(DONOR / "keyboard.json")
    via = read_json(DONOR / "via.json")
    layout = read_json(BOARD / "layout.json")
    layout.insert(14, {"label": "KNOB", "x": 16.5, "y": 0, "encoder": 0})

    matrix = {
        label: [row, col]
        for row, matrix_row in enumerate(MATRIX_KEYS)
        for col, label in enumerate(matrix_row)
        if label is not None
    }
    if set(matrix) != {key["label"] for key in layout} or len(matrix) != len(layout):
        raise ValueError("The measured mapping must cover every AK650 key and knob exactly once")
    rgb_cells = {tuple(led["matrix"]) for led in keyboard["rgb_matrix"]["layout"]}
    led_layout = []
    for key in layout:
        key["matrix"] = matrix[key["label"]]
        if key["label"] == "KNOB":
            continue
        rgb_cell = RGB_CELLS.get(key["label"], key["matrix"])
        if tuple(rgb_cell) not in rgb_cells:
            raise ValueError(f"Missing donor RGB channel for {key['label']}")
        # QMK effects use the centre of each key on the 224 × 64 matrix plane.
        x = key["x"] + key.get("w", 1) / 2
        led_layout.append(
            {"flags": 4, "matrix": rgb_cell, "x": round(x * 224 / 16), "y": key["y"] * 16}
        )

    keyboard["keyboard_name"] = "AK650 QMK Reference"
    keyboard["url"] = "https://ajazzstore.com/products/ajazz-ak650"
    keyboard["usb"] = {"vid": VID, "pid": PID, "device_version": "0.3.9"}
    keyboard["layouts"] = {"LAYOUT_67_ansi": {"layout": layout}}
    keyboard["rgb_matrix"]["layout"] = led_layout
    keyboard["indicators"] = {"caps_lock": "B0", "on_state": 1}
    # The AK650 lit all keys with this steady white setting during the wired test.
    keyboard["rgb_matrix"]["default"].update(on=True, sat=0, val=32)
    # Keep QMK's matrix-based bootloader shortcut disabled for the reference layout.
    keyboard["features"]["bootmagic"] = False

    via["name"] = keyboard["keyboard_name"]
    via["vendorId"] = VID
    via["productId"] = PID
    via["layouts"] = {"keymap": via_layout(layout)}
    via["customKeycodes"].extend([
        {"name": "AK650_FN_ESC", "title": "Grave / Shift: toggle number row", "shortName": "Grave/Fn"},
        {"name": "AK650_RESET", "title": "Restore defaults (hold 3 seconds)", "shortName": "Reset"},
        {"name": "AK650_ZH", "title": "Screen language: Chinese", "shortName": "Chinese"},
        {"name": "AK650_EN", "title": "Screen language: English", "shortName": "English"},
        {"name": "AK650_ENCODER", "title": "Switch knob between screen and volume", "shortName": "Knob Mode"},
    ])
    for file, data in (("keyboard.json", keyboard), ("via.json", via)):
        (REFERENCE / file).write_text(json.dumps(data, indent=4) + "\n", encoding="utf-8")


if __name__ == "__main__":
    generate()
