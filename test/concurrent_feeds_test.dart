import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:keyboard_control/features_panel.dart';
import 'package:keyboard_control/models.dart';
import 'package:keyboard_control/palette.dart';

class _Feeds implements KeyboardService {
  _Feeds(this.leds);
  final int leds;
  final packets = <List<int>>[];
  int active = 0, maxActive = 0, weatherCalls = 0, metricsCalls = 0;
  bool weatherFails = false;
  String song = 'A';
  List<int>? weatherPacket;
  @override
  Future<List<List<int>>> companion(DeviceRef d, List<List<int>> batch) async {
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return [for (final p in batch) _reply(p)];
    } finally {
      active--;
    }
  }

  List<int> _reply(List<int> p) {
    packets.add(List.of(p));
    if (p[0] == 8 && p[2] == 0) {
      return [
        8,
        81,
        0,
        1,
        127,
        leds == 98 ? 240 : 128,
        20,
        leds,
        0,
        3,
        ...List.filled(22, 0),
      ];
    }
    if (p[0] == 7 && p[2] == 4) weatherPacket = p;
    if (p[0] == 8 && p[2] == 10) {
      final w = weatherPacket!;
      return [
        8,
        81,
        10,
        ...w.sublist(3, 7),
        1,
        ...w.sublist(7, 9),
        ...List.filled(22, 0),
      ];
    }
    final reply = [...p, ...List.filled(32 - p.length, 0)];
    if (p[2] == 7) reply[10] = 1;
    return reply;
  }

  @override
  Future<Json> nowPlaying() async => {
    'title': song,
    'artist': 'Fixture',
    'duration': 60000,
    'position': 1200,
    'playing': false,
  };
  @override
  Future<Json> lyrics(Json t) async => {
    'lrc': '[00:00]Own lyric $song',
    'status': 'Matched $song',
  };
  @override
  Future<List<int>> metrics() async {
    metricsCalls++;
    return [17, 36, 42, 68];
  }

  @override
  Future<Json> weather(String city) async {
    weatherCalls++;
    if (weatherFails) throw StateError('weather offline');
    return {'name': 'Fixture', 'temperature': 24.3, 'humidity': 96, 'code': 3};
  }

  @override
  Future<List<DeviceRef>> scan() async => [];
  @override
  Future<Profile> read(DeviceRef d) async => throw UnimplementedError();
  @override
  Future<Profile> apply(DeviceRef d, Profile before, Profile after) async =>
      after;
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  for (var image = 0; image < 4; image++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }
}

Future<void> _mount(
  WidgetTester tester,
  String id,
  _Feeds service,
  List<bool> locks,
) async {
  final board = Board.fromJson(
    jsonDecode(File('assets/$id.json').readAsStringSync()) as Json,
  );
  await tester.binding.setSurfaceSize(const Size(1250, 2000));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FeaturesPanel(
            board: board,
            palette: PaletteModel(board),
            device: DeviceRef('fixture', id, 'Fixture'),
            service: service,
            locked: false,
            isLocked: () => false,
            onLock: locks.add,
          ),
        ),
      ),
    ),
  );
  await _drain(tester);
}

void main() {
  for (final id in ['rs2', 'ak650']) {
    testWidgets(
      '$id: auto connection keeps three feeds active without global loading or page stealing',
      (tester) async {
        final service = _Feeds(id == 'rs2' ? 98 : 66);
        final locks = <bool>[];
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _mount(tester, id, service, locks);
        expect(service.packets.any((p) => p[0] == 7 && p[2] == 3), isTrue);
        expect(service.packets.any((p) => p[0] == 7 && p[2] == 4), isTrue);
        await tester.pump(const Duration(seconds: 1));
        await _drain(tester);
        expect(service.packets.any((p) => p[0] == 7 && p[2] == 6), isTrue);
        expect(locks, isEmpty);
        expect(service.maxActive, 1);
        expect(service.packets.where((p) => p[0] == 7 && p[2] == 8), isEmpty);
        await tester.tap(find.text('显示天气'));
        await _drain(tester);
        expect(service.packets.where((p) => p[0] == 7 && p[2] == 8).single, [
          7,
          81,
          8,
          2,
        ]);
        final manualLocks = List.of(locks);
        service.song = 'B';
        await tester.pump(const Duration(seconds: 6));
        await _drain(tester);
        expect(service.metricsCalls, greaterThan(1));
        expect(service.packets.where((p) => p[0] == 7 && p[2] == 8).length, 1);
        expect(locks, manualLocks);
        expect(service.maxActive, 1);
        final frames = service.packets
            .where((p) => p[0] == 7 && p[2] == 5)
            .length;
        await tester.pump(const Duration(seconds: 1));
        await _drain(tester);
        expect(
          service.packets.where((p) => p[0] == 7 && p[2] == 5).length,
          frames,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('Weather failure leaves monitor and lyrics running', (
    tester,
  ) async {
    final service = _Feeds(98)..weatherFails = true;
    final locks = <bool>[];
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _mount(tester, 'rs2', service, locks);
    await tester.pump(const Duration(seconds: 7));
    await _drain(tester);
    expect(service.metricsCalls, greaterThan(1));
    expect(service.packets.any((p) => p[0] == 7 && p[2] == 6), isTrue);
    expect(find.textContaining('weather offline'), findsOneWidget);
    expect(locks, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
