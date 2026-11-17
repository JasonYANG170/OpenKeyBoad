# OpenKeyBoad

[English](README.en.md)

| 项目 | 支持 |
| --- | --- |
| 键盘 | [JamesDonkey RS2 3.0](https://github.com/JasonYANG170/JamesDonkey-RS2-QMK)、[AJAZZ AK650](https://github.com/JasonYANG170/AJAZZ-AK650-QMK) |
| 客户端 | Windows、macOS、Linux、Android、iOS、Web |
| 技术 | Flutter 3.50 / Dart 3.14、VIA 12、HID |
| 配置 | 四层改键、旋钮、组合键、逐键 RGB、动态灯效 |
| 彩屏 | 系统歌词、扩展天气、资源监控、实时网速、番茄钟、校时 |

## 构建

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d windows # 也可选择 macos、linux 或 Android / iOS 设备
```

桌面 USB 需要 HIDAPI：Windows 将 `hidapi.dll` 放到程序旁；macOS 安装 `brew install hidapi`；Linux 安装 `libhidapi-hidraw0` 并使用 `linux/70-keyboard-control.rules`。

GitHub Actions 检查代码并构建全部六种客户端，全部成功后自动发布。Android APK 使用测试签名，iOS IPA 未签名，安装前需自行签名；macOS 构建未公证。Web 通过桌面中继访问键盘。中继在 `bridge/` 下用 `dart run bin/main.dart --lan` 启动，需先执行 `flutter build web --release --no-web-resources-cdn` 和 `dart pub get`。

## 固件

配套镜像和 VIA 布局位于 `firmware/`，对应源码及锁定依赖的构建脚本位于 `firmware/source/{rs2,ak650}/`。


GPL-2.0-or-later。字体许可见 `fonts/OFL.txt`。天气由 [Open-Meteo](https://open-meteo.com/) 提供（免费接口限非商业用途），歌词由 [LRCLIB](https://lrclib.net/) 提供。
