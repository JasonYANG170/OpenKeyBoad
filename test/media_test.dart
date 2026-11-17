import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyboard_control/media_features.dart';

void main() {
  test('LRC resolves offsets, multiple timestamps, and the current line', () {
    final lines = parseLrc(
      '[offset:100]\n[00:01.20][00:02.200]你好\n[00:03.0]world',
    );
    expect(lines.length, 3);
    expect(lines[0].time.inMilliseconds, 1100);
    expect(lyricAt(lines, const Duration(milliseconds: 2000))?.text, '你好');
    expect(lyricAt(lines, const Duration(milliseconds: 3000))?.text, 'world');
    expect(lyricAt(lines, Duration.zero), isNull);
  });
  test('PCM analysis follows amplitude and rejects truncated files', () {
    final data = Uint8List(44 + 16000);
    data.setRange(0, 4, ascii.encode('RIFF'));
    data.setRange(8, 12, ascii.encode('WAVE'));
    data.setRange(12, 16, ascii.encode('fmt '));
    data.setRange(36, 40, ascii.encode('data'));
    final v = ByteData.sublistView(data);
    v.setUint32(4, data.length - 8, Endian.little);
    v.setUint32(16, 16, Endian.little);
    v.setUint16(20, 1, Endian.little);
    v.setUint16(22, 1, Endian.little);
    v.setUint32(24, 8000, Endian.little);
    v.setUint16(34, 16, Endian.little);
    v.setUint32(40, 16000, Endian.little);
    for (var i = 0; i < 4000; i++) {
      v.setInt16(44 + i * 2, i.isEven ? 12000 : -12000, Endian.little);
    }
    final wave = WaveTrack.parse(data);
    expect(wave.seconds, 1);
    expect(wave.intensity(const Duration(milliseconds: 100)), 255);
    expect(wave.intensity(const Duration(milliseconds: 900)), 0);
    expect(() => WaveTrack.parse(data.sublist(0, 200)), throwsFormatException);
  });
}
