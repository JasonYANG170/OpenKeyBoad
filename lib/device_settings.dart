import 'models.dart';

enum SettingField {
  theme,
  accent,
  timeout,
  english,
  backlight,
  rgbEnabled,
  mac,
  guiLock,
  encoder,
  media,
  profile,
  fkeys,
  screen,
  wired,
  battery,
  connection,
}

enum DeviceAction { dim, brighten, wake, pair, isp, reset }

class DeviceSettings {
  DeviceSettings._(this.supported, this.writable, this.actions, this.values);
  factory DeviceSettings.decode(List<int> packet) {
    if (packet.length != 32 ||
        packet[1] != 0x51 ||
        packet[2] != 17 ||
        packet[3] != 1 ||
        (packet[0] != 7 && packet[0] != 8)) {
      throw StateError('需要更新随本版控制台提供的键盘固件，才能设置全部选项。');
    }
    return DeviceSettings._(
      (packet[5] << 8) | packet[6],
      (packet[7] << 8) | packet[8],
      packet[9],
      List.unmodifiable(packet.sublist(10, 26)),
    );
  }
  final int supported, writable, actions;
  final List<int> values;
  int operator [](SettingField field) => values[field.index];
  bool has(SettingField field) => supported & (1 << field.index) != 0;
  bool canSet(SettingField field) => writable & (1 << field.index) != 0;
  bool canRun(DeviceAction action) => actions & (1 << action.index) != 0;
}

class SettingsConflict implements Exception {
  SettingsConflict(this.current, this.message);
  final DeviceSettings current;
  final String message;
  @override
  String toString() => message;
}

class DeviceSettingsClient {
  DeviceSettingsClient(this.service, this.device);
  final KeyboardService service;
  final DeviceRef device;
  Future<List<int>> _request(List<int> packet) async {
    final replies = await service.companion(device, [packet]);
    if (replies.length != 1 ||
        replies.single.length != 32 ||
        replies.single[0] != packet[0] ||
        replies.single[1] != 0x51 ||
        replies.single[2] != packet[2]) {
      throw StateError('当前固件不支持此设置，请更新对应型号固件。');
    }
    return replies.single;
  }

  Future<DeviceSettings> read() async =>
      DeviceSettings.decode(await _request([8, 0x51, 17]));
  Future<DeviceSettings> set(
    DeviceSettings before,
    SettingField field,
    int value,
  ) async {
    if (!before.canSet(field) || value < 0 || value > 255) {
      throw StateError('当前设备不支持修改此选项。');
    }
    final reply = await _request([
      7,
      0x51,
      17,
      field.index,
      value,
      before[field],
    ]);
    final current = DeviceSettings.decode(reply);
    if (reply[4] != 0) {
      throw SettingsConflict(
        current,
        reply[4] == 2 ? '该选项已在键盘或另一控制台修改，已读取最新值，请重试。' : '键盘未应用此设置，已读取当前值。',
      );
    }
    final verified = await read();
    if (verified[field] != value) {
      throw SettingsConflict(verified, '读回值发生变化，请检查键盘上的操作。');
    }
    return verified;
  }

  Future<void> run(DeviceSettings current, DeviceAction action) async {
    if (!current.canRun(action)) throw StateError('请先切换到此操作支持的硬件档位。');
    final reply = await _request([7, 0x51, 18, action.index, 0xa5, 0x5a]);
    if (reply[3] != action.index ||
        reply[4] != 0xa5 ||
        reply[5] != 0x5a ||
        reply[6] != 0) {
      throw StateError('键盘未执行此操作，请刷新状态后重试。');
    }
  }
}
