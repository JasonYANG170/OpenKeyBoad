# OpenKeyBoad

[English](README.en.md)

| 项目 | 支持 |
| --- | --- |
| 键盘 | [JamesDonkey RS2 3.0](https://github.com/JasonYANG170/JamesDonkey-RS2-QMK)、[AJAZZ AK650](https://github.com/JasonYANG170/AJAZZ-AK650-QMK) |
| 客户端 | Windows、macOS、Linux、Android、iOS、Web |
| 技术 | Flutter 3.50 / Dart 3.14、VIA 12、HID |
| 配置 | 四层改键、旋钮、组合键、逐键 RGB、动态灯效 |
| 彩屏 | 系统歌词、扩展天气、资源监控、实时网速、番茄钟、校时 |

## 使用

从 [Releases](https://github.com/JasonYANG170/OpenKeyBoad/releases) 下载对应客户端。键盘切到有线模式，扫描设备后编辑并应用。逐键配色在「灯光 → 逐键配色」中直接点选实际布局，支持 HEX 颜色、全部填充和配色文件导入导出。

Windows 便携版运行 `KeyboardControl.exe`。运行 `Connect-Phone.cmd` 或桌面中继的 `--lan` 参数，将显示的完整链接在同一局域网的手机浏览器中打开。iOS 客户端通过该链接连接桌面。链接含临时授权令牌，仅分享给可信设备。Android 也支持 USB OTG。

「在线功能开关」开启后自动读取系统播放器曲名、歌手及进度，通过 LRCLIB 匹配同步歌词，在键盘屏幕显示播放状态、进度和滚动歌词。Windows 使用系统媒体会话，macOS 支持 Music / Spotify，Linux 需要 `playerctl`。播放器须提供媒体信息，未匹配到同步歌词时会显示状态提示。

在线功能默认关闭。开启总开关后，歌词、天气、资源与网速同时在后台更新；关闭后全部停止，并暂停番茄钟。番茄钟支持专注、短休、每四轮长休息和自定义时长，完成后手动开始下一轮。旋钮或「显示」按钮只切换键盘画面，后台同步不会触发全局加载条。

天气输入城市后按回车更新，包含图标、当前温湿度、今日高低温、降雨概率、最大 UV、AQI（美国标准）及 PM2.5，每 15 分钟刷新；空气质量不可用时显示 `--`。网速按每秒物理网卡收发字节差值计算。监控和歌词需保持桌面连接；GPU 不可用时显示 `--`。手机通过桌面连接时显示电脑数据。静态逐键配色暂存 RAM，重启后重新应用；组合键保存到 VIA 宏。

系统音乐律动在在线开关开启后按所选方式运行，支持逐键配色随音量、八段频谱和彩虹律动，带静音衰减。Windows 采集系统输出声音，Linux 通过 `parec`（`pulseaudio-utils`）采集默认输出的 monitor；不保存录音。macOS 和移动端暂不直接采集系统声音，可连接 Windows / Linux 桌面中继。

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

配套镜像和 VIA 布局位于 `firmware/`，对应源码及锁定依赖的构建脚本位于 `firmware/source/{rs2,ak650}/`。RS2 按 `Fn+Esc` 进入 ISP，AK650 从彩屏设置进入「刷机」。确认只有目标键盘处于 ISP 后使用对应型号命令。

```sh
python -m pip install hidapi
python firmware/flash.py firmware/RS2-VIA-0.3.2.bin --checksums firmware/SHA256SUMS
# AK650 使用 firmware/AK650-VIA-0.3.7.bin
```

GPL-2.0-or-later。字体许可见 `fonts/OFL.txt`。天气由 [Open-Meteo](https://open-meteo.com/) 提供（免费接口限非商业用途），歌词由 [LRCLIB](https://lrclib.net/) 提供。
