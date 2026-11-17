import 'dart:convert';
import 'dart:math';

import 'weather_client.dart';

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
  CityWeather(
    this.name,
    this.temperature,
    this.humidity,
    this.code, {
    this.minimum,
    this.maximum,
    this.rain,
    this.uv,
    this.aqi,
    this.pm25,
  });
  factory CityWeather.fromJson(Map<String, dynamic> value) => CityWeather(
    value['name'] as String,
    (value['temperature'] as num).toDouble(),
    value['humidity'] as int,
    value['code'] as int,
    minimum: (value['minimum'] as num?)?.toDouble(),
    maximum: (value['maximum'] as num?)?.toDouble(),
    rain: (value['rain'] as num?)?.round(),
    uv: (value['uv'] as num?)?.toDouble(),
    aqi: (value['aqi'] as num?)?.round(),
    pm25: (value['pm25'] as num?)?.toDouble(),
  );
  Map<String, dynamic> toJson() => {
    'name': name,
    'temperature': temperature,
    'humidity': humidity,
    'code': code,
    'minimum': minimum,
    'maximum': maximum,
    'rain': rain,
    'uv': uv,
    'aqi': aqi,
    'pm25': pm25,
  };
  final String name;
  final double temperature;
  final int humidity, code;
  final double? minimum, maximum, uv, pm25;
  final int? rain, aqi;
  List<int> get detailsPacket {
    int safe(num? n, num scale, int limit, int missing) =>
        n == null || !n.isFinite
        ? missing
        : (n * scale).round().clamp(0, limit);
    List<int> word(int value) => [(value >> 8) & 255, value & 255];
    int temperature(double? n) =>
        n == null || !n.isFinite ? 32767 : (n * 10).round().clamp(-1000, 800);
    return [
      7,
      0x51,
      14,
      ...word(temperature(minimum)),
      ...word(temperature(maximum)),
      safe(rain, 1, 100, 255),
      safe(uv, 10, 250, 255),
      ...word(safe(aqi, 1, 500, 65535)),
      ...word(safe(pm25, 10, 65534, 65535)),
    ];
  }

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
  final coordinates = {
    'latitude': '${location['latitude']}',
    'longitude': '${location['longitude']}',
    'timezone': 'auto',
  };
  final airRequest = get(
    Uri.https('air-quality-api.open-meteo.com', '/v1/air-quality', {
      ...coordinates,
      'current': 'us_aqi,pm2_5',
    }),
  ).catchError((Object _) => <String, dynamic>{});
  final result = await get(
    Uri.https('api.open-meteo.com', '/v1/forecast', {
      ...coordinates,
      'current': 'temperature_2m,relative_humidity_2m,weather_code',
      'daily': 'temperature_2m_min,temperature_2m_max,precipitation_probability_max,uv_index_max',
      'forecast_days': '1',
    }),
  );
  final now = result['current'] as Map<String, dynamic>;
  final daily = result['daily'] as Map<String, dynamic>? ?? {};
  final air = (await airRequest)['current'] as Map<String, dynamic>? ?? {};
  double? first(String name) {
    final values = daily[name] as List?;
    return values != null && values.isNotEmpty
        ? (values.first as num?)?.toDouble()
        : null;
  }

  return CityWeather(
    '${location['name']} · ${location['country'] ?? ''}',
    (now['temperature_2m'] as num).toDouble(),
    now['relative_humidity_2m'] as int,
    now['weather_code'] as int,
    minimum: first('temperature_2m_min'),
    maximum: first('temperature_2m_max'),
    rain: first('precipitation_probability_max')?.round(),
    uv: first('uv_index_max'),
    aqi: (air['us_aqi'] as num?)?.round(),
    pm25: (air['pm2_5'] as num?)?.toDouble(),
  );
}
