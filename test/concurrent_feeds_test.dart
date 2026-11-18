import 'dart:async';
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
  final cities = <String>[];
  int active = 0, maxActive = 0, weatherCalls = 0, metricsCalls = 0;
  bool weatherFails = false;
  int minor = 3;
  Completer<Json>? pendingWeather;
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
        minor,
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
    cities.add(city);
    if (weatherFails) throw StateError('weather offline');
    if (pendingWeather != null) return pendingWeather!.future;
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

class _OnlineFeeds extends _Feeds implements OnlineHostService {
  _OnlineFeeds(super.leds) {
    minor = 5;
  }
  int networkCalls = 0, audioCalls = 0, audioStops = 0;
  @override
  Future<Json> network() async {
    networkCalls++;
    return {
      'supported': true,
      'ready': true,
      'download': 1048576,
      'upload': 12345,
    };
  }

  @override
  Future<Json> audio(bool enabled) async {
    if (!enabled) {
      audioStops++;
      return {};
    }
    audioCalls++;
    return {
      'supported': true,
      'ready': true,
      'level': 0.6,
      'bands': List.filled(8, 0.4),
    };
  }
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
  List<bool> locks, {
  bool autoStart = true,
  Size size = const Size(1250, 2000),
}) async {
  final board = Board.fromJson(
    jsonDecode(File('assets/$id.json').readAsStringSync()) as Json,
  );
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FeaturesPanel(
            autoStart: autoStart,
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
  for (final width in [320.0, 390.0]) {
    testWidgets('Connected cards and settings fit a $width px phone', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = _OnlineFeeds(98);
      await _mount(tester, 'rs2', service, [], size: Size(width, 900));
      for (final title in ['实时网速', '番茄钟', '系统音乐律动', '系统歌词', '主机监视器', '天气']) {
        expect(
          tester.getSize(find.byKey(ValueKey('online-card-$title'))),
          const Size(310, 280),
        );
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('online-detail-天气')),
      );
      await tester.tap(find.byKey(const ValueKey('online-detail-天气')));
      await tester.pump();
      expect(find.byType(TextFormField), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const ValueKey('online-detail-番茄钟')),
      );
      await tester.tap(find.byKey(const ValueKey('online-detail-番茄钟')));
      await tester.pump();
      expect(find.text('短休'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'New feeds share one switch, keep the selected page and stop audio completely',
    (tester) async {
      final service = _OnlineFeeds(98);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, 'rs2', service, [], autoStart: false);
      await tester.tap(find.byType(Switch));
      await _drain(tester);
      for (final op in [12, 14]) {
        expect(service.packets.any((p) => p[0] == 7 && p[2] == op), isTrue);
      }
      expect(service.packets.where((p) => p[0] == 7 && p[2] == 8), isEmpty);
      expect(service.packets.where((p) => p[0] == 7 && p[2] == 13), isEmpty);
      await tester.tap(find.text('开始 / 继续'));
      await _drain(tester);
      expect(
        service.packets.any((p) => p[0] == 7 && p[2] == 13 && p[14] == 1),
        isTrue,
      );
      for (final title in ['实时网速', '番茄钟', '系统音乐律动', '系统歌词', '主机监视器', '天气']) {
        expect(
          tester.getSize(find.byKey(ValueKey('online-card-$title'))),
          const Size(310, 280),
        );
      }
      expect(find.text('显示天气'), findsNothing);
      expect(find.text('显示歌词'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('system-audio-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('八段频谱').last);
      await _drain(tester);
      await tester.pump(const Duration(seconds: 1));
      await _drain(tester);
      expect(service.audioCalls, greaterThan(0));
      expect(service.packets.any((p) => p[0] == 7 && p[2] == 15), isTrue);
      expect(service.maxActive, 1);
      await tester.tap(find.byType(Switch));
      await _drain(tester);
      final count = service.packets.length,
          calls = service.audioCalls,
          networks = service.networkCalls;
      await tester.pump(const Duration(seconds: 20));
      await _drain(tester);
      expect(service.packets.length, count);
      expect(service.audioCalls, calls);
      expect(service.networkCalls, networks);
      expect(service.audioStops, greaterThan(0));
      expect(find.text('选择 WAV'), findsNothing);
      expect(find.text('选择 LRC'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'One online switch starts and stops all feeds without local media controls',
    (tester) async {
      final service = _Feeds(98);
      final locks = <bool>[];
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, 'rs2', service, locks, autoStart: false);
      expect(service.packets, isEmpty);
      expect(find.text('选择 WAV'), findsNothing);
      expect(find.text('选择 LRC'), findsNothing);
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await _drain(tester);
      await tester.pump(const Duration(seconds: 1));
      await _drain(tester);
      for (final op in [3, 4, 6]) {
        expect(service.packets.any((p) => p[0] == 7 && p[2] == op), isTrue);
      }
      await tester.tap(find.byType(Switch));
      await _drain(tester);
      final count = service.packets.length,
          weather = service.weatherCalls,
          metrics = service.metricsCalls;
      await tester.pump(const Duration(minutes: 16));
      await _drain(tester);
      expect(service.packets.length, count);
      expect(service.weatherCalls, weather);
      expect(service.metricsCalls, metrics);
      expect(locks, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Switch off discards an in-flight weather result and cannot restart its timer',
    (tester) async {
      final pending = Completer<Json>();
      final service = _Feeds(98)..pendingWeather = pending;
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, 'rs2', service, [], autoStart: false);
      await tester.tap(find.byType(Switch));
      await _drain(tester);
      expect(service.weatherCalls, 1);
      await tester.tap(find.byType(Switch));
      await _drain(tester);
      pending.complete({
        'name': 'Late weather',
        'temperature': 24.3,
        'humidity': 96,
        'code': 3,
      });
      await _drain(tester);
      expect(service.packets.where((p) => p[0] == 7 && p[2] == 4), isEmpty);
      await tester.pump(const Duration(minutes: 16));
      await _drain(tester);
      expect(service.weatherCalls, 1);
      service.pendingWeather = null;
      await tester.tap(find.byType(Switch));
      await _drain(tester);
      expect(service.packets.any((p) => p[0] == 7 && p[2] == 4), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Submitting a new city during a request discards the previous city result',
    (tester) async {
      final pending = Completer<Json>();
      final service = _Feeds(98)..pendingWeather = pending;
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, 'rs2', service, [], autoStart: false);
      await tester.tap(find.byType(Switch));
      await _drain(tester);
      await tester.tap(find.byKey(const ValueKey('online-detail-天气')));
      await tester.pump();
      await tester.enterText(find.byType(TextFormField), 'Shenzhen');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      service.pendingWeather = null;
      pending.complete({
        'name': 'Old city',
        'temperature': -1.0,
        'humidity': 50,
        'code': 51,
      });
      await _drain(tester);
      expect(service.cities, ['Singapore', 'Shenzhen']);
      final writes = service.packets
          .where((p) => p[0] == 7 && p[2] == 4)
          .toList();
      expect(writes.length, 1);
      expect(writes.single[3], 0);
      expect(writes.single[4], 243);
      await tester.pumpWidget(const SizedBox());
    },
  );
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
        final manualLocks = List.of(locks);
        service.song = 'B';
        await tester.pump(const Duration(seconds: 6));
        await _drain(tester);
        expect(service.metricsCalls, greaterThan(1));
        expect(service.packets.where((p) => p[0] == 7 && p[2] == 8), isEmpty);
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
