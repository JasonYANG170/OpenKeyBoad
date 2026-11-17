import 'dart:math';

import 'models.dart';

class AudioAnalysis {
  final _samples = List<double>.filled(1024, 0);
  int _cursor = 0;
  void add(double sample) {
    _samples[_cursor] = sample.isFinite ? sample.clamp(-1, 1) : 0;
    _cursor = (_cursor + 1) % _samples.length;
  }

  Json frame(int rate) {
    final samples = List.generate(1024, (i) => _samples[(_cursor + i) % 1024]);
    final rms = sqrt(samples.fold<double>(0, (sum, n) => sum + n * n) / 1024);
    if (rms < 0.0005) {
      return {
        'supported': true,
        'ready': true,
        'level': 0.0,
        'bands': List.filled(8, 0.0),
      };
    }
    double compress(double n) =>
        n < 0.0005 ? 0 : ((20 * log(n) / ln10 + 60) / 60).clamp(0, 1);
    final bands = <double>[];
    for (final frequency in [80, 160, 320, 640, 1280, 2560, 5120, 10000]) {
      if (frequency >= rate / 2) {
        bands.add(0);
        continue;
      }
      final coefficient = 2 * cos(2 * pi * frequency / rate);
      double previous = 0, older = 0;
      for (var i = 0; i < samples.length; i++) {
        final window = 0.5 - 0.5 * cos(2 * pi * i / 1023);
        final next = samples[i] * window + coefficient * previous - older;
        older = previous;
        previous = next;
      }
      final power = max(
        0.0,
        previous * previous + older * older - coefficient * previous * older,
      );
      bands.add(compress(sqrt(power) / 256));
    }
    return {
      'supported': true,
      'ready': true,
      'level': compress(rms),
      'bands': bands,
    };
  }
}
