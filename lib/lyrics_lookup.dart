import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'weather_client.dart';

class LyricsLookup {
  LyricsLookup({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? weatherClient;
  final http.Client Function() _clientFactory;
  final _cache = <String, ({DateTime time, Json value})>{};
  final _pending = <String, Future<Json>>{};
  DateTime? _retry;
  Future<Json> find(Json track) async {
    final title = (track['title'] as String? ?? '').trim();
    final artist = (track['artist'] as String? ?? '').trim();
    final album = (track['album'] as String? ?? '').trim();
    final duration = ((track['duration'] as num? ?? 0) / 1000).round();
    if (title.isEmpty ||
        title.length > 300 ||
        artist.length > 300 ||
        album.length > 300) {
      throw StateError('播放器尚未提供有效曲名。');
    }
    final key = jsonEncode([title, artist, album, duration]);
    final hit = _cache[key];
    if (hit != null &&
        DateTime.now().difference(hit.time).inMinutes <
            (hit.value['lrc'] == null ? 10 : 1440)) {
      return hit.value;
    }
    if (_pending[key] != null) return _pending[key]!;
    if (_retry != null && DateTime.now().isBefore(_retry!)) {
      throw StateError('歌词服务限流，请稍后再试。');
    }
    final future = _fetch(title, artist, album, duration);
    _pending[key] = future;
    try {
      final value = await future;
      if (_cache.length >= 100) _cache.remove(_cache.keys.first);
      _cache[key] = (time: DateTime.now(), value: value);
      return value;
    } finally {
      _pending.remove(key);
    }
  }

  Future<Json> _fetch(
    String title,
    String artist,
    String album,
    int duration,
  ) async {
    final client = _clientFactory();
    Future<dynamic> get(String path, Map<String, String> args) async {
      final response = await client
          .get(
            Uri.https('lrclib.net', path, args),
            headers: {
              'Lrclib-Client': 'OpenKeyBoad v0.3.2 (https://github.com/JasonYANG170/OpenKeyBoad)',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 429) {
        _retry = DateTime.now().add(
          Duration(
            seconds:
                (int.tryParse(response.headers['retry-after'] ?? '') ?? 60)
                    .clamp(1, 3600) +
                2,
          ),
        );
        throw StateError('歌词服务限流，请稍后再试。');
      }
      if (response.statusCode == 404) return null;
      if (response.statusCode != 200) throw StateError('歌词服务暂时不可用。');
      if (response.bodyBytes.length > 2 * 1024 * 1024) {
        throw StateError('歌词响应过大。');
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    try {
      if (artist.isEmpty) return {'status': '播放器未提供歌手信息，暂时无法匹配歌词。'};
      if (duration > 0 && duration <= 86400) {
        final exact = await get('/api/get', {
          'track_name': title,
          'artist_name': artist,
          if (album.isNotEmpty) 'album_name': album,
          'duration': '$duration',
        });
        if (exact is Json &&
            (exact['syncedLyrics'] as String? ?? '').isNotEmpty) {
          return {'lrc': exact['syncedLyrics'], 'status': '已自动匹配同步歌词 · LRCLIB'};
        }
        if (exact is Json && exact['instrumental'] == true) {
          return {'status': '这首歌曲为纯音乐。'};
        }
      }
      final matches = await get('/api/search', {
        'track_name': title,
        'artist_name': artist,
      });
      final candidates = matches is List
          ? matches
                .whereType<Json>()
                .where(
                  (m) =>
                      (m['syncedLyrics'] as String? ?? '').isNotEmpty &&
                      (m['trackName'] as String? ?? '').toLowerCase().trim() ==
                          title.toLowerCase() &&
                      (m['artistName'] as String? ?? '').toLowerCase().trim() ==
                          artist.toLowerCase() &&
                      (duration == 0 ||
                          ((m['duration'] as num? ?? -100) - duration).abs() <=
                              3),
                )
                .toList()
          : <Json>[];
      if (candidates.isNotEmpty) {
        candidates.sort(
          (a, b) => ((a['duration'] as num) - duration).abs().compareTo(
            ((b['duration'] as num) - duration).abs(),
          ),
        );
        return {
          'lrc': candidates.first['syncedLyrics'],
          'status': '已自动匹配同步歌词 · LRCLIB',
        };
      }
      return {'status': '未找到该版本的同步歌词。'};
    } finally {
      client.close();
    }
  }
}
