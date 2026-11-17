import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:keyboard_control/features_panel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:keyboard_control/lyrics_lookup.dart';
import 'package:keyboard_control/models.dart';
import 'package:keyboard_control/palette.dart';

class _MediaService implements KeyboardService {
  String song = 'A';
  final lookups = <String, Completer<Json>>{};
  @override
  Future<Json> nowPlaying() async => {
    'title': song,
    'artist': 'Fixture',
    'duration': 60000,
    'position': 0,
    'playing': false,
  };
  @override
  Future<Json> lyrics(Json track) {
    final pending = Completer<Json>();
    lookups[track['title'] as String] = pending;
    return pending.future;
  }

  @override
  Future<List<List<int>>> companion(
    DeviceRef d,
    List<List<int>> packets,
  ) async => [
    for (final p in packets)
      p[0] == 8 && p[2] == 0
          ? [8, 0x51, 0, 1, 127, 240, 20, 98, 0, 2, ...List.filled(22, 0)]
          : [...p, ...List.filled(32 - p.length, 0)],
  ];
  @override
  Future<List<DeviceRef>> scan() async => [];
  @override
  Future<Profile> read(DeviceRef d) async => throw UnimplementedError();
  @override
  Future<Profile> apply(DeviceRef d, Profile before, Profile after) async =>
      after;
  @override
  Future<List<int>> metrics() async => [255, 255, 255, 255];
  @override
  Future<Json> weather(String city) async => throw UnimplementedError();
}

void main() {
  testWidgets(
    'Slow lyrics do not block song changes; stale results are discarded',
    (tester) async {
      final board = Board.fromJson(
        jsonDecode(File('assets/rs2.json').readAsStringSync()) as Json,
      );
      final service = _MediaService();
      await tester.binding.setSurfaceSize(const Size(1200, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FeaturesPanel(
                board: board,
                palette: PaletteModel(board),
                device: const DeviceRef('fixture', 'rs2', 'Test'),
                service: service,
                locked: false,
                isLocked: () => false,
                onLock: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('跟随系统音乐'));
      await tester.pump();
      expect(service.lookups.keys, ['A']);
      service.song = 'B';
      await tester.pump(const Duration(seconds: 2));
      expect(service.lookups.keys, ['A', 'B']);
      service.lookups['B']!.complete({
        'lrc': '[00:00]Owned fixture B',
        'status': 'B matched',
      });
      await tester.pump();
      expect(find.text('B matched'), findsOneWidget);
      service.lookups['A']!.complete({
        'lrc': '[00:00]Owned fixture A',
        'status': 'A matched',
      });
      await tester.pump();
      expect(find.text('A matched'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'Timed lyrics are cached; another duration is matched separately',
    () async {
      var requests = 0;
      final lookup = LyricsLookup(
        clientFactory: () => MockClient((request) async {
          requests++;
          expect(request.headers['Lrclib-Client'], contains('OpenKeyBoad'));
          return http.Response(
            jsonEncode({'syncedLyrics': '[00:01.00]Own test lyric'}),
            200,
          );
        }),
      );
      final track = {
        'title': 'Test',
        'artist': 'Fixture',
        'album': 'Tests',
        'duration': 180000,
      };
      expect((await lookup.find(track))['lrc'], contains('Own test lyric'));
      await lookup.find(track);
      expect(requests, 1);
      await lookup.find({...track, 'duration': 200000});
      expect(requests, 2);
    },
  );
  test('Search rejects another recording and caches missing lyrics', () async {
    var requests = 0;
    final lookup = LyricsLookup(
      clientFactory: () => MockClient((request) async {
        requests++;
        if (request.url.path.endsWith('/get')) return http.Response('{}', 404);
        return http.Response(
          jsonEncode([
            {
              'trackName': 'Test',
              'artistName': 'Fixture',
              'duration': 250,
              'syncedLyrics': '[00:01]wrong duration',
            },
            {
              'trackName': 'Test live',
              'artistName': 'Fixture',
              'duration': 180,
              'syncedLyrics': '[00:01]wrong recording',
            },
          ]),
          200,
        );
      }),
    );
    final track = {'title': 'Test', 'artist': 'Fixture', 'duration': 180000};
    expect((await lookup.find(track))['lrc'], isNull);
    await lookup.find(track);
    expect(requests, 2);
  });
  test('Rate limiting backs off without another request', () async {
    var requests = 0;
    final lookup = LyricsLookup(
      clientFactory: () => MockClient((_) async {
        requests++;
        return http.Response('{}', 429, headers: {'retry-after': '30'});
      }),
    );
    final track = {'title': 'Test', 'artist': 'Fixture', 'duration': 180000};
    await expectLater(lookup.find(track), throwsStateError);
    await expectLater(lookup.find(track), throwsStateError);
    expect(requests, 1);
  });
  test('RS2 and AK650 knob clicks do not consume RGB channels', () {
    for (final id in ['rs2', 'ak650']) {
      final board = Board.fromJson(
        jsonDecode(File('assets/$id.json').readAsStringSync()) as Json,
      );
      final palette = PaletteModel(board);
      final knob = board.keys.indexWhere((k) => k.encoder);
      expect(palette.colors.length, id == 'rs2' ? 98 : 66);
      palette.select(knob);
      expect(palette.selected, 0);
      palette.select(knob + 1);
      palette.paint(0xff0000);
      expect(palette.colors.where((color) => color == 0xff0000).length, 1);
      expect(palette.ledAt(board.keys.length - 1), palette.colors.length - 1);
    }
  });
}
