import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:keyboard_control/device_settings.dart';
import 'package:keyboard_control/device_settings_panel.dart';
import 'package:keyboard_control/models.dart';

class SettingsDevice implements KeyboardService {
  SettingsDevice({this.rs2 = true});
  final bool rs2;
  final values = [0, 0, 2, 0, 5, 1, 0, 0, 0, 1, 1, 0, 1, 1, 75, 0];
  final packets = <List<int>>[];
  bool oldFirmware = false;
  @override
  Future<List<List<int>>> companion(DeviceRef d, List<List<int>> batch) async =>
      [for (final p in batch) _reply(p)];
  List<int> _reply(List<int> p) {
    packets.add(List.of(p));
    if (oldFirmware) return [255, ...List.filled(31, 0)];
    var status = 0;
    if (p[2] == 18) return [...p, 0, ...List.filled(25, 0)];
    if (p[0] == 7) {
      if (values[p[3]] != p[5]) {
        status = 2;
      } else {
        values[p[3]] = p[4];
      }
    }
    final support = rs2 ? 0xf7ff : 0xffff;
    final writable = support & 0x1fff;
    return [
      p[0],
      81,
      17,
      1,
      status,
      support >> 8,
      support & 255,
      writable >> 8,
      writable & 255,
      0x37,
      ...values,
      ...List.filled(6, 0),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const device = DeviceRef('fixture', 'rs2', 'Fixture');
void main() {
  test(
    'setting writes read back; physical changes reject stale edits',
    () async {
      final service = SettingsDevice();
      final client = DeviceSettingsClient(service, device);
      final before = await client.read();
      expect(before.has(SettingField.fkeys), false);
      expect(before.canSet(SettingField.wired), false);
      final after = await client.set(before, SettingField.theme, 2);
      expect(after[SettingField.theme], 2);
      expect(service.packets.last[0], 8);
      service.values[SettingField.accent.index] = 9;
      await expectLater(
        client.set(after, SettingField.accent, 3),
        throwsA(
          isA<SettingsConflict>().having(
            (e) => e.current[SettingField.accent],
            'actual',
            9,
          ),
        ),
      );
      expect(service.values[SettingField.accent.index], 9);
      await expectLater(
        client.set(after, SettingField.wired, 0),
        throwsStateError,
      );
    },
  );
  test(
    'older firmware cannot be presented as successfully configured',
    () async {
      final service = SettingsDevice()..oldFirmware = true;
      await expectLater(
        DeviceSettingsClient(service, device).read(),
        throwsStateError,
      );
      expect(service.packets.every((p) => p[0] == 8), true);
    },
  );
  for (final width in [320.0, 390.0, 1250.0]) {
    testWidgets('settings stay compact and usable at $width px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = SettingsDevice(rs2: false);
      final board = Board.fromJson(
        jsonDecode(File('assets/ak650.json').readAsStringSync()) as Json,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: DeviceSettingsPanel(
                  board: board,
                  device: device,
                  service: service,
                  busy: false,
                  run: (action, label) => action(),
                  beforeDeparture: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('键盘设置'));
      await tester.pumpAndSettle();
      expect(find.text('屏幕外观'), findsOneWidget);
      final card = find.byKey(const ValueKey('online-card-屏幕外观'));
      expect(tester.getSize(card).height, 280);
      await tester.tap(find.byKey(const ValueKey('online-detail-屏幕外观')));
      await tester.pumpAndSettle();
      expect(find.text('无操作后熄屏'), findsOneWidget);
      expect(tester.getSize(card).height, 280);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('online-detail-按键与旋钮')),
      );
      await tester.tap(find.byKey(const ValueKey('online-detail-按键与旋钮')));
      await tester.pumpAndSettle();
      expect(find.text('数字行默认功能'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('online-detail-连接与设备')),
      );
      await tester.tap(find.byKey(const ValueKey('online-detail-连接与设备')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('恢复出厂设置'));
      await tester.tap(find.text('恢复出厂设置'));
      await tester.pumpAndSettle();
      expect(find.text('恢复键盘出厂设置？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(service.packets.any((p) => p[0] == 7), false);
      expect(tester.takeException(), isNull);
    });
  }
}
