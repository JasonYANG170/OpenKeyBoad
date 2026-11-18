# OpenKeyBoad

[简体中文](README.md)

| Item | Support |
| --- | --- |
| Keyboards | [JamesDonkey RS2 3.0](https://github.com/JasonYANG170/JamesDonkey-RS2-QMK), [AJAZZ AK650](https://github.com/JasonYANG170/AJAZZ-AK650-QMK) |
| Clients | Windows, macOS, Linux, Android, iOS, Web |
| Stack | Flutter 3.50 / Dart 3.14, VIA 12, HID |
| Configuration | Four layers, encoder, chords, per-key RGB, animated lighting, display preferences, sleep, OS mapping, wireless slots |
| Keyboard display | System lyrics, extended weather, resources, live network speed, Pomodoro, clock sync |

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

Matching firmware and VIA layouts are in `firmware/`; corresponding sources and pinned build scripts are in `firmware/source/{rs2,ak650}/`.


GPL-2.0-or-later. Font license: `fonts/OFL.txt`. Weather: [Open-Meteo](https://open-meteo.com/) (free API for non-commercial use). Lyrics: [LRCLIB](https://lrclib.net/).
