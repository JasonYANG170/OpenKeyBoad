#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Guide a wired AK650 matrix test without changing its keyboard reports."""

import argparse
import ctypes
import json
from pathlib import Path
import sys
import tkinter as tk
from tkinter import messagebox, ttk

import hid


BOARD = Path(__file__).resolve().parent
IDLE, WAIT_RELEASE, ARMED, CAPTURED, MULTIPLE = range(5)
LABELS = {
    "BSPC": "Backspace", "CAPS": "Caps Lock", "ENT": "Enter", "LSFT": "左 Shift",
    "RSFT": "右 Shift", "LCTL": "左 Ctrl", "LGUI": "Win", "LALT": "左 Alt",
    "SPC": "空格", "RALT": "右 Alt", "FN": "Fn", "LEFT": "←", "DOWN": "↓",
    "UP": "↑", "RGHT": "→", "PGUP": "PgUp", "PGDN": "PgDn", "DEL": "Del",
    "MINS": "-", "EQL": "=", "LBRC": "[", "RBRC": "]", "BSLS": "\\",
    "SCLN": ";", "QUOT": "'", "COMM": ",", "DOT": ".", "SLSH": "/",
    "KNOB": "按压旋钮",
}


class MatrixReader:
    def __init__(self):
        devices = [
            device for device in hid.enumerate(0x05AC, 0x024F)
            if device["product_string"] == "AK650 QMK Reference"
            and device["usage_page"] == 0xFF60 and device["usage"] == 0x61
        ]
        if len(devices) != 1:
            raise RuntimeError("请通过 USB 接入一把 AK650，并把连接拨杆放到有线模式。")
        if devices[0]["release_number"] not in (0x26, 0x31):
            raise RuntimeError("当前固件没有矩阵测试接口，需要烧录矩阵测试版。")
        self.device = hid.device()
        self.device.open_path(devices[0]["path"])

    def request(self, command):
        query = bytes((0xE1, 0x65, 0xA7, command))
        if self.device.write(b"\0" + query.ljust(32, b"\0")) != 33:
            raise OSError("AK650 HID 写入失败")
        reply = bytes(self.device.read(32, 250))
        if len(reply) != 32 or reply[:4] != query:
            raise OSError("AK650 没有返回有效的矩阵测试报告")
        return reply[4:7]


class MatrixTest:
    def __init__(self, root, reader, output):
        self.root = root
        self.reader = reader
        self.output = output
        self.keys = json.loads((BOARD / "layout.json").read_text(encoding="utf-8"))
        self.keys.insert(14, {"label": "KNOB", "x": 16.25, "y": 0, "w": 1.65})
        self.results = []
        self.running = False
        self.armed = False
        self.notice = tk.StringVar(value="准备好后点击开始。每次只按一颗键，停一下再松开。")
        self.prompt = tk.StringVar()

        root.title("AK650 按键矩阵测试")
        root.resizable(False, False)
        frame = ttk.Frame(root, padding=18)
        frame.grid(sticky="nsew")
        ttk.Label(frame, textvariable=self.prompt, font=("Microsoft YaHei UI", 17, "bold")).grid(sticky="w")
        ttk.Label(frame, textvariable=self.notice).grid(sticky="w", pady=(5, 12))
        self.canvas = tk.Canvas(frame, width=935, height=258, bg="#f4f5f7", highlightthickness=0)
        self.canvas.grid(sticky="w")
        self.canvas.bind("<Key>", lambda event: "break" if self.running else None)
        controls = ttk.Frame(frame)
        controls.grid(sticky="w", pady=(13, 0))
        self.start_button = ttk.Button(controls, text="开始", command=self.toggle)
        self.start_button.pack(side="left", padx=(0, 8))
        self.skip_button = ttk.Button(controls, text="跳过这颗键", command=self.skip)
        self.skip_button.pack(side="left", padx=(0, 8))
        self.back_button = ttk.Button(controls, text="重测上一颗", command=self.back)
        self.back_button.pack(side="left", padx=(0, 8))
        ttk.Button(controls, text="退出并保存", command=self.close).pack(side="left")
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.update_idletasks()
        user32 = ctypes.WinDLL("user32")
        user32.GetAncestor.argtypes = (ctypes.c_void_p, ctypes.c_uint)
        user32.GetAncestor.restype = ctypes.c_void_p
        user32.GetForegroundWindow.restype = ctypes.c_void_p
        self.get_foreground = user32.GetForegroundWindow
        self.window = user32.GetAncestor(root.winfo_id(), 2)
        self.draw()
        root.after(60, self.poll)

    def draw(self):
        index = len(self.results)
        self.canvas.delete("all")
        for i, key in enumerate(self.keys):
            x, y = 12 + 50 * key["x"], 11 + 49 * key["y"]
            width = 50 * key.get("w", 1) - 4
            if i < index:
                fill = "#d4eddd" if self.results[i] is not None else "#f6e5ba"
            else:
                fill = "#a6d4ff" if i == index else "#ffffff"
            self.canvas.create_rectangle(x, y, x + width, y + 44, fill=fill, outline="#b6bdc8")
            self.canvas.create_text(x + width / 2, y + 22, text=LABELS.get(key["label"], key["label"]))
        if index == len(self.keys):
            self.prompt.set(f"已完成 {len(self.keys)} 个位置的测试")
        else:
            label = self.keys[index]["label"]
            self.prompt.set(f"第 {index + 1} / {len(self.keys)} 颗   {LABELS.get(label, label)}")
        self.skip_button.config(state="normal" if index < len(self.keys) else "disabled")
        self.back_button.config(state="normal" if index else "disabled")
        self.start_button.config(state="normal" if index < len(self.keys) else "disabled")

    def save(self):
        result = {key["label"]: mark for key, mark in zip(self.keys, self.results)}
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def cancel(self):
        if self.armed:
            self.armed = False
            try:
                self.reader.request(2)
            except OSError:
                # An outstanding request expires on the device after 30 seconds.
                pass

    def toggle(self):
        self.running = not self.running
        self.start_button.config(text="暂停" if self.running else "继续")
        self.notice.set("请按蓝色标出的实体键。" if self.running else "已暂停。可以正常打字。")
        if self.running:
            self.canvas.focus_set()
        else:
            self.cancel()

    def advance(self, mark):
        self.results.append(mark)
        self.save()
        self.draw()
        if len(self.results) == len(self.keys):
            self.running = False
            self.start_button.config(text="继续")
            self.notice.set(f"结果已保存到 {self.output.name}")

    def skip(self):
        self.cancel()
        self.advance(None)
        self.canvas.focus_set()

    def back(self):
        self.cancel()
        self.results.pop()
        self.save()
        self.draw()
        self.notice.set("已回到上一颗键。")
        self.canvas.focus_set()

    def poll(self):
        try:
            if self.running and self.get_foreground() == self.window:
                if not self.armed:
                    self.reader.request(1)
                    self.armed = True
                state, row, col = self.reader.request(0)
                if state == CAPTURED:
                    self.armed = False
                    mark = [row, col]
                    if mark in self.results:
                        earlier = self.keys[self.results.index(mark)]["label"]
                        self.notice.set(f"矩阵 {row},{col} 已记录给 {earlier}，请重按当前提示键。")
                    else:
                        self.advance(mark)
                elif state == MULTIPLE:
                    self.armed = False
                    self.notice.set("同时按到了多颗键，请全部松开后重试。")
                elif state == IDLE:
                    self.armed = False
                    self.toggle()
                    self.notice.set("等待按键超时，点击继续可恢复。")
            else:
                self.cancel()
        except (OSError, ValueError) as exc:
            self.cancel()
            self.running = False
            self.start_button.config(text="继续")
            self.notice.set(f"测试暂停。{exc}")
        self.root.after(60, self.poll)

    def close(self):
        try:
            self.cancel()
            if self.results:
                self.save()
        finally:
            self.reader.device.close()
            self.root.destroy()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("AK650-matrix-observed.json"))
    parser.add_argument("--probe", action="store_true", help="check the test interface without opening a window")
    args = parser.parse_args()
    if args.probe:
        reader = MatrixReader()
        try:
            print(f"AK650 matrix endpoint is available (state {reader.request(0)[0]})")
        finally:
            reader.device.close()
        return
    root = tk.Tk()
    try:
        MatrixTest(root, MatrixReader(), args.output.resolve())
    except (OSError, RuntimeError) as exc:
        messagebox.showerror("AK650 矩阵测试", str(exc), parent=root)
        root.destroy()
        sys.exit(1)
    root.mainloop()


if __name__ == "__main__":
    main()
