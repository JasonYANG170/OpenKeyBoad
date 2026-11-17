import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class BridgeService implements KeyboardService, OnlineHostService {
  BridgeService(this.base, this.token, this.boards);
  final Uri base;
  final String token;
  final List<Board> boards;
  @override
  Future<Json> network() => _request('/api/network');
  @override
  Future<Json> audio(bool enabled) =>
      _request('/api/audio', {'enabled': enabled});

  @override
  Future<Json> nowPlaying() => _request('/api/now-playing');
  @override
  Future<Json> lyrics(Json track) => _request('/api/lyrics', track);
  @override
  Future<Json> weather(String city) =>
      _request('/api/weather?city=${Uri.encodeQueryComponent(city)}');

  @override
  Future<List<int>> metrics() async =>
      ((await _request('/api/metrics'))['values'] as List).cast<int>();

  @override
  Future<List<List<int>>> companion(
    DeviceRef device,
    List<List<int>> packets,
  ) async =>
      ((await _request(
                '/api/companion/${device.model}/${Uri.encodeComponent(device.id)}',
                {'packets': packets},
              ))['packets']
              as List)
          .map((p) => (p as List).cast<int>())
          .toList();

  static BridgeService fromLink(String link, List<Board> boards) {
    final uri = Uri.parse(link.trim());
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.length < 32) {
      throw const FormatException('请输入桌面端提供的完整连接链接。');
    }
    return BridgeService(
      uri.removeFragment().resolve('/'),
      uri.fragment,
      boards,
    );
  }

  @override
  Future<List<DeviceRef>> scan() async =>
      ((await _request('/api/devices'))['devices'] as List)
          .cast<Json>()
          .map(DeviceRef.fromJson)
          .toList();

  @override
  Future<Profile> read(DeviceRef device) async =>
      _profile(device, await _request(_route(device)));

  @override
  Future<Profile> apply(
    DeviceRef device,
    Profile before,
    Profile after,
  ) async => _profile(
    device,
    await _request(_route(device), {
      'before': before.toJson(),
      'after': after.toJson(),
    }),
  );

  String _route(DeviceRef device) =>
      '/api/profile/${device.model}/${Uri.encodeComponent(device.id)}';
  Profile _profile(DeviceRef device, Json json) => Profile.fromJson(
    boards.firstWhere((board) => board.id == device.model),
    json,
  );

  Future<Json> _request(String path, [Json? data]) async {
    final request = data == null
        ? http.get(
            base.resolve(path),
            headers: {'Authorization': 'Bearer $token'},
          )
        : http.post(
            base.resolve(path),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(data),
          );
    final response = await request.timeout(const Duration(seconds: 60));
    if (response.statusCode == 401) throw StateError('连接链接已失效，请从桌面端重新复制。');
    final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
    if (response.statusCode != 200) {
      throw StateError(decoded['error'] as String? ?? '桌面端请求失败。');
    }
    return decoded;
  }
}
