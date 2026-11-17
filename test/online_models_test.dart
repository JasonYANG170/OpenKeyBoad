import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyboard_control/audio_analysis.dart';
import 'package:keyboard_control/online_models.dart';
import 'package:keyboard_control/media_features.dart';

void main() {
  test(
    'network handles adapter arrival, reset, 32-bit wrap and stale samples',
    () {
      final rates = NetworkRates();
      expect(rates.update({'a': (100, 50)}, Duration.zero)['ready'], false);
      final next = rates.update({
        'a': (2148, 1074),
        'new': (999999, 999999),
      }, const Duration(seconds: 2));
      expect(next['download'], 1024);
      expect(next['upload'], 512);
      expect(
        rates.update({'a': (1, 1)}, const Duration(seconds: 3))['download'],
        0,
      );
      rates.update({'a': (0xfffffff0, 100)}, const Duration(seconds: 4));
      expect(
        rates.update(
          {'a': (16, 110)},
          const Duration(seconds: 5),
          wrap32: true,
        )['download'],
        32,
      );
      expect(
        rates.update({'a': (1000, 300)}, const Duration(seconds: 80))['ready'],
        false,
      );
      expect(byteRate(1048576), '1.0 MB/s');
      expect(
        networkPacket({
          'download': 0x100000000,
          'upload': -1,
          'supported': true,
          'ready': true,
        }).sublist(3),
        [255, 255, 255, 255, 0, 0, 0, 0, 1],
      );
    },
  );
  test('pomodoro uses elapsed time, pauses exactly, completes once and cycles breaks', () {
    var clock = Duration.zero;
    final timer = Pomodoro(now: () => clock)..configure(1, 1, 5);
    timer.start();
    clock += const Duration(seconds: 35);
    expect(timer.clock, '00:25');
    timer.pause();
    clock += const Duration(minutes: 1);
    expect(timer.clock, '00:25');
    timer.start();
    clock += const Duration(seconds: 25);
    expect(timer.tick(), true);
    expect(timer.tick(), false);
    expect(timer.completed, 1);
    timer.start();
    expect(timer.rest, true);
    expect(timer.total.inMinutes, 1);
    clock += const Duration(minutes: 1);
    timer.tick();
    timer.start();
    expect(timer.rest, false);
    for (var i = 0; i < 3; i++) {
      clock += const Duration(minutes: 1);
      timer.tick();
      timer.start();
      if (i < 2) {
        clock += const Duration(minutes: 1);
        timer.tick();
        timer.start();
      }
    }
    expect(timer.completed, 4);
    expect(timer.rest, true);
    expect(timer.total.inMinutes, 5);
  });
  test(
    'system audio analysis rejects silence and separates a real test tone',
    () {
      final audio = AudioAnalysis();
      expect(audio.frame(48000)['level'], 0);
      for (var i = 0; i < 2048; i++) {
        audio.add(0.4 * sin(2 * pi * 2560 * i / 48000));
      }
      final result = audio.frame(48000);
      final bands = (result['bands'] as List).cast<double>();
      expect(result['level'] as double, greaterThan(0.5));
      expect(bands[5], greaterThan(bands[0]));
      final envelope = AudioEnvelope()..update(result);
      final peak = envelope.level;
      envelope.update({'level': 0, 'bands': List.filled(8, 0)});
      expect(envelope.level, lessThan(peak));
      expect(envelope.level, greaterThan(0));
      for (var i = 0; i < 80; i++) {
        envelope.update({});
      }
      expect(envelope.level, lessThan(0.001));
    },
  );
  test('weather detail payload keeps missing AQ data distinct from zero', () {
    final weather = CityWeather(
      'Example',
      -12.3,
      77,
      3,
      minimum: -15,
      maximum: -1,
      rain: 60,
      uv: 4.2,
    );
    expect(weather.detailsPacket, [
      7,
      81,
      14,
      255,
      106,
      255,
      246,
      60,
      42,
      255,
      255,
      255,
      255,
    ]);
    expect(CityWeather.fromJson(weather.toJson()).rain, 60);
    expect(CityWeather('Empty', 20, 50, 0).detailsPacket.sublist(3), [
      127,
      255,
      127,
      255,
      255,
      255,
      255,
      255,
      255,
      255,
    ]);
  });
}
