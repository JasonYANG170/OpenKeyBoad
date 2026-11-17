import 'dart:convert';
import 'dart:io';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

int _percent(num? n) => n == null ? 255 : n.round().clamp(0, 100);

Future<ProcessResult> _run(String program, List<String> args) async {
  final process = await Process.start(program, args);
  try {
    final result = await Future.wait([
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
      process.exitCode,
    ]).timeout(const Duration(seconds: 8));
    return ProcessResult(process.pid, result[2] as int, result[0], result[1]);
  } catch (_) {
    process.kill();
    rethrow;
  }
}

Future<List<int>> sampleHost() async {
  if (Platform.isWindows) return _windowsMetrics();
  if (Platform.isLinux) {
    Future<List<int>> ticks() async => (await File('/proc/stat').readAsLines())
        .first
        .trim()
        .split(RegExp(r'\s+'))
        .skip(1)
        .take(8)
        .map(int.parse)
        .toList();
    final before = await ticks();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final after = await ticks();
    final total = List.generate(
      8,
      (i) => after[i] - before[i],
    ).fold<int>(0, (a, b) => a + b);
    final cpu = total > 0
        ? _percent(
            100 *
                (1 - ((after[3] - before[3]) + (after[4] - before[4])) / total),
          )
        : 255;
    final mem = <String, int>{};
    for (final line in await File('/proc/meminfo').readAsLines()) {
      final match = RegExp(r'^(MemTotal|MemAvailable):\s+(\d+)')
          .firstMatch(line);
      if (match != null) mem[match[1]!] = int.parse(match[2]!);
    }
    final ram = _percent(100 * (1 - mem['MemAvailable']! / mem['MemTotal']!));
    final df = await _run('df', ['-P', '/']);
    final match = RegExp(r'(\d+)%').firstMatch(df.stdout as String);
    return [cpu, ram, await _gpu(), match == null ? 255 : int.parse(match[1]!)];
  }
  if (Platform.isMacOS) {
    final cpu = await _run('/usr/bin/top', ['-l', '2', '-n', '0', '-s', '1']);
    final matches = RegExp(r'CPU usage:.*?([\d.]+)% idle')
        .allMatches(cpu.stdout as String);
    final memory = await _run('/usr/bin/memory_pressure', []);
    final free = RegExp(r'System-wide memory free percentage:\s*(\d+)%')
        .firstMatch(memory.stdout as String);
    final disk = await _run('/bin/df', ['-P', '/System/Volumes/Data']);
    final used = RegExp(r'(\d+)%').firstMatch(disk.stdout as String);
    return [
      matches.isEmpty ? 255 : _percent(100 - double.parse(matches.last[1]!)),
      free == null ? 255 : 100 - int.parse(free[1]!),
      await _gpu(),
      used == null ? 255 : int.parse(used[1]!),
    ];
  }
  return [255, 255, 255, 255];
}

Future<int> _gpu() async {
  try {
    final result = await _run('nvidia-smi', [
      '--query-gpu=utilization.gpu',
      '--format=csv,noheader,nounits',
    ]);
    if (result.exitCode == 0) {
      return _percent(
        num.tryParse((result.stdout as String).trim().split('\n').first),
      );
    }
  } on ProcessException {
    return 255;
  }
  return 255;
}

final class _MemoryStatus extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int load;
  @Uint64()
  external int totalPhysical;
  @Uint64()
  external int availablePhysical;
  @Uint64()
  external int totalPage;
  @Uint64()
  external int availablePage;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availableVirtual;
  @Uint64()
  external int extended;
}

int _lastGpu = 255;
DateTime? _gpuRequested;
bool _gpuRunning = false;

Future<List<int>> _windowsMetrics() async {
  final library = DynamicLibrary.open('kernel32.dll');
  final times = library
      .lookupFunction<
        Int32 Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
      >('GetSystemTimes');
  final memory = library
      .lookupFunction<
        Int32 Function(Pointer<_MemoryStatus>),
        int Function(Pointer<_MemoryStatus>)
      >('GlobalMemoryStatusEx');
  final disk = library
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetDiskFreeSpaceExW');
  final counts = calloc<Uint64>(6), drive = calloc<Uint64>(3);
  final mem = calloc<_MemoryStatus>();
  final path = ((Platform.environment['SystemDrive'] ?? 'C:') + r'\')
      .toNativeUtf16();
  try {
    if (times(counts, counts + 1, counts + 2) == 0) {
      throw StateError('CPU 采样失败。');
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    if (times(counts + 3, counts + 4, counts + 5) == 0) {
      throw StateError('CPU 采样失败。');
    }
    final total = (counts[4] - counts[1]) + (counts[5] - counts[2]);
    final cpu = total > 0
        ? _percent(100 * (1 - (counts[3] - counts[0]) / total))
        : 255;
    mem.ref.length = sizeOf<_MemoryStatus>();
    final ram = memory(mem) == 0 ? 255 : mem.ref.load;
    final used = disk(path, drive, drive + 1, drive + 2) != 0 && drive[1] > 0
        ? _percent(100 * (1 - drive[2] / drive[1]))
        : 255;
    if (!_gpuRunning &&
        (_gpuRequested == null ||
            DateTime.now().difference(_gpuRequested!).inSeconds >= 15)) {
      _gpuRunning = true;
      _gpuRequested = DateTime.now();
      _sampleWindowsGpu()
          .then((value) => _lastGpu = value)
          .catchError((Object _) => _lastGpu = 255)
          .whenComplete(() => _gpuRunning = false);
    }
    return [cpu, ram, _lastGpu, used];
  } finally {
    calloc.free(counts);
    calloc.free(drive);
    calloc.free(mem);
    calloc.free(path);
  }
}

Future<int> _sampleWindowsGpu() async {
  const script = r"""
$ErrorActionPreference='Stop'
$samples=Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine |
  Where-Object Name -Match 'engtype_3D'
if($samples) {
  $engines=$samples | Group-Object { $_.Name -replace '^pid_\d+_','' }
  ($engines | ForEach-Object { ($_.Group | Measure-Object UtilizationPercentage -Sum).Sum } |
    Measure-Object -Maximum).Maximum
}
""";
  final result = await _run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
  ]);
  return result.exitCode == 0
      ? _percent(num.tryParse((result.stdout as String).trim()))
      : 255;
}
