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
}
