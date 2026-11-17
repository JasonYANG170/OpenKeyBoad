# OpenKeyBoad

[简体中文](README.md)

| Item | Support |
| --- | --- |
| Keyboards | [JamesDonkey RS2 3.0](https://github.com/JasonYANG170/JamesDonkey-RS2-QMK), [AJAZZ AK650](https://github.com/JasonYANG170/AJAZZ-AK650-QMK) |
| Clients | Windows, macOS, Linux, Android, iOS, Web |
| Stack | Flutter 3.50 / Dart 3.14, VIA 12, HID |
| Configuration | Four layers, encoder, chords, per-key RGB, animated lighting |
| Keyboard display | System lyrics, weather, CPU / RAM / GPU / disk space, clock sync |

## Usage

Download a client from [Releases](https://github.com/JasonYANG170/OpenKeyBoad/releases). Connect the keyboard in wired mode, scan, edit and apply. In Lighting → Per-key colors, select keys directly on the physical layout. HEX colors, fill, import and export are supported.

Windows portable: run `KeyboardControl.exe`. `Connect-Phone.cmd`, or the desktop bridge's `--lan` option, prints a complete link for phones on the same LAN. iOS uses this link to connect through the desktop. The link contains a temporary authorization token; share it only with trusted devices. Android also supports USB OTG.

The Online features switch reads the player's title, artist and position, automatically matches timed lyrics with LRCLIB, and sends playback state, progress and scrolling text to the keyboard screen. Windows uses system media sessions; macOS supports Music / Spotify; Linux requires `playerctl`. Players must expose metadata. Unavailable timed lyrics show a status message.

Online features are off by default. Enabling the master switch starts lyrics, weather and monitoring together; disabling it stops all three. The encoder and Show buttons only select the visible keyboard page. Periodic transfers do not activate the global loading indicator.

Enter a city to display weather icons, temperature, humidity and update time on the keyboard, refreshed every 15 minutes. Monitoring and lyrics require the desktop connection. Missing GPU counters show `--`. Phones connected through the bridge show desktop statistics. Static per-key colors remain in RAM until reboot; chords persist in VIA macros.

## Build

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d windows # or macos, linux, an Android / iOS device
```

Desktop USB requires HIDAPI: place `hidapi.dll` beside the Windows executable; run `brew install hidapi` on macOS; install `libhidapi-hidraw0` and `linux/70-keyboard-control.rules` on Linux.

GitHub Actions checks the code and builds all six clients, publishing automatically only after every build succeeds. Android APKs use test signing. iOS IPAs are unsigned and require signing before installation. macOS builds are not notarized. Web accesses keyboards through the desktop bridge. Build the web UI using `flutter build web --release --no-web-resources-cdn`, then run `dart pub get` and `dart run bin/main.dart --lan` inside `bridge/`.

## Firmware

Matching firmware and VIA layouts are in `firmware/`; corresponding sources and pinned build scripts are in `firmware/source/{rs2,ak650}/`. Enter ISP with `Fn+Esc` on RS2 or the display's Flash menu on AK650. Ensure only the intended keyboard is in ISP and select its matching image.

```sh
python -m pip install hidapi
python firmware/flash.py firmware/RS2-VIA-0.3.1.bin --checksums firmware/SHA256SUMS
# AK650: use firmware/AK650-VIA-0.3.6.bin instead
```

GPL-2.0-or-later. Font license: `fonts/OFL.txt`. Weather: [Open-Meteo](https://open-meteo.com/) (free API for non-commercial use). Lyrics: [LRCLIB](https://lrclib.net/).
