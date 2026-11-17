import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyboard_control/models.dart';
import 'package:keyboard_control/via.dart';
import 'package:keyboard_control/chords.dart';

Board load(String name) => Board.fromJson(
  jsonDecode(File('assets/$name.json').readAsStringSync()) as Json,
);

class _SimulatedPort implements ReportPort {
  _SimulatedPort(this.board)
    : memory = Uint8List(board.rows * board.cols * board.layers * 2) {
    final defaults = board.preview();
    for (var layer = 0; layer < board.layers; layer++) {
      for (var i = 0; i < board.keys.length; i++) {
        final key = board.keys[i];
        _store(layer, key.row, key.column, defaults.keys[layer][i]);
      }
    }
    encoders = defaults.encoders.map(List<int>.of).toList();
  }
  final Board board;
  final Uint8List memory;
  late final List<List<int>> encoders;
  final settings = {
    1: [130],
    2: [1],
    3: [118],
    4: [150, 240],
  };
  int changes = 0;
  int saves = 0;
  final macros = Uint8List(256);

  void _store(int layer, int row, int col, int code) {
    final index = ((layer * board.rows + row) * board.cols + col) * 2;
    memory[index] = code >> 8;
    memory[index + 1] = code & 255;
  }

  @override
  Future<Uint8List> exchange(Uint8List payload) async {
    final result = Uint8List.fromList(payload);
    final code = (payload[4] << 8) | payload[5];
    switch (payload[0]) {
      case 1:
        result[2] = 12;
      case 0x11:
        result[1] = board.layers;
      case 0x0c:
        result[1] = 16;
      case 0x0d:
        result[1] = 1;
        result[2] = 0;
      case 0x0e:
        final offset = (payload[1] << 8) | payload[2];
        result.setRange(4, 4 + payload[3], macros, offset);
      case 0x0f:
        final offset = (payload[1] << 8) | payload[2];
        macros.setRange(offset, offset + payload[3], payload, 4);
      case 0x12:
        final offset = (payload[1] << 8) | payload[2];
        result.setRange(4, 4 + payload[3], memory, offset);
      case 5:
        changes++;
        _store(payload[1], payload[2], payload[3], code);
      case 0x14:
        final entry = encoders[payload[1]][payload[3]];
        result[4] = entry >> 8;
        result[5] = entry & 255;
      case 0x15:
        changes++;
        encoders[payload[1]][payload[3]] = code;
      case 8:
        final value = settings[payload[2]]!;
        result.setRange(3, 3 + value.length, value);
      case 7:
        changes++;
        settings[payload[2]] = payload.sublist(3, payload[2] == 4 ? 5 : 4);
      case 9:
        saves++;
      default:
        throw StateError('Unknown command');
    }
    return result;
  }

  @override
  Future<void> close() async {}
}

void main() {
  for (final id in ['rs2', 'ak650']) {
    final board = load(id);
    test(
      '$id maps all matrix cells and applies only modified settings',
      () async {
        final port = _SimulatedPort(board);
        final via = ViaSession(port, board);
        final before = await via.read();
        expect(before.keys, board.defaults);
        final after = before
            .withKey(3, board.keys.length - 1, 0x5220)
            .withKey(1, 1, 0x00a8, encoder: true)
            .withLight(
              before.light.copyWith(effect: 3, hue: 14, saturation: 185),
            );
        expect((await via.apply(before, after)).serialized, after.serialized);
        expect(port.changes, 4);
        expect(port.saves, 1);
        await expectLater(via.apply(before, after), throwsStateError);
        expect(port.changes, 4);
      },
    );
  }
  test('backup rejects a different model and invalid key codes', () {
    final rs2 = load('rs2'), ak650 = load('ak650');
    expect(
      () => Profile.fromJson(ak650, rs2.preview().toJson()),
      throwsFormatException,
    );
    final backup = jsonDecode(rs2.preview().serialized) as Json;
    backup['keys'][0][1] = 65536;
    expect(() => Profile.fromJson(rs2, backup), throwsFormatException);
  });
  test(
    'mixed side modifiers and multi-key chords persist in the macro buffer',
    () async {
      final board = load('rs2');
      final via = ViaSession(_SimulatedPort(board), board);
      final original = await via.read();
      final chord = assignChord(original, 0, 12, [0xe0, 0xe5, 4, 5]);
      expect(chord.keys[0][12], 0x7700);
      expect(macroEntries(chord).first, [
        1,
        2,
        0xe0,
        1,
        2,
        0xe5,
        1,
        2,
        4,
        1,
        2,
        5,
        1,
        3,
        5,
        1,
        3,
        4,
        1,
        3,
        0xe5,
        1,
        3,
        0xe0,
      ]);
      expect((await via.apply(original, chord)).serialized, chord.serialized);
      final next = assignChord(chord, 0, 13, [0xe2, 6]);
      expect(next.keys[0][13], 0x7701);
      expect(macroEntries(next).first, macroEntries(chord).first);
    },
  );
}
