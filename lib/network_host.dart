import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'models.dart';
import 'online_models.dart';

class HostNetwork {
  final _clock = Stopwatch()..start();
  final _rates = NetworkRates();
  Future<Json> sample() async {
    try {
      final counters = <String, (int, int)>{};
      if (Platform.isWindows) {
        final library = DynamicLibrary.open('iphlpapi.dll');
        final get = library
            .lookupFunction<
              Uint32 Function(Pointer<Pointer<Uint8>>),
              int Function(Pointer<Pointer<Uint8>>)
            >('GetIfTable2');
        final free = library
            .lookupFunction<
              Void Function(Pointer<Uint8>),
              void Function(Pointer<Uint8>)
            >('FreeMibTable');
        final result = calloc<Pointer<Uint8>>();
        try {
          if (get(result) != 0 || result.value == nullptr) {
            throw StateError('Network counters unavailable');
          }
          final table = result.value;
          try {
            final count = table.cast<Uint32>().value;
            if (count > 100000 || sizeOf<_IfRow2>() != 1352) {
              throw StateError('Unsupported network table ABI');
            }
            final rows = (table + 8).cast<_IfRow2>();
            for (var i = 0; i < count; i++) {
              final row = rows[i];
              if ((row.type != 6 && row.type != 71) ||
                  row.oper != 1 ||
                  (row.flags & 3) != 1) {
                continue;
              }
              counters['${row.luid}'] = (row.counters[0], row.counters[9]);
            }
          } finally {
            free(table);
          }
        } finally {
          calloc.free(result);
        }
      } else if (Platform.isLinux) {
        for (final line in await File('/proc/net/dev').readAsLines()) {
          final parts = line.split(':');
          if (parts.length != 2) continue;
          final name = parts[0].trim();
          if (!await Directory('/sys/class/net/$name/device').exists()) {
            continue;
          }
          final numbers = parts[1].trim().split(RegExp(r'\s+'));
          counters[name] = (int.parse(numbers[0]), int.parse(numbers[8]));
        }
      } else if (Platform.isMacOS) {
        final process = await Process.start('/usr/sbin/netstat', ['-ibn']);
        try {
          final output = await process.stdout
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 3));
          await process.exitCode.timeout(const Duration(seconds: 1));
          final lines = output.split('\n');
          final header = lines.first.trim().split(RegExp(r'\s+'));
          final rx = header.indexOf('Ibytes'), tx = header.indexOf('Obytes');
          for (final line in lines.skip(1)) {
            final cells = line.trim().split(RegExp(r'\s+'));
            if (rx < 0 ||
                tx < 0 ||
                cells.length <= tx ||
                !RegExp(r'^en\d+$').hasMatch(cells[0]) ||
                counters.containsKey(cells[0])) {
              continue;
            }
            final received = int.tryParse(cells[rx]),
                sent = int.tryParse(cells[tx]);
            if (received != null && sent != null) {
              counters[cells[0]] = (received, sent);
            }
          }
        } finally {
          process.kill();
        }
      } else {
        return {'supported': false};
      }
      return _rates.update(
        counters,
        _clock.elapsed,
        wrap32: Platform.isWindows,
      );
    } catch (_) {
      return {'supported': false, 'status': '暂时无法读取物理网卡计数'};
    }
  }
}

// Windows MIB_IF_ROW2 uses 8-byte alignment. Keep the GUIDs and bounded WCHAR
// arrays explicit so FFI supplies native padding, including before link speeds.
final class _IfRow2 extends Struct {
  @Uint64()
  external int luid;
  @Uint32()
  external int index;
  @Array(16)
  external Array<Uint8> guid;
  @Array(257)
  external Array<Uint16> alias;
  @Array(257)
  external Array<Uint16> description;
  @Uint32()
  external int addressLength;
  @Array(32)
  external Array<Uint8> address;
  @Array(32)
  external Array<Uint8> permanent;
  @Uint32()
  external int mtu;
  @Uint32()
  external int type;
  @Uint32()
  external int tunnel;
  @Uint32()
  external int medium;
  @Uint32()
  external int physicalMedium;
  @Uint32()
  external int access;
  @Uint32()
  external int direction;
  @Uint8()
  external int flags;
  @Uint32()
  external int oper;
  @Uint32()
  external int admin;
  @Uint32()
  external int mediaState;
  @Array(16)
  external Array<Uint8> networkGuid;
  @Uint32()
  external int connection;
  @Uint64()
  external int transmitSpeed;
  @Uint64()
  external int receiveSpeed;
  @Array(18)
  external Array<Uint64> counters;
}
