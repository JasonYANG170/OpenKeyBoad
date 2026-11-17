import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'media_features.dart';
import 'models.dart';
import 'palette.dart';
import 'serial_work.dart';
import 'online_models.dart';

class FeaturesPanel extends StatefulWidget {
  const FeaturesPanel({
    super.key,
    required this.board,
    this.autoStart = false,
    required this.palette,
    required this.device,
    required this.service,
    required this.locked,
    required this.isLocked,
    required this.onLock,
  });
  final Board board;
  final bool autoStart;
  final PaletteModel palette;
  final DeviceRef? device;
  final KeyboardService? service;
  final bool locked;
  final bool Function() isLocked;
  final ValueChanged<bool> onLock;

  @override
  State<FeaturesPanel> createState() => FeaturesPanelState();
}

class FeaturesPanelState extends State<FeaturesPanel> {
  Timer? _monitorTimer, _weatherTimer, _effectTimer, _systemPoll, _systemScreen;
  Timer? _onlineTimer, _audioTimer;
  final _pomodoro = Pomodoro();
  final _envelope = AudioEnvelope();
  Json _network = {};
  bool _networkBusy = false, _audioBusy = false;
  int _musicMode = 0, _musicGeneration = 0;
  String _audioStatus = '选择律动方式后，跟随系统正在播放的声音。';
  List<int>? _lastAudioPacket;
  DateTime? _lastAudioSent;
  bool _online = false;
  int _onlineGeneration = 0;
  bool _followSystem = false, _polling = false, _weatherBusy = false;
  int _mediaGeneration = 0, _minor = 0;
  Json _systemTrack = {};
  List<LyricLine> _systemLyrics = [];
  String _lyricStatus = '启用后自动跟随系统播放器。',
      _weatherStatus = '填写城市后同步到键盘彩屏。',
      _titleSent = '';
  DateTime _mediaSample = DateTime.now();
  String _mediaKey = '';
  late final SerialWork _work;
  final _retryAfter = <String, DateTime>{};
  final _bitmapCache = <int, List<int>>{};
  bool _startingAll = false, _systemStarting = false, _monitorPolling = false;
  int _monitorGeneration = 0;
  String _monitorStatus = '连接后自动同步主机资源。';

  Future<void> settleBackground() => _work.activeIdle;
  void resumeBackground() => _work.wake();
  Duration get _systemPosition {
    final base = (_systemTrack['position'] as num? ?? 0).toInt();
    final extra = _systemTrack['playing'] == true
        ? DateTime.now().difference(_mediaSample).inMilliseconds
        : 0;
    final duration = (_systemTrack['duration'] as num? ?? 0).toInt();
    return Duration(
      milliseconds: (base + extra).clamp(0, duration > 0 ? duration : 86400000),
    );
  }

  String _message = '开启在线功能后自动同步系统歌词、天气和监视器。', _city = 'Singapore';
  String _weatherCity = 'Singapore';
  List<int> _metrics = [255, 255, 255, 255];
  CityWeather? _weather;
  List<int> get _palette => widget.palette.colors;
  set _palette(List<int> colors) => widget.palette.replace(colors);
  int _width = 240;
  int get _animation => widget.palette.animation;
  set _animation(int value) => widget.palette.animation = value;
  bool _sending = false, _supported = false;
  DateTime? _lastClock;

  List<KeyPosition> get _keys =>
      widget.board.keys.where((key) => !key.encoder).toList();
  bool get _connected => widget.device != null && widget.service != null;

  @override
  void initState() {
    super.initState();
    _width = widget.board.id == 'ak650' ? 128 : 240;
    _work = SerialWork(blocked: () => widget.isLocked());
    if (widget.autoStart && _connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_startAll());
      });
    }
  }

  @override
  void dispose() {
    _onlineTimer?.cancel();
    _audioTimer?.cancel();
    ++_musicGeneration;
    if (_musicMode != 0) unawaited(_stopHostAudio());
    _work.dispose();
    ++_mediaGeneration;
    ++_monitorGeneration;
    _systemPoll?.cancel();
    _systemScreen?.cancel();
    _monitorTimer?.cancel();
    _weatherTimer?.cancel();
    _effectTimer?.cancel();
    super.dispose();
  }

  Future<T?> _operation<T>(Future<T> Function() action) async {
    if (_sending || widget.isLocked()) return null;
    setState(() => _sending = true);
    widget.onLock(true);
    try {
      return await _work.foreground<T?>(() async {
        if (!mounted) return null;
        return action();
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        widget.onLock(false);
        _work.wake();
      }
    }
  }

  Future<bool> _background(
    String source,
    Future<void> Function() action,
  ) async {
    if (!mounted || !_connected) return false;
    final onlineSource = const {
      'connect',
      'monitor',
      'lyrics',
      'system-enable',
      'weather',
      'network',
      'pomodoro',
      'audio',
    }.contains(source);
    final epoch = _onlineGeneration;
    if (onlineSource && !_online) return false;
    final retry = _retryAfter[source];
    if (retry != null && DateTime.now().isBefore(retry)) return false;
    try {
      final result = await _work.background(source, () async {
        if (!mounted ||
            (onlineSource && (!_online || epoch != _onlineGeneration))) {
          return false;
        }
        await action();
        return true;
      });
      if (result == true) _retryAfter.remove(source);
      return result == true;
    } catch (error) {
      _retryAfter[source] = DateTime.now().add(const Duration(seconds: 10));
      final message = error.toString().replaceFirst('Bad state: ', '');
      if (mounted) {
        setState(() {
          if (source == 'monitor') {
            _monitorStatus = '监控暂未同步，稍后重试：$message';
          } else if (source == 'lyrics' || source == 'system-enable') {
            _lyricStatus = '歌词暂未同步，稍后重试：$message';
          } else if (source == 'weather') {
            _weatherStatus = '同步失败：$message';
          } else {
            _message = message;
          }
        });
      }
      return false;
    }
  }

  Future<void> _setOnline(bool value) async {
    if (value) {
      await _startAll();
      return;
    }
    final stoppedAt = ++_onlineGeneration;
    ++_mediaGeneration;
    ++_monitorGeneration;
    ++_musicGeneration;
    _onlineTimer?.cancel();
    _onlineTimer = null;
    _audioTimer?.cancel();
    _audioTimer = null;
    _pomodoro.pause();
    if (_musicMode != 0) unawaited(_stopHostAudio());
    _systemPoll?.cancel();
    _systemScreen?.cancel();
    _monitorTimer?.cancel();
    _weatherTimer?.cancel();
    _systemPoll = null;
    _systemScreen = null;
    _monitorTimer = null;
    _weatherTimer = null;
    setState(() {
      _online = false;
      _startingAll = false;
      _followSystem = false;
      _systemStarting = false;
      _weatherBusy = false;
      _lyricStatus = '在线功能已关闭。';
      _monitorStatus = '在线功能已关闭。';
      _weatherStatus = '在线功能已关闭。';
    });
    await _work.activeIdle;
    if (mounted &&
        !_online &&
        stoppedAt == _onlineGeneration &&
        _connected &&
        _supported &&
        _minor >= 4) {
      await _operation(
        () => _send([
          _pomodoro.packet,
          if (_musicMode != 0) [7, 0x51, 2, 0, 255],
        ]),
      );
    }
  }

  Future<void> _startAll() async {
    if (_online || !_connected) return;
    final epoch = ++_onlineGeneration;
    _weatherCity = _city.trim();
    setState(() => _online = true);
    setState(() => _startingAll = true);
    _retryAfter.clear();
    try {
      final ready = await _background('connect', () async {
        await _send([
          [8, 0x51, 0],
        ]);
      });
      if (!mounted || !_online || epoch != _onlineGeneration) return;
      if (!ready) {
        setState(() {
          _online = false;
          _message = '无法连接键盘在线协议，请重新开启重试。';
        });
        return;
      }
      await Future.wait([_toggleMonitor(), _toggleSystem(), _weatherUpdate()]);
      if (!mounted || !_online || epoch != _onlineGeneration) return;
      _onlineTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_pomodoro.tick()) {
          setState(() => _message = '番茄钟本轮完成，可以开始下一轮。');
        }
        if (_pomodoro.running || _pomodoro.done) setState(() {});
        unawaited(_networkUpdate());
        unawaited(_syncPomodoro());
      });
      unawaited(_networkUpdate());
      unawaited(_syncPomodoro());
      if (_musicMode != 0) unawaited(_changeMusic(_musicMode));
    } finally {
      if (mounted && epoch == _onlineGeneration) {
        setState(() => _startingAll = false);
      }
    }
  }

  Future<void> _showPage(int page) => _operation(() async {
    if (!_supported) {
      await _send([
        [8, 0x51, 0],
      ]);
    }
    if (page > 3 && _minor < 4) throw StateError('新页面需要刷入本版随附的键盘固件。');
    await _send([
      [7, 0x51, 8, page],
    ]);
  });

  Future<List<List<int>>> _send(List<List<int>> packets) async {
    final device = widget.device, service = widget.service;
    if (device == null || service == null) throw StateError('请先连接键盘。');
    if (!_supported) {
      final result = await service.companion(device, [
        [8, 0x51, 0],
      ]);
      final caps = result.single;
      if (caps.length != 32 ||
          caps[3] != 1 ||
          caps[4] != 0x7f ||
          caps[7] != _keys.length) {
        throw StateError('需要刷入随本版上位机提供的对应型号固件。');
      }
      _width = caps[5];
      _minor = caps[9];
      _supported = true;
    }
    final outgoing = packets.where((p) {
      if (p[0] != 7 || (p[2] != 5 && p[2] != 11)) return true;
      final key = (p[2] << 16) | (p[3] << 8) | p[4];
      final previous = _bitmapCache[key];
      return previous == null ||
          previous.length != p.length ||
          !List.generate(
            p.length,
            (i) => p[i] == previous[i],
          ).every((same) => same);
    }).toList();
    if (outgoing.isEmpty) return [];
    try {
      final replies = await service.companion(device, outgoing);
      if (replies.length != outgoing.length) throw StateError('键盘返回的数据不完整。');
      for (var i = 0; i < replies.length; i++) {
        if (replies[i].length != 32 ||
            replies[i][0] != outgoing[i][0] ||
            replies[i][1] != 0x51 ||
            replies[i][2] != outgoing[i][2]) {
          throw StateError('键盘未接受屏幕指令，请更新对应型号的固件。');
        }
        final p = outgoing[i];
        if (p[0] == 7 && (p[2] == 5 || p[2] == 11)) {
          _bitmapCache[(p[2] << 16) | (p[3] << 8) | p[4]] = List.of(p);
        }
      }
      return replies;
    } catch (_) {
      _supported = false;
      _bitmapCache.clear();
      _titleSent = '';
      rethrow;
    }
  }

  Future<void> _clock() async {
    final now = DateTime.now();
    if (now.year < 2000 || now.year > 2099) {
      throw StateError('主机日期超出键盘 RTC 的范围。');
    }
    final replies = await _send([
      [
        7,
        0x51,
        7,
        now.year - 2000,
        now.month,
        now.day,
        now.weekday % 7,
        now.hour,
        now.minute,
        now.second,
      ],
    ]);
    if (mounted) {
      setState(
        () => _message = replies.single[10] == 1
            ? '已校准键盘时间并保存到 RTC。'
            : '已更新运行时间，RTC 保存失败，请检查硬件。',
      );
    }
    _lastClock = now;
  }

  Future<void> _monitor() async {
    final service = widget.service;
    if (service == null ||
        !_connected ||
        _monitorPolling ||
        _monitorTimer == null) {
      return;
    }
    _monitorPolling = true;
    final generation = _monitorGeneration;
    try {
      // Sampling is independent of USB writes and may take longer than a lyric frame.
      final values = await service.metrics();
      if (!mounted ||
          generation != _monitorGeneration ||
          _monitorTimer == null) {
        return;
      }
      final sent = await _background('monitor', () async {
        if (generation != _monitorGeneration || _monitorTimer == null) return;
        await _send([
          [7, 0x51, 3, ...values],
        ]);
        if (_online &&
            generation == _monitorGeneration &&
            (_lastClock == null ||
                DateTime.now().difference(_lastClock!).inHours >= 1)) {
          await _clock();
        }
      });
      if (mounted && sent && generation == _monitorGeneration) {
        setState(() {
          _metrics = values;
          _monitorStatus = '监控同步中 · 每 3 秒更新';
        });
      }
    } catch (error) {
      if (mounted && _online && generation == _monitorGeneration) {
        setState(() => _monitorStatus = '监控采样失败，将自动重试。');
      }
    } finally {
      _monitorPolling = false;
    }
  }

  Future<void> _toggleMonitor() async {
    ++_monitorGeneration;
    if (_monitorTimer != null) {
      setState(() {
        _monitorTimer?.cancel();
        _monitorTimer = null;
        _monitorStatus = '已停止监控同步。';
      });
      return;
    }
    setState(() {
      _monitorStatus = '正在读取主机资源…';
      _monitorTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _monitor(),
      );
    });
    await _monitor();
  }

  Future<void> _weatherUpdate() async {
    if (_weatherBusy || !_connected || !_online) return;
    final epoch = _onlineGeneration;
    final city = _weatherCity;
    setState(() {
      _weatherBusy = true;
      _weatherStatus = '正在获取天气…';
    });
    try {
      // Use the desktop network/proxy, including when this UI runs on a phone.
      final value = CityWeather.fromJson(await widget.service!.weather(city));
      if (!mounted ||
          !_online ||
          epoch != _onlineGeneration ||
          city != _weatherCity) {
        return;
      }
      final applied = await _background('weather', () async {
        if (city != _weatherCity) return;
        await _send([value.packet, if (_minor >= 4) value.detailsPacket]);
        if (_minor >= 2) {
          final state = (await _send([
            [8, 0x51, 10],
          ])).single;
          final t = (value.temperature * 10).round();
          if (state[3] != (t >> 8 & 255) ||
              state[4] != (t & 255) ||
              state[5] != value.humidity ||
              state[6] != value.code ||
              state[7] != 1) {
            throw StateError('天气写入后校验失败，请重试。');
          }
        }
      });
      if (!mounted ||
          !_online ||
          epoch != _onlineGeneration ||
          city != _weatherCity) {
        return;
      }
      if (applied != true) {
        return;
      }
      setState(() {
        _weather = value;
        _weatherStatus = '已同步到键盘 · ${TimeOfDay.now().format(context)}';
      });
      _weatherTimer ??= Timer.periodic(
        const Duration(minutes: 15),
        (_) => _weatherUpdate(),
      );
    } catch (error) {
      if (mounted && _online && epoch == _onlineGeneration) {
        setState(
          () => _weatherStatus =
              '同步失败：${error.toString().replaceFirst('Bad state: ', '')}',
        );
      }
    } finally {
      if (mounted && _connected && _online && epoch == _onlineGeneration) {
        _weatherTimer ??= Timer.periodic(
          const Duration(minutes: 15),
          (_) => _weatherUpdate(),
        );
      }
      if (mounted && epoch == _onlineGeneration) {
        setState(() => _weatherBusy = false);
        if (_online && city != _weatherCity) unawaited(_weatherUpdate());
      }
    }
  }

  Future<void> _toggleSystem() async {
    final epoch = _onlineGeneration;
    if (!_online) return;
    if (_followSystem) {
      _systemPoll?.cancel();
      _systemScreen?.cancel();
      ++_mediaGeneration;
      setState(() {
        _followSystem = false;
        _lyricStatus = '已停止跟随系统。';
      });
      return;
    }
    if (_systemStarting) return;
    setState(() => _systemStarting = true);
    final ready = await _background('system-enable', () async {
      await _send([
        [8, 0x51, 0],
      ]);
    });
    if (mounted && epoch == _onlineGeneration) {
      setState(() => _systemStarting = false);
    }
    if (ready != true || !mounted || !_online || epoch != _onlineGeneration) {
      return;
    }
    setState(() {
      _followSystem = true;
      _mediaKey = '';
      _titleSent = '';
      _lyricStatus = '正在读取系统播放器…';
    });
    _systemPoll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollSystem(),
    );
    _systemScreen = Timer.periodic(
      const Duration(milliseconds: 650),
      (_) => _background('lyrics', _systemTick),
    );
    await _pollSystem();
  }

  Future<void> _pollSystem() async {
    if (_polling || !_followSystem || !_connected || !_online) return;
    final epoch = _onlineGeneration;
    _polling = true;
    try {
      final track = await widget.service!.nowPlaying();
      if (!mounted ||
          !_followSystem ||
          !_online ||
          epoch != _onlineGeneration) {
        return;
      }
      final title = track['title'] as String? ?? '';
      final key = title.isEmpty
          ? ''
          : jsonEncode([
              title,
              track['artist'],
              track['album'],
              track['duration'],
            ]);
      final changed = key != _mediaKey;
      setState(() {
        _systemTrack = track;
        _mediaSample = DateTime.now();
      });
      if (changed || key.isEmpty) {
        final generation = ++_mediaGeneration;
        _mediaKey = key;
        _systemLyrics = [];
        _titleSent = '';
        setState(
          () =>
              _lyricStatus = key.isEmpty ? '等待系统播放器提供曲名和播放进度。' : '正在自动匹配同步歌词…',
        );
        if (key.isNotEmpty) unawaited(_lookupSystemLyrics(track, generation));
      }
    } catch (error) {
      if (mounted && _online && epoch == _onlineGeneration) {
        _systemPoll?.cancel();
        _systemScreen?.cancel();
        setState(() {
          _followSystem = false;
          _lyricStatus = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _lookupSystemLyrics(Json track, int generation) async {
    try {
      final lyrics = await widget.service!.lyrics(track);
      if (!mounted || !_followSystem || generation != _mediaGeneration) return;
      setState(() {
        _systemLyrics = parseLrc(lyrics['lrc'] as String? ?? '');
        _lyricStatus = (lyrics['status'] as String)
            .replaceAll('，可手动导入 LRC。', '。')
            .replaceAll('，请手动导入 LRC。', '。');
      });
    } catch (error) {
      if (mounted && _followSystem && generation == _mediaGeneration) {
        setState(() => _lyricStatus = '歌词匹配暂时失败，切歌后自动重试。');
      }
    }
  }

  Future<void> _systemTick() async {
    if (!_followSystem) return;
    final generation = _mediaGeneration;
    final position = _systemPosition;
    final line = lyricAt(_systemLyrics, position);
    final title = _systemTrack['title'] as String? ?? '';
    final artist = _systemTrack['artist'] as String? ?? '';
    final label = title.isEmpty
        ? '等待系统音乐'
        : title + (artist.isEmpty ? '' : ' · $artist');
    final duration = (_systemTrack['duration'] as num? ?? 0).toInt();
    final packets = <List<int>>[];
    if (_minor >= 2 && label != _titleSent) {
      packets.addAll(
        await _raster(label, 0, op: 11, height: 12, font: 10, commit: false),
      );
    }
    final caption =
        line?.text ??
        (title.isEmpty
            ? '请播放音乐'
            : _systemLyrics.isEmpty
            ? '暂无同步歌词'
            : '♫');
    packets.addAll(
      await _raster(
        caption,
        line == null ? 0 : (position - line.time).inMilliseconds,
        playing: _systemTrack['playing'] == true,
        progress: duration > 0
            ? (position.inMilliseconds * 1000 ~/ duration).clamp(0, 1000)
            : 0,
      ),
    );
    if (!mounted || !_followSystem || generation != _mediaGeneration) return;
    await _send(packets);
    _titleSent = label;
  }

  Future<void> _networkUpdate() async {
    if (_networkBusy || !_online || !_connected) return;
    _networkBusy = true;
    final epoch = _onlineGeneration;
    try {
      final value = await widget.service!.hostNetwork();
      if (!mounted || !_online || epoch != _onlineGeneration) return;
      if (_minor >= 4) {
        await _background('network', () => _send([networkPacket(value)]));
      }
      if (mounted && _online && epoch == _onlineGeneration) {
        setState(() => _network = value);
      }
    } catch (_) {
      if (mounted && _online && epoch == _onlineGeneration) {
        setState(() => _network = {'supported': false});
      }
    } finally {
      _networkBusy = false;
    }
  }

  Future<void> _syncPomodoro() async {
    if (!_online || _minor < 4) return;
    await _background('pomodoro', () => _send([_pomodoro.packet]));
  }

  void _startAudio() {
    if (!mounted) return;
    _audioTimer?.cancel();
    _audioTimer = null;
    if (!_online || _musicMode == 0) return;
    if (_minor < 4) {
      setState(() => _audioStatus = '系统律动需要刷入本版随附的键盘固件。');
      return;
    }
    _audioTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _audioUpdate(),
    );
    unawaited(_audioUpdate());
  }

  Future<void> _changeMusic(int mode) async {
    final generation = ++_musicGeneration;
    _audioTimer?.cancel();
    _audioTimer = null;
    setState(() {
      _musicMode = mode;
      _lastAudioPacket = null;
    });
    if (mode == 0) {
      await _stopHostAudio();
      if (_online && _minor >= 4 && generation == _musicGeneration) {
        await _background(
          'audio',
          () => _send([
            [7, 0x51, 2, 0, 255],
          ]),
        );
      }
      return;
    }
    if (_online && _minor >= 4) {
      _effectTimer?.cancel();
      _effectTimer = null;
      final epoch = _onlineGeneration;
      await _background('audio', () => _send(_palettePackets()));
      if (!mounted ||
          !_online ||
          generation != _musicGeneration ||
          epoch != _onlineGeneration) {
        return;
      }
    }
    _startAudio();
  }

  Future<void> _audioUpdate() async {
    if (_audioBusy || !_online || _musicMode == 0) return;
    _audioBusy = true;
    final epoch = _onlineGeneration, generation = _musicGeneration;
    try {
      final frame = await widget.service!.systemAudio(true);
      if (!mounted ||
          !_online ||
          epoch != _onlineGeneration ||
          generation != _musicGeneration) {
        return;
      }
      _envelope.update(frame);
      final status = frame['supported'] != true || frame['ready'] != true
          ? frame['status'] as String? ?? '正在启动系统声音采集…'
          : '系统声音采集中 · 8 段频谱 · 静音自动衰减';
      setState(() => _audioStatus = status);
      final packet = [
        7,
        0x51,
        15,
        _musicMode,
        (_envelope.level * 255).round(),
        for (final n in _envelope.bands) (n * 255).round(),
      ];
      final changed =
          _lastAudioPacket == null ||
          List.generate(
            packet.length,
            (i) => (packet[i] - _lastAudioPacket![i]).abs(),
          ).any((d) => d >= 3);
      final heartbeat =
          _lastAudioSent == null ||
          DateTime.now().difference(_lastAudioSent!).inMilliseconds >= 750;
      if ((changed || heartbeat) && frame['supported'] == true) {
        await _background('audio', () async {
          if (generation != _musicGeneration) return;
          await _send([packet]);
          _lastAudioPacket = packet;
          _lastAudioSent = DateTime.now();
        });
      }
    } catch (_) {
      if (mounted &&
          _online &&
          epoch == _onlineGeneration &&
          generation == _musicGeneration) {
        setState(() => _audioStatus = '系统声音采集暂时不可用，稍后自动重试。');
      }
    } finally {
      _audioBusy = false;
    }
  }

  Future<void> _stopHostAudio() async {
    try {
      await widget.service?.systemAudio(false);
    } catch (_) {
      /* The lease stops a disconnected bridge worker. */
    }
  }

  List<List<int>> _palettePackets([List<int>? colors]) {
    final values = colors ?? _palette;
    return [
      for (var start = 0; start < values.length; start += 8)
        [
          7,
          0x51,
          1,
          start,
          min(8, values.length - start),
          for (var i = start; i < min(start + 8, values.length); i++) ...[
            (values[i] >> 16) & 255,
            (values[i] >> 8) & 255,
            values[i] & 255,
          ],
        ],
    ];
  }

  Future<void> applyPalette() => _setCustom(true);
  Future<void> restoreLighting() => _setCustom(false);
  Future<void> paletteFile(bool save) => _patternFile(save);
  Future<void> animatePalette() => _animate();

  Future<void> _setCustom(bool enable) async {
    if (_musicMode != 0) await _changeMusic(0);
    await _operation(() async {
      _effectTimer?.cancel();
      _effectTimer = null;
      await _send([
        if (enable) ..._palettePackets(),
        [7, 0x51, 2, enable ? 1 : 0, 255],
      ]);
      if (mounted) {
        setState(() {
          _message = enable ? '已应用逐键配色。请在 RGB 页面启用灯光并调节亮度。' : '已恢复固件灯效。';
        });
      }
    });
  }

  Future<void> _animate() async {
    if (_musicMode != 0) await _changeMusic(0);
    if (_effectTimer != null) {
      await _setCustom(true);
      return;
    }
    await _operation(() async {
      if (_animation == 0) _animation = 1;
      await _send([
        [7, 0x51, 2, 2, 255],
      ]);
      final start = DateTime.now();
      _effectTimer = Timer.periodic(
        const Duration(milliseconds: 140),
        (_) => _background('effect', () async {
          final seconds =
              DateTime.now().difference(start).inMilliseconds / 1000;
          final colors = List.generate(_palette.length, (i) {
            final pulse = (sin(seconds * 3 + _keys[i].x * 0.6) + 1) / 2;
            final c = _palette[i];
            return _animation == 2
                ? HSVColor.fromAHSV(
                        1,
                        (seconds * 60 + _keys[i].x * 18) % 360,
                        0.9,
                        1,
                      ).toColor().toARGB32() &
                      0xffffff
                : (((c >> 16 & 255) * pulse).round() << 16) |
                      (((c >> 8 & 255) * pulse).round() << 8) |
                      ((c & 255) * pulse).round();
          });
          await _send([
            ..._palettePackets(colors),
            [7, 0x51, 2, 2, 255],
          ]);
        }),
      );
      if (mounted) setState(() => _message = '正在播放自定义动态灯效。');
    });
  }

  Future<List<List<int>>> _raster(
    String text,
    int elapsed, {
    int op = 5,
    int height = 20,
    double font = 16,
    bool commit = true,
    bool? playing,
    int? progress,
  }) async {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Console SC',
          fontSize: font,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(Colors.black, BlendMode.src);
    final overflow = max(0.0, painter.width - _width + 4);
    final scroll = min(overflow, max(0.0, (elapsed - 1000) / 50));
    painter.paint(canvas, Offset(2 - scroll, 0));
    final picture = recorder.endRecording();
    final bitmap = await picture.toImage(_width, height);
    final rgba = (await bitmap.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final bits = Uint8List(_width * height ~/ 8);
    for (var i = 0; i < _width * height; i++) {
      if (rgba.getUint8(i * 4) > 90) bits[i ~/ 8] |= 0x80 >> (i % 8);
    }
    bitmap.dispose();
    picture.dispose();
    painter.dispose();
    return [
      for (var offset = 0; offset < bits.length; offset += 26)
        [
          7,
          0x51,
          op,
          offset >> 8,
          offset & 255,
          min(26, bits.length - offset),
          ...bits.sublist(offset, min(offset + 26, bits.length)),
        ],
      if (commit)
        [
          7,
          0x51,
          6,
          if (_minor >= 2) ...[
            (playing ?? false) ? 1 : 0,
            ((progress ?? 0) >> 8) & 255,
            (progress ?? 0) & 255,
          ],
        ],
    ];
  }

  Future<void> _patternFile(bool save) async {
    await _operation(() async {
      if (save) {
        await FilePicker.platform.saveFile(
          fileName: '${widget.board.id}-lighting.json',
          type: FileType.custom,
          allowedExtensions: ['json'],
          bytes: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'format': 1,
                'model': widget.board.id,
                'colors': _palette,
                'animation': _animation,
              }),
            ),
          ),
        );
      } else {
        final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['json'],
          withData: true,
        );
        final file = picked?.files.single;
        if (file == null) return;
        if (file.size > 65536 || file.bytes == null) {
          throw const FormatException('配色文件无效。');
        }
        final data = jsonDecode(utf8.decode(file.bytes!)) as Json;
        final colors = data['colors'];
        if (data['format'] != 1 ||
            data['model'] != widget.board.id ||
            colors is! List ||
            colors.length != _keys.length) {
          throw const FormatException('配色的型号或按键数量不匹配。');
        }
        final palette = colors
            .map((c) => bounded(c, 0xffffff, 'colors'))
            .toList();
        final animation = bounded(data['animation'], 2, 'animation');
        setState(() {
          _palette = palette;
          _animation = animation;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_sending && !widget.locked;
    final live = enabled && _connected;
    final position = _systemPosition;
    final duration = (_systemTrack['duration'] as num? ?? 0).toInt();
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: EdgeInsets.zero,
      title: const Text(
        '在线功能',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('在线功能开关'),
          subtitle: Text(
            _online
                ? (_startingAll ? '正在连接在线服务…' : '歌词、天气、资源和网速正在后台同步')
                : '开启后同步在线内容，关闭后全部停止并暂停番茄钟',
          ),
          value: _online,
          onChanged: live ? (value) => unawaited(_setOnline(value)) : null,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _card(
              '实时网速',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _rateLine(
                    Icons.south_rounded,
                    '下载',
                    byteRate(
                      _network['supported'] == true && _network['ready'] == true
                          ? _network['download'] as num?
                          : null,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _rateLine(
                    Icons.north_rounded,
                    '上传',
                    byteRate(
                      _network['supported'] == true && _network['ready'] == true
                          ? _network['upload'] as num?
                          : null,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _network['supported'] == true
                        ? '物理网卡合计 · 每秒更新'
                        : '在线后读取桌面主机网速',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: live ? () => _showPage(4) : null,
                    icon: const Icon(Icons.network_check),
                    label: const Text('显示网速'),
                  ),
                ],
              ),
            ),
            _pomodoroCard(live),
            _card(
              '系统音乐律动',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.graphic_eq, size: 42),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    key: const ValueKey('system-audio-mode'),
                    initialValue: _musicMode,
                    decoration: const InputDecoration(labelText: '律动方式'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('关闭律动')),
                      DropdownMenuItem(value: 1, child: Text('逐键配色随音量')),
                      DropdownMenuItem(value: 2, child: Text('八段频谱')),
                      DropdownMenuItem(value: 3, child: Text('彩虹律动')),
                    ],
                    onChanged: live
                        ? (mode) => unawaited(_changeMusic(mode ?? 0))
                        : null,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 50,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final level in _envelope.bands)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Container(
                                height: 4 + level * 46,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(_audioStatus, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  const Text(
                    '读取系统输出声音，不保存录音。Windows / Linux 支持；手机可通过桌面端连接。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            _card(
              '系统歌词',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lyrics_outlined),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _systemTrack['title'] as String? ?? '等待系统播放器',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  if ((_systemTrack['artist'] as String? ?? '').isNotEmpty)
                    Text(_systemTrack['artist'] as String),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: duration > 0
                        ? (position.inMilliseconds / duration).clamp(0, 1)
                        : 0,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    lyricAt(_systemLyrics, position)?.text ??
                        '播放系统音乐后自动匹配同步歌词。',
                  ),
                  const SizedBox(height: 8),
                  Text(_lyricStatus, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: live ? () => _showPage(3) : null,
                    icon: const Icon(Icons.lyrics_outlined),
                    label: const Text('显示歌词'),
                  ),
                ],
              ),
            ),
            _card(
              '主机监视器',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < 4; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 72,
                            child: Text(['CPU', '内存', 'GPU', '系统盘'][i]),
                          ),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: _metrics[i] > 100 ? 0 : _metrics[i] / 100,
                            ),
                          ),
                          SizedBox(
                            width: 45,
                            child: Text(
                              _metrics[i] > 100 ? ' --' : ' ${_metrics[i]}%',
                            ),
                          ),
                        ],
                      ),
                    ),
                  Text(_monitorStatus, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  const Text(
                    '系统盘显示空间占用率，GPU 不可读时显示 --。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: live ? () => _showPage(1) : null,
                    icon: const Icon(Icons.monitor_heart_outlined),
                    label: const Text('显示监视器'),
                  ),
                ],
              ),
            ),
            _card(
              '天气',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    initialValue: _city,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: '城市',
                      helperText: '输入城市后按回车更新',
                    ),
                    onChanged: (value) => _city = value,
                    onFieldSubmitted: (_) {
                      _weatherCity = _city.trim();
                      if (_online) unawaited(_weatherUpdate());
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_weather != null) ...[
                    Icon(
                      _weather!.code == 0
                          ? Icons.wb_sunny_outlined
                          : _weather!.code < 50
                          ? Icons.cloud_outlined
                          : Icons.umbrella_outlined,
                      size: 40,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${_weather!.temperature.toStringAsFixed(1)} °C',
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(_weather!.name),
                    const SizedBox(height: 12),
                    Text(
                      '今日 ${_weather!.minimum?.toStringAsFixed(0) ?? "--"}° / ${_weather!.maximum?.toStringAsFixed(0) ?? "--"}° · 湿度 ${_weather!.humidity}%',
                    ),
                    Text(
                      '降雨 ${_weather!.rain == null ? "--" : "${_weather!.rain}%"} · UV ${_weather!.uv?.toStringAsFixed(1) ?? "--"}',
                    ),
                    Text(
                      'AQI ${_weather!.aqi ?? "--"} · PM2.5 ${_weather!.pm25?.toStringAsFixed(1) ?? "--"} μg/m³',
                    ),
                    const Text(
                      'AQI 采用美国标准；空气质量不可用时显示 --。',
                      style: TextStyle(fontSize: 11),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(_weatherStatus, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  const Text(
                    'Open-Meteo · 在线时每 15 分钟更新',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: live ? () => _showPage(2) : null,
                    icon: const Icon(Icons.cloud_outlined),
                    label: const Text('显示天气'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(_message, style: const TextStyle(fontSize: 12)),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _rateLine(IconData icon, String label, String value) => Row(
    children: [
      Icon(icon, color: Theme.of(context).colorScheme.primary, size: 28),
      const SizedBox(width: 10),
      Expanded(child: Text(label)),
      Text(
        value,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
      ),
    ],
  );

  Widget _pomodoroCard(bool live) => _card(
    '番茄钟',
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: SizedBox(
            width: 132,
            height: 132,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value:
                        1 -
                        _pomodoro.remaining.inMilliseconds /
                            _pomodoro.total.inMilliseconds,
                    strokeWidth: 7,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer_outlined),
                    Text(
                      _pomodoro.clock,
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(_pomodoro.label),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '已完成 ${_pomodoro.completed} 轮 · 每 4 轮长休息',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _durationPicker(
                '专注',
                _pomodoro.focusMinutes,
                [1, 15, 25, 45, 60],
                live && !_pomodoro.running,
                (v) => _pomodoro.configure(
                  v,
                  _pomodoro.breakMinutes,
                  _pomodoro.longBreakMinutes,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _durationPicker(
                '短休',
                _pomodoro.breakMinutes,
                [1, 3, 5, 10],
                live && !_pomodoro.running,
                (v) => _pomodoro.configure(
                  _pomodoro.focusMinutes,
                  v,
                  _pomodoro.longBreakMinutes,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _durationPicker(
                '长休',
                _pomodoro.longBreakMinutes,
                [5, 10, 15, 20, 30],
                live && !_pomodoro.running,
                (v) => _pomodoro.configure(
                  _pomodoro.focusMinutes,
                  _pomodoro.breakMinutes,
                  v,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: live && _online
              ? () {
                  setState(() {
                    if (_pomodoro.running) {
                      _pomodoro.pause();
                    } else {
                      _pomodoro.start();
                    }
                  });
                  unawaited(_syncPomodoro());
                }
              : null,
          icon: Icon(_pomodoro.running ? Icons.pause : Icons.play_arrow),
          label: Text(
            _pomodoro.running
                ? '暂停'
                : _pomodoro.done
                ? '开始下一轮'
                : '开始 / 继续',
          ),
        ),
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: live
                    ? () {
                        setState(_pomodoro.reset);
                        unawaited(_syncPomodoro());
                      }
                    : null,
                child: const Text('重置本轮'),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: live ? () => _showPage(5) : null,
                child: const Text('显示番茄钟'),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _durationPicker(
    String label,
    int value,
    List<int> options,
    bool enabled,
    ValueChanged<int> change,
  ) => DropdownButtonFormField<int>(
    key: ValueKey('$label$value'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final n in options)
        DropdownMenuItem(
          value: n,
          child: Text('$n 分', style: const TextStyle(fontSize: 12)),
        ),
    ],
    onChanged: enabled
        ? (n) {
            if (n != null) {
              setState(() => change(n));
              unawaited(_syncPomodoro());
            }
          }
        : null,
  );

  Widget _card(String title, Widget child) => SizedBox(
    width: 310,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    ),
  );
}
