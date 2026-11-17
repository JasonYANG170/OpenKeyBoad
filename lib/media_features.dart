import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'weather_client.dart';

class WaveTrack {
  WaveTrack(this.bytes, this.seconds, this.energy);
  final Uint8List bytes;
  final double seconds;
  final List<double> energy;

  factory WaveTrack.parse(Uint8List data) {
    if (data.length < 44 ||
        ascii.decode(data.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(data.sublist(8, 12), allowInvalid: true) != 'WAVE') {
      throw const FormatException('音乐律动支持未压缩的 PCM WAV 文件。');
    }
    final view = ByteData.sublistView(data);
    var channels = 0, rate = 0, bits = 0, format = 0, start = 0, length = 0;
    for (var at = 12; at + 8 <= data.length;) {
      final size = view.getUint32(at + 4, Endian.little), begin = at + 8;
      if (begin + size > data.length) throw const FormatException('WAV 文件不完整。');
      final name = ascii.decode(data.sublist(at, at + 4), allowInvalid: true);
      if (name == 'fmt ' && size >= 16) {
        format = view.getUint16(begin, Endian.little);
        channels = view.getUint16(begin + 2, Endian.little);
        rate = view.getUint32(begin + 4, Endian.little);
        bits = view.getUint16(begin + 14, Endian.little);
      } else if (name == 'data') {
        start = begin;
        length = size;
      }
      at = begin + size + (size % 2);
    }
    if (format != 1 ||
        channels < 1 ||
        channels > 8 ||
        rate < 8000 ||
        rate > 192000 ||
        ![8, 16, 24, 32].contains(bits) ||
        length == 0) {
      throw const FormatException('请使用 8/16/24/32 位 PCM WAV 音频。');
    }
    final bytesPerSample = bits ~/ 8, frame = bytesPerSample * channels;
    final frames = length ~/ frame;
    final window = max(1, rate ~/ 20), levels = <double>[];
    for (var index = 0; index < frames; index += window) {
      var squares = 0.0, count = 0;
      // Every fourth frame is sufficient for amplitude response and limits parsing cost.
      for (var i = index; i < min(index + window, frames); i += 4) {
        for (var c = 0; c < channels; c++) {
          final at = start + i * frame + c * bytesPerSample;
          final value = switch (bits) {
            8 => (view.getUint8(at) - 128) / 128,
            16 => view.getInt16(at, Endian.little) / 32768,
            24 =>
              (((view.getUint8(at) |
                                  (view.getUint8(at + 1) << 8) |
                                  (view.getUint8(at + 2) << 16)) <<
                              8)
                          .toSigned(32) >>
                      8) /
                  8388608,
            _ => view.getInt32(at, Endian.little) / 2147483648,
          };
          squares += value * value;
          count++;
        }
      }
      levels.add(sqrt(squares / max(count, 1)));
    }
    final peak = levels.fold<double>(0, max);
    if (peak > 0) {
      for (var i = 0; i < levels.length; i++) {
        levels[i] = sqrt(levels[i] / peak);
      }
    }
    return WaveTrack(data, frames / rate, levels);
  }

  int intensity(Duration position) {
    final index = (position.inMilliseconds / 50).floor();
    return index >= 0 && index < energy.length
        ? (energy[index] * 255).round()
        : 0;
  }
}

class LyricLine {
  const LyricLine(this.time, this.text);
  final Duration time;
  final String text;
}

List<LyricLine> parseLrc(String source) {
  final lines = <LyricLine>[];
  final offsetMatch = RegExp(r'\[offset:([+-]?\d+)\]').firstMatch(source);
  final offset = int.tryParse(offsetMatch?[1] ?? '0') ?? 0;
  final timestamp = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');
  for (final row in source.split(RegExp(r'\r?\n'))) {
    final stamps = timestamp.allMatches(row).toList();
    if (stamps.isEmpty) continue;
    final text = row.substring(stamps.last.end).trim();
    for (final match in stamps) {
      final second = int.parse(match[2]!);
      if (second >= 60) continue;
      final fraction = (match[3] ?? '').padRight(3, '0');
      final ms =
          int.parse(match[1]!) * 60000 +
          second * 1000 +
          int.parse(fraction) -
          offset;
      lines.add(LyricLine(Duration(milliseconds: max(0, ms)), text));
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

LyricLine? lyricAt(List<LyricLine> lines, Duration position) {
  var low = 0, high = lines.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (lines[middle].time <= position) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low == 0 ? null : lines[low - 1];
}

class CityWeather {
  CityWeather(this.name, this.temperature, this.humidity, this.code);
  factory CityWeather.fromJson(Map<String, dynamic> value) => CityWeather(
    value['name'] as String,
    (value['temperature'] as num).toDouble(),
    value['humidity'] as int,
    value['code'] as int,
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'temperature': temperature,
    'humidity': humidity,
    'code': code,
  };
  final String name;
  final double temperature;
  final int humidity, code;
  List<int> get packet {
    final t = (temperature * 10).round();
    final now = DateTime.now();
    return [
      7,
      0x51,
      4,
      (t >> 8) & 255,
      t & 255,
      humidity,
      code,
      now.hour,
      now.minute,
    ];
  }
}

Future<CityWeather> fetchWeather(String city) async {
  if (city.isEmpty || city.length > 100) {
    throw const FormatException('请输入有效城市名。');
  }
  Future<Map<String, dynamic>> get(Uri uri) async {
    final client = weatherClient();
    try {
      final result = await client.get(uri).timeout(const Duration(seconds: 15));
      if (result.statusCode != 200) throw StateError('天气服务暂时无法连接。');
      return jsonDecode(utf8.decode(result.bodyBytes)) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  final search = await get(
    Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': city,
      'count': '1',
      'language': 'zh',
      'format': 'json',
    }),
  );
  final locations = search['results'] as List?;
  if (locations == null || locations.isEmpty) {
    throw const FormatException('未找到城市，请试用城市英文名。');
  }
  final location = locations.first as Map<String, dynamic>;
  final result = await get(
    Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '${location['latitude']}',
      'longitude': '${location['longitude']}',
      'current': 'temperature_2m,relative_humidity_2m,weather_code',
    }),
  );
  final now = result['current'] as Map<String, dynamic>;
  return CityWeather(
    '${location['name']} · ${location['country'] ?? ''}',
    (now['temperature_2m'] as num).toDouble(),
    now['relative_humidity_2m'] as int,
    now['weather_code'] as int,
  );
}
