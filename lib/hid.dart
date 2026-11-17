import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'models.dart';
import 'via.dart';
import 'metrics.dart';
import 'host_media.dart';
import 'lyrics_lookup.dart';
import 'media_features.dart';

final class _HidInfo extends Struct {
  external Pointer<Utf8> path;
  @Uint16()
  external int vendorId;
  @Uint16()
  external int productId;
  external Pointer<Void> serial;
  @Uint16()
  external int release;
  external Pointer<Void> manufacturer;
  external Pointer<Void> product;
  @Uint16()
  external int usagePage;
  @Uint16()
  external int usage;
  @Int32()
  external int interfaceNumber;
  external Pointer<_HidInfo> next;
}

class _Hid {
  _Hid() : library = _openLibrary();
  final DynamicLibrary library;
  late final enumerate = library
      .lookupFunction<
        Pointer<_HidInfo> Function(Uint16, Uint16),
        Pointer<_HidInfo> Function(int, int)
      >('hid_enumerate');
  late final freeEnumeration = library
      .lookupFunction<
        Void Function(Pointer<_HidInfo>),
        void Function(Pointer<_HidInfo>)
      >('hid_free_enumeration');
  late final open = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Uint8>)
      >('hid_open_path');
  late final write = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Size),
        int Function(Pointer<Void>, Pointer<Uint8>, int)
      >('hid_write');
  late final read = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Int32),
        int Function(Pointer<Void>, Pointer<Uint8>, int, int)
      >('hid_read_timeout');
  late final close = library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('hid_close');

  static DynamicLibrary _openLibrary() {
    final executable = File(Platform.resolvedExecutable).parent.path;
    final configured = Platform.environment['KEYBOARD_HIDAPI'];
    final names = [
      ?configured,
      if (Platform.isWindows) ...['$executable\\hidapi.dll', 'hidapi.dll'],
      if (Platform.isLinux) ...['libhidapi-hidraw.so.0', 'libhidapi-hidraw.so'],
      if (Platform.isMacOS) ...[
        '$executable/../Frameworks/libhidapi.dylib',
        '$executable/libhidapi.dylib',
        '/opt/homebrew/lib/libhidapi.dylib',
        '/usr/local/lib/libhidapi.dylib',
        'libhidapi.dylib',
      ],
    ];
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } on ArgumentError {
        continue;
      }
    }
    throw StateError('没有找到 HIDAPI 库。安装方式见 README。');
  }

  List<DeviceRef> scan(List<Board> boards) {
    final result = <DeviceRef>[];
    for (final board in boards) {
      final list = enumerate(board.vid, board.pid);
      try {
        for (var ptr = list; ptr != nullptr; ptr = ptr.ref.next) {
          final info = ptr.ref;
          if (info.usagePage != 0xff60 ||
              info.usage != 0x61 ||
              info.path == nullptr) {
            continue;
          }
          // A HID path is an opaque, null-terminated byte string.
          final bytes = <int>[];
          final path = info.path.cast<Uint8>();
          for (var i = 0; path[i] != 0; i++) {
            bytes.add(path[i]);
          }
          final number =
              result.where((item) => item.model == board.id).length + 1;
          result.add(
            DeviceRef(
              base64UrlEncode(bytes),
              board.id,
              '${board.name} · USB $number',
            ),
          );
        }
      } finally {
        if (list != nullptr) freeEnumeration(list);
      }
    }
    return result;
  }

  ReportPort connect(Board board, String id) {
    if (!scan([board]).any((device) => device.id == id)) {
      throw StateError('键盘已断开，请重新扫描。');
    }
    final path = base64Url.decode(id);
    final memory = calloc<Uint8>(path.length + 1);
    try {
      memory.asTypedList(path.length).setAll(0, path);
      final handle = open(memory);
      if (handle == nullptr) throw StateError('无法打开键盘，请检查权限并关闭其他 VIA 工具。');
      return _HidPort(this, handle);
    } finally {
      calloc.free(memory);
    }
  }
}

class _HidPort implements ReportPort {
  _HidPort(this.hid, this.handle);
  final _Hid hid;
  final Pointer<Void> handle;

  @override
  Future<Uint8List> exchange(Uint8List payload) async {
    final data = calloc<Uint8>(33);
    try {
      data.asTypedList(33).setAll(1, payload);
      if (hid.write(handle, data, 33) != 33) throw StateError('USB HID 写入失败。');
      final count = hid.read(handle, data, 33, 1800);
      if (count == 33 && data[0] == 0) {
        return Uint8List.fromList(data.asTypedList(33).sublist(1));
      }
      if (count == 32) return Uint8List.fromList(data.asTypedList(32));
      throw StateError('VIA 读取超时或键盘已断开。');
    } finally {
      calloc.free(data);
    }
  }

  @override
  Future<void> close() async => hid.close(handle);
}

class DesktopService implements KeyboardService {
  DesktopService(this.boards);
  final List<Board> boards;

  @override
  Future<List<int>> metrics() => sampleHost();
  final _media = HostMedia();
  final _lyrics = LyricsLookup();
  @override
  Future<Json> nowPlaying() => _media.current();
  @override
  Future<Json> lyrics(Json track) => _lyrics.find(track);
  @override
  Future<Json> weather(String city) async =>
      (await fetchWeather(city)).toJson();

  @override
  Future<List<List<int>>> companion(DeviceRef device, List<List<int>> packets) {
    final board = boards.firstWhere((board) => board.id == device.model);
    validatePackets(packets);
    return Isolate.run(() async {
      final port = _Hid().connect(board, device.id);
      try {
        final via = ViaSession(port, board);
        return [
          for (final p in packets)
            (await via.request(p[0], p.sublist(1), 2)).toList(),
        ];
      } finally {
        await port.close();
      }
    });
  }

  @override
  Future<List<DeviceRef>> scan() {
    final known = boards;
    return Isolate.run(() => _Hid().scan(known));
  }

  @override
  Future<Profile> read(DeviceRef device) => _execute(device, null, null);

  @override
  Future<Profile> apply(DeviceRef device, Profile before, Profile after) =>
      _execute(device, before, after);

  Future<Profile> _execute(DeviceRef device, Profile? before, Profile? after) {
    final board = boards.firstWhere((board) => board.id == device.model);
    return Isolate.run(() async {
      final port = _Hid().connect(board, device.id);
      try {
        final via = ViaSession(port, board);
        return before == null
            ? await via.read()
            : await via.apply(before, after!);
      } finally {
        await port.close();
      }
    });
  }
}
