import 'package:flutter/services.dart';

import 'models.dart';
import 'lyrics_lookup.dart';
import 'media_features.dart';
import 'via.dart';

const _usb = MethodChannel('keyboard_control/usb');

class AndroidService implements KeyboardService {
  AndroidService(this.boards);
  final List<Board> boards;

  @override
  Future<List<int>> metrics() async => [255, 255, 255, 255];
  final _lyrics = LyricsLookup();
  @override
  Future<Json> nowPlaying() async => throw StateError('请使用桌面端连接链接，跟随电脑上的系统音乐。');
  @override
  Future<Json> lyrics(Json track) => _lyrics.find(track);
  @override
  Future<Json> weather(String city) async =>
      (await fetchWeather(city)).toJson();

  @override
  Future<List<List<int>>> companion(
    DeviceRef device,
    List<List<int>> packets,
  ) async {
    validatePackets(packets);
    final board = boards.firstWhere((item) => item.id == device.model);
    await _usb.invokeMethod<void>('open', {
      'id': device.id,
      'vid': board.vid,
      'pid': board.pid,
    });
    final port = _AndroidPort();
    try {
      final via = ViaSession(port, board);
      return [
        for (final p in packets)
          (await via.request(p[0], p.sublist(1), 2)).toList(),
      ];
    } finally {
      await port.close();
    }
  }

  @override
  Future<List<DeviceRef>> scan() async {
    final devices = await _usb.invokeListMethod<dynamic>('scan') ?? [];
    return [
      for (final dynamic item in devices)
        for (final board in boards)
          if (item['vid'] == board.vid && item['pid'] == board.pid)
            DeviceRef(
              item['id'] as String,
              board.id,
              '${board.name} · USB',
              firmwareVersion: firmwareVersionFromUsbVersion(
                item['version'] as String?,
              ),
            ),
    ];
  }

  @override
  Future<Profile> read(DeviceRef device) => _perform(device, null, null);

  @override
  Future<Profile> apply(DeviceRef device, Profile before, Profile after) =>
      _perform(device, before, after);

  Future<Profile> _perform(
    DeviceRef device,
    Profile? before,
    Profile? after,
  ) async {
    final board = boards.firstWhere((item) => item.id == device.model);
    await _usb.invokeMethod<void>('open', {
      'id': device.id,
      'vid': board.vid,
      'pid': board.pid,
    });
    final port = _AndroidPort();
    try {
      final via = ViaSession(port, board);
      return before == null
          ? await via.read()
          : await via.apply(before, after!);
    } finally {
      await port.close();
    }
  }
}

class _AndroidPort implements ReportPort {
  @override
  Future<Uint8List> exchange(Uint8List payload) async =>
      (await _usb.invokeMethod<Uint8List>('exchange', payload)) ?? Uint8List(0);
  @override
  Future<void> close() => _usb.invokeMethod<void>('close');
}
