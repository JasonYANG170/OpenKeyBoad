import 'dart:typed_data';

import 'models.dart';

abstract interface class ReportPort {
  Future<Uint8List> exchange(Uint8List payload);
  Future<void> close();
}

class ViaSession {
  ViaSession(this.port, this.board);
  final ReportPort port;
  final Board board;

  Future<Uint8List> request(
    int command, [
    List<int> data = const [],
    int echo = 0,
  ]) async {
    final payload = Uint8List(32);
    payload[0] = command;
    payload.setRange(1, 1 + data.length, data);
    final response = await port.exchange(payload);
    if (response.length != 32 || response[0] != command) {
      throw StateError(
        'VIA 命令 0x${command.toRadixString(16)} 未应答。请关闭其他 VIA 工具并重试。',
      );
    }
    for (var i = 1; i <= echo; i++) {
      if (response[i] != payload[i]) throw StateError('收到不匹配的 VIA 应答，请重新连接键盘。');
    }
    return response;
  }

  Future<void> verify() async {
    final protocol = await request(0x01);
    if (_word(protocol, 1) != 12 || (await request(0x11))[1] != board.layers) {
      throw StateError('键盘的 VIA 固件与本应用支持的版本不匹配。');
    }
  }

  Future<Profile> read() async {
    await verify();
    final size = board.layers * board.rows * board.cols * 2;
    final buffer = Uint8List(size);
    for (var offset = 0; offset < size; offset += 28) {
      final length = (size - offset).clamp(0, 28);
      final result = await request(0x12, [
        offset >> 8,
        offset & 255,
        length,
      ], 3);
      buffer.setRange(offset, offset + length, result, 4);
    }
    final keys = <List<int>>[];
    final encoders = <List<int>>[];
    for (var layer = 0; layer < board.layers; layer++) {
      keys.add([
        for (final key in board.keys)
          _word(
            buffer,
            ((layer * board.rows + key.row) * board.cols + key.column) * 2,
          ),
      ]);
      encoders.add([
        for (var direction = 0; direction < 2; direction++)
          _word(await request(0x14, [layer, 0, direction], 3), 4),
      ]);
    }
    final color = await request(0x08, [3, 4], 2);
    final macroCount = (await request(0x0c))[1];
    final macroSize = _word(await request(0x0d), 1);
    if (macroCount > 32 || macroSize > 4096) throw StateError('宏存储布局不受支持。');
    final macros = Uint8List(macroSize);
    for (var offset = 0; offset < macroSize; offset += 28) {
      final count = minInt(28, macroSize - offset);
      final chunk = await request(0x0e, [offset >> 8, offset & 255, count], 3);
      macros.setRange(offset, offset + count, chunk, 4);
    }
    return Profile(
      board.id,
      keys,
      encoders,
      Lighting(
        (await request(0x08, [3, 1], 2))[3],
        (await request(0x08, [3, 2], 2))[3],
        (await request(0x08, [3, 3], 2))[3],
        color[3],
        color[4],
      ),
      macros: macros,
      macroCount: macroCount,
    );
  }

  Future<Profile> apply(Profile before, Profile after) async {
    final current = await read();
    if (current.serialized != before.serialized) {
      throw StateError('设备配置已变动。请重新读取，再编辑并应用。');
    }
    if (after.macros == null) {
      after = after.withMacros(current.macros, current.macroCount);
    }
    if (after.macros!.length != current.macros!.length ||
        after.macroCount != current.macroCount) {
      throw const FormatException('宏配置的容量与当前固件不匹配。');
    }
    if (after.light.effect >= board.effects.length &&
        current.light.effect != after.light.effect) {
      throw const FormatException('导入的灯效不适用于当前固件。');
    }

    try {
      if (!_equalMatrix([current.macros!], [after.macros!])) {
        final bytes = after.macros!;
        if (bytes.isEmpty || bytes.last != 0) {
          throw const FormatException('宏缓冲区缺少结束标记。');
        }
        final last = bytes.length - 1;
        await request(0x0f, [last >> 8, last & 255, 1, 255], 4);
        for (var offset = 0; offset < last; offset += 28) {
          final count = minInt(28, last - offset);
          await request(0x0f, [
            offset >> 8,
            offset & 255,
            count,
            ...bytes.sublist(offset, offset + count),
          ], 3);
        }
        await request(0x0f, [last >> 8, last & 255, 1, 0], 4);
      }
      for (var layer = 0; layer < board.layers; layer++) {
        for (var index = 0; index < board.keys.length; index++) {
          final code = after.keys[layer][index];
          if (code != current.keys[layer][index]) {
            final key = board.keys[index];
            await request(0x05, [
              layer,
              key.row,
              key.column,
              code >> 8,
              code & 255,
            ], 5);
          }
        }
        for (var direction = 0; direction < 2; direction++) {
          final code = after.encoders[layer][direction];
          if (code != current.encoders[layer][direction]) {
            await request(0x15, [
              layer,
              0,
              direction,
              code >> 8,
              code & 255,
            ], 5);
          }
        }
      }
      await _setLighting(current.light, after.light);
      final verified = await read();
      final a = verified.light;
      final b = after.light;
      if (!_equalMatrix(verified.keys, after.keys) ||
          !_equalMatrix([verified.macros!], [after.macros!]) ||
          !_equalMatrix(verified.encoders, after.encoders) ||
          (a.brightness - b.brightness).abs() > 3 ||
          a.effect != b.effect ||
          a.speed != b.speed ||
          a.hue != b.hue ||
          a.saturation != b.saturation) {
        throw StateError('设备读回值与预期有差异。');
      }
      return verified;
    } catch (error) {
      throw StateError('应用未完成，已有部分改动可能已写入。请重新读取设备。\n$error');
    }
  }

  Future<void> _setLighting(Lighting before, Lighting after) async {
    final commands = <List<int>>[];
    if (before.brightness != after.brightness) {
      commands.add([3, 1, after.brightness]);
    }
    if (before.effect != after.effect) commands.add([3, 2, after.effect]);
    if (before.speed != after.speed) commands.add([3, 3, after.speed]);
    if (before.hue != after.hue || before.saturation != after.saturation) {
      commands.add([3, 4, after.hue, after.saturation]);
    }
    for (final command in commands) {
      await request(0x07, command, command.length);
    }
    if (commands.isNotEmpty) await request(0x09, [3], 1);
  }
}

int minInt(int a, int b) => a < b ? a : b;

int _word(List<int> data, int offset) => (data[offset] << 8) | data[offset + 1];

bool _equalMatrix(List<List<int>> a, List<List<int>> b) {
  for (var row = 0; row < a.length; row++) {
    for (var col = 0; col < a[row].length; col++) {
      if (a[row][col] != b[row][col]) return false;
    }
  }
  return true;
}

void validatePackets(List<List<int>> packets) {
  if (packets.isEmpty ||
      packets.length > 128 ||
      packets.any(
        (p) =>
            p.length < 3 ||
            p.length > 32 ||
            (p[0] != 7 && p[0] != 8) ||
            p[1] != 0x51 ||
            p.any((v) => v < 0 || v > 255),
      )) {
    throw const FormatException('扩展数据包格式错误。');
  }
}
