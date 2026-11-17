import 'dart:math';

import 'models.dart';

String byteRate(num? value) {
  if (value == null) return '--';
  final n = max(0, value);
  if (n >= 1048576) return '${(n / 1048576).toStringAsFixed(1)} MB/s';
  if (n >= 1024) return '${(n / 1024).toStringAsFixed(1)} KB/s';
  return '${n.round()} B/s';
}

List<int> uint32Bytes(int value) => [
  (value >> 24) & 255,
  (value >> 16) & 255,
  (value >> 8) & 255,
  value & 255,
];

List<int> networkPacket(Json value) => [
  7,
  0x51,
  12,
  ...uint32Bytes((value['download'] as num? ?? 0).round().clamp(0, 0xffffffff)),
  ...uint32Bytes((value['upload'] as num? ?? 0).round().clamp(0, 0xffffffff)),
  value['supported'] == true && value['ready'] == true ? 1 : 0,
];

/// Rates are derived from monotonic time and per-interface counters. Newly
/// connected adapters never contribute their entire lifetime byte count.
class NetworkRates {
  Map<String, (int, int)> _previous = {};
  Duration? _at;
  Json update(
    Map<String, (int, int)> current,
    Duration at, {
    bool wrap32 = false,
  }) {
    final elapsed = _at == null ? 0 : (at - _at!).inMicroseconds / 1e6;
    var rx = 0, tx = 0;
    int delta(int next, int old) {
      if (next >= old) return next - old;
      // Only a counter near the 32-bit ceiling can be considered a wrap.
      return wrap32 && old > 0xf0000000 && next < 0x10000000
          ? next + 0x100000000 - old
          : 0;
    }

    if (elapsed > 0 && elapsed <= 30) {
      for (final entry in current.entries) {
        final before = _previous[entry.key];
        if (before == null) continue;
        rx += delta(entry.value.$1, before.$1);
        tx += delta(entry.value.$2, before.$2);
      }
    }
    final ready = _at != null && elapsed > 0 && elapsed <= 30;
    _previous = Map.of(current);
    _at = at;
    return {
      'supported': true,
      'ready': ready,
      'download': ready ? (rx / elapsed).round() : 0,
      'upload': ready ? (tx / elapsed).round() : 0,
      'interfaces': current.length,
    };
  }
}

class Pomodoro {
  Pomodoro({Duration Function()? now}) {
    final watch = Stopwatch()..start();
    _now = now ?? (() => watch.elapsed);
  }
  late final Duration Function() _now;
  int focusMinutes = 25, breakMinutes = 5, longBreakMinutes = 15;
  int completed = 0;
  bool rest = false, running = false, done = false;
  Duration _remaining = const Duration(minutes: 25), _started = Duration.zero;
  Duration get total => Duration(
    minutes: rest
        ? (completed > 0 && completed % 4 == 0
              ? longBreakMinutes
              : breakMinutes)
        : focusMinutes,
  );
  Duration get remaining {
    final value = running ? _remaining - (_now() - _started) : _remaining;
    return value.isNegative ? Duration.zero : value;
  }

  String get label => done
      ? '本轮完成'
      : rest
      ? '休息'
      : '专注';
  String get clock {
    final seconds = (remaining.inMilliseconds / 1000).ceil();
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void start() {
    if (running) return;
    if (done) {
      rest = !rest;
      done = false;
      _remaining = total;
    }
    _started = _now();
    running = true;
  }

  void pause() {
    _remaining = remaining;
    running = false;
  }

  bool tick() {
    if (!running || remaining > Duration.zero) return false;
    running = false;
    done = true;
    _remaining = Duration.zero;
    if (!rest) completed++;
    return true;
  }

  void reset() {
    running = false;
    done = false;
    _remaining = total;
  }

  void configure(int focus, int shortBreak, int longBreak) {
    focusMinutes = focus.clamp(1, 120);
    breakMinutes = shortBreak.clamp(1, 60);
    longBreakMinutes = longBreak.clamp(1, 120);
    reset();
  }

  List<int> get packet => [
    7,
    0x51,
    13,
    done
        ? 4
        : running
        ? (rest ? 3 : 1)
        : remaining == total
        ? 0
        : 2,
    ...uint32Bytes((remaining.inMilliseconds / 1000).ceil()),
    ...uint32Bytes(total.inSeconds),
    completed % 256,
    rest ? 1 : 0,
  ];
}

/// Fast attack / slower release, with a quiet gate. Only actual captured audio
/// enters this envelope; no synthetic beat is substituted when capture fails.
class AudioEnvelope {
  double level = 0;
  List<double> bands = List.filled(8, 0);
  void update(Json frame) {
    double smooth(double old, num value) {
      final target = value.isFinite ? value.toDouble().clamp(0, 1) : 0.0;
      final gated = target < 0.015 ? 0.0 : target;
      return old + (gated - old) * (gated > old ? 0.65 : 0.22);
    }

    level = smooth(level, frame['level'] as num? ?? 0);
    final input = frame['bands'] as List? ?? [];
    bands = List.generate(
      8,
      (i) => smooth(
        bands[i],
        i < input.length && input[i] is num ? input[i] as num : 0,
      ),
    );
  }
}
