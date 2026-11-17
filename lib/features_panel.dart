import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'media_features.dart';
import 'models.dart';
import 'palette.dart';

class FeaturesPanel extends StatefulWidget {
  const FeaturesPanel({
    super.key,
    required this.board,
    required this.palette,
    required this.device,
    required this.service,
    required this.locked,
    required this.isLocked,
    required this.onLock,
  });
  final Board board;
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
  AudioPlayer? _audio;
  AudioPlayer get _player {
    final current = _audio;
    if (current != null) return current;
    final value = AudioPlayer();
    _audio = value;
    _positionSubscription = value.onPositionChanged.listen((position) {
      _position = position;
    });
    _playSubscription = value.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _playing = state == PlayerState.playing);
    });
    return value;
  }

  Timer? _monitorTimer,
      _musicTimer,
      _weatherTimer,
      _effectTimer,
      _systemPoll,
      _systemScreen;
  bool _followSystem = false, _polling = false, _weatherBusy = false;
  int _mediaGeneration = 0, _minor = 0;
  Json _systemTrack = {};
  List<LyricLine> _systemLyrics = [];
  String _lyricStatus = '启用后自动跟随系统播放器。',
      _weatherStatus = '填写城市后同步到键盘彩屏。',
      _titleSent = '';
  DateTime _mediaSample = DateTime.now();
  String _mediaKey = '';
  bool _showSystemPage = false;
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

  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playSubscription;
  Duration _position = Duration.zero;
  WaveTrack? _wave;
  String _track = '', _message = '连接新版固件后可启用屏幕和逐键灯光功能。', _city = 'Singapore';
  List<LyricLine> _lyrics = [];
  List<int> _metrics = [255, 255, 255, 255];
  CityWeather? _weather;
  List<int> get _palette => widget.palette.colors;
  set _palette(List<int> colors) => widget.palette.replace(colors);
  int _width = 240;
  int get _animation => widget.palette.animation;
  set _animation(int value) => widget.palette.animation = value;
  bool _sending = false, _supported = false, _playing = false;
  DateTime? _lastRaster, _lastClock;
  bool _custom = false;

  List<KeyPosition> get _keys =>
      widget.board.keys.where((key) => !key.encoder).toList();
  bool get _connected => widget.device != null && widget.service != null;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _systemPoll?.cancel();
    _systemScreen?.cancel();
    _monitorTimer?.cancel();
    _musicTimer?.cancel();
    _weatherTimer?.cancel();
    _effectTimer?.cancel();
    _positionSubscription?.cancel();
    _playSubscription?.cancel();
    _audio?.dispose();
    super.dispose();
  }

  Future<T?> _operation<T>(Future<T> Function() action) async {
    if (_sending || widget.isLocked()) return null;
    setState(() => _sending = true);
    widget.onLock(true);
    try {
      return await action();
    } catch (error) {
      _audio?.pause().catchError((Object _) {});
      _monitorTimer?.cancel();
      _musicTimer?.cancel();
      _weatherTimer?.cancel();
      _effectTimer?.cancel();
      _monitorTimer = null;
      _musicTimer = null;
      _weatherTimer = null;
      _effectTimer = null;
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
      }
    }
  }

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
    final replies = await service.companion(device, packets);
    if (replies.length != packets.length) throw StateError('键盘返回的数据不完整。');
    for (var i = 0; i < replies.length; i++) {
      if (replies[i].length != 32 ||
          replies[i][0] != packets[i][0] ||
          replies[i][1] != 0x51 ||
          replies[i][2] != packets[i][2]) {
        throw StateError('键盘未接受屏幕指令，请更新对应型号的固件。');
      }
    }
    return replies;
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
    if (service == null) return;
    final values = await service.metrics();
    await _send([
      [7, 0x51, 3, ...values],
    ]);
    if (_lastClock == null ||
        DateTime.now().difference(_lastClock!).inHours >= 1) {
      await _clock();
    }
    if (mounted) setState(() => _metrics = values);
  }

  Future<void> _toggleMonitor() async {
    if (_monitorTimer != null) {
      setState(() {
        _monitorTimer?.cancel();
        _monitorTimer = null;
        _message = '已停止监控同步。';
      });
      return;
    }
    await _operation(() async {
      await _monitor();
      await _send([
        [7, 0x51, 8, 1],
      ]);
      _monitorTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _operation(_monitor),
      );
      if (mounted) setState(() => _message = '正在同步主机 CPU、内存、GPU 和系统盘空间占用率。');
    });
  }

  Future<void> _weatherUpdate({bool show = false}) async {
    if (_weatherBusy || !_connected) return;
    setState(() {
      _weatherBusy = true;
      _weatherStatus = '正在获取天气…';
    });
    try {
      // Use the desktop network/proxy, including when this UI runs on a phone.
      final value = CityWeather.fromJson(
        await widget.service!.weather(_city.trim()),
      );
      if (!mounted) return;
      final applied = await _operation(() async {
        await _send([
          value.packet,
          if (show) [7, 0x51, 8, 2],
        ]);
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
        return true;
      });
      if (!mounted) return;
      if (applied != true) {
        throw StateError(
          _message.contains('正在') ? '键盘正在处理其他操作，请重试。' : _message,
        );
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
      if (mounted) {
        setState(
          () => _weatherStatus =
              '同步失败：${error.toString().replaceFirst('Bad state: ', '')}',
        );
      }
    } finally {
      if (mounted) setState(() => _weatherBusy = false);
    }
  }

  Future<void> _toggleSystem() async {
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
    final ready = await _operation(() async {
      await _send([
        [8, 0x51, 0],
        [7, 0x51, 8, 3],
      ]);
      await _audio?.pause();
      _musicTimer?.cancel();
      _musicTimer = null;
      return true;
    });
    if (ready != true || !mounted) return;
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
      (_) => _operation(_systemTick),
    );
    await _pollSystem();
  }

  Future<void> _pollSystem() async {
    if (_polling || !_followSystem) return;
    _polling = true;
    try {
      final track = await widget.service!.nowPlaying();
      if (!mounted || !_followSystem) return;
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
        _showSystemPage = changed && key.isNotEmpty;
        setState(
          () =>
              _lyricStatus = key.isEmpty ? '等待系统播放器提供曲名和播放进度。' : '正在自动匹配同步歌词…',
        );
        if (key.isNotEmpty) unawaited(_lookupSystemLyrics(track, generation));
      }
    } catch (error) {
      if (mounted) {
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
        _lyricStatus = lyrics['status'] as String;
      });
    } catch (error) {
      if (mounted && _followSystem && generation == _mediaGeneration) {
        setState(() => _lyricStatus = '歌词匹配失败，可导入 LRC。');
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
    if (_showSystemPage) packets.add([7, 0x51, 8, 3]);
    await _send(packets);
    _titleSent = label;
    _showSystemPage = false;
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
    await _operation(() async {
      _effectTimer?.cancel();
      _effectTimer = null;
      await _send([
        if (enable) ..._palettePackets(),
        [7, 0x51, 2, enable ? 1 : 0, 255],
      ]);
      if (mounted) {
        setState(() {
          _custom = enable;
          _message = enable ? '已应用逐键配色。请在 RGB 页面启用灯光并调节亮度。' : '已恢复固件灯效。';
        });
      }
    });
  }

  Future<void> _openAudio() async {
    await _operation(() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wav'],
        withData: true,
      );
      final file = result?.files.single;
      if (file == null) return;
      if (file.size > 120 * 1024 * 1024 || file.bytes == null) {
        throw StateError('音频超过 120 MiB 或无法读取。');
      }
      final wave = WaveTrack.parse(file.bytes!);
      await _player.stop();
      if (mounted) {
        setState(() {
          _wave = wave;
          _track = file.name;
          _titleSent = '';
          _position = Duration.zero;
          _message = '已载入 PCM WAV，可播放并同步音乐律动。';
        });
      }
    });
  }

  Future<void> _openLyrics() async {
    await _operation(() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['lrc'],
        withData: true,
      );
      final file = result?.files.single;
      if (file == null) return;
      if (file.size > 1024 * 1024 || file.bytes == null) {
        throw const FormatException('歌词文件过大。');
      }
      final lines = parseLrc(utf8.decode(file.bytes!));
      if (lines.isEmpty) throw const FormatException('未找到有效的 LRC 时间戳。');
      setState(() {
        _lyrics = lines;
        if (_followSystem) _systemLyrics = lines;
        _message = '已载入 ${lines.length} 行同步歌词。';
      });
    });
  }

  Future<void> _play() async {
    if (_followSystem) {
      _systemPoll?.cancel();
      _systemScreen?.cancel();
      ++_mediaGeneration;
      setState(() => _followSystem = false);
    }
    await _operation(() async {
      _effectTimer?.cancel();
      _effectTimer = null;
      if (_playing) {
        await _player.pause();
        _musicTimer?.cancel();
        _musicTimer = null;
        if (_connected) {
          await _send([
            if (_custom) ..._palettePackets(),
            [7, 0x51, 2, _custom ? 1 : 0, 255],
          ]);
        }
        return;
      }
      final wave = _wave;
      if (wave == null) throw StateError('请先载入 PCM WAV 音乐。');
      // Start from the user gesture before the USB round trip, including on Safari.
      if (_position == Duration.zero) {
        await _player.play(BytesSource(wave.bytes, mimeType: 'audio/wav'));
      } else {
        await _player.resume();
      }
      if (_connected) {
        await _send([
          ..._palettePackets(),
          [7, 0x51, 2, 2, 0],
          if (_lyrics.isNotEmpty) [7, 0x51, 8, 3],
        ]);
      }
      _musicTimer = Timer.periodic(
        const Duration(milliseconds: 125),
        (_) => _operation(_musicTick),
      );
    });
  }

  Future<void> _musicTick() async {
    if (!_connected) {
      if (mounted) setState(() {});
      if (!_playing) {
        _musicTimer?.cancel();
        _musicTimer = null;
        _position = Duration.zero;
      }
      return;
    }
    final level = _wave?.intensity(_position) ?? 0;
    final packets = <List<int>>[
      [7, 0x51, 2, 2, _playing ? level : 0],
    ];
    if (_animation > 0) {
      final phase = _position.inMilliseconds / 1000;
      final colors = List.generate(_palette.length, (i) {
        final position = _keys[i];
        final pulse = _animation == 1
            ? (sin(phase * 3 + position.x * 0.6) + 1) / 2
            : 1.0;
        final base = _palette[i];
        if (_animation == 2) {
          return HSVColor.fromAHSV(
                1,
                (phase * 60 + position.x * 18) % 360,
                0.9,
                1,
              ).toColor().toARGB32() &
              0xffffff;
        }
        return (((base >> 16 & 255) * pulse).round() << 16) |
            (((base >> 8 & 255) * pulse).round() << 8) |
            ((base & 255) * pulse).round();
      });
      packets.insertAll(0, _palettePackets(colors));
    }
    if (_minor >= 2 && _titleSent != _track) {
      packets.addAll(
        await _raster(_track, 0, op: 11, height: 12, font: 10, commit: false),
      );
    }
    final lyric = lyricAt(_lyrics, _position);
    if (lyric != null &&
        (_lastRaster == null ||
            DateTime.now().difference(_lastRaster!).inMilliseconds >= 600)) {
      packets.addAll(
        await _raster(lyric.text, (_position - lyric.time).inMilliseconds),
      );
      _lastRaster = DateTime.now();
    }
    await _send(packets);
    _titleSent = _track;
    if (mounted) setState(() {});
    if (!_playing) {
      _musicTimer?.cancel();
      _musicTimer = null;
      _position = Duration.zero;
      await _send([
        if (_custom) ..._palettePackets(),
        [7, 0x51, 2, _custom ? 1 : 0, 255],
      ]);
    }
  }

  Future<void> _animate() async {
    if (_effectTimer != null) {
      await _setCustom(true);
      return;
    }
    await _operation(() async {
      if (_playing) await _player.pause();
      _musicTimer?.cancel();
      _musicTimer = null;
      if (_animation == 0) _animation = 1;
      await _send([
        [7, 0x51, 2, 2, 255],
      ]);
      final start = DateTime.now();
      _effectTimer = Timer.periodic(
        const Duration(milliseconds: 140),
        (_) => _operation(() async {
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
            (playing ?? _playing) ? 1 : 0,
            ((progress ??
                        (_wave == null
                            ? 0
                            : (_position.inMilliseconds / _wave!.seconds)
                                  .round()
                                  .clamp(0, 1000))) >>
                    8) &
                255,
            (progress ??
                    (_wave == null
                        ? 0
                        : (_position.inMilliseconds / _wave!.seconds)
                              .round()
                              .clamp(0, 1000))) &
                255,
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
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: EdgeInsets.zero,
      title: const Text(
        '音乐与屏幕同步',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _card(
              '音乐律动与字幕',
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lyrics_outlined),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _followSystem
                              ? (_systemTrack['title'] as String? ?? '系统播放器')
                              : '系统音乐歌词',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: live ? _toggleSystem : null,
                    icon: Icon(_followSystem ? Icons.stop : Icons.sync),
                    label: Text(_followSystem ? '停止跟随系统' : '跟随系统音乐'),
                  ),
                  const SizedBox(height: 8),
                  Text(_lyricStatus, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  const Text(
                    '曲名、歌手和进度由系统播放器提供；匹配成功后，歌词自动显示在键盘彩屏。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const Divider(height: 24),
                  Text(
                    _track.isEmpty ? '载入 PCM WAV 音乐与 UTF-8 LRC 歌词。' : _track,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: enabled ? _openAudio : null,
                        child: const Text('选择 WAV'),
                      ),
                      OutlinedButton(
                        onPressed: enabled ? _openLyrics : null,
                        child: const Text('选择 LRC'),
                      ),
                      FilledButton(
                        onPressed: enabled && _wave != null ? _play : null,
                        child: Text(_playing ? '暂停' : '播放'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _animation,
                    decoration: const InputDecoration(labelText: '自定义律动效果'),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('逐键配色随音量跳动')),
                      DropdownMenuItem(value: 1, child: Text('波浪叠加')),
                      DropdownMenuItem(value: 2, child: Text('彩虹流动')),
                    ],
                    onChanged: enabled
                        ? (value) => setState(() => _animation = value ?? 0)
                        : null,
                  ),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _wave == null
                        ? 0
                        : (_position.inMilliseconds / 1000 / _wave!.seconds)
                              .clamp(0, 1),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    (_followSystem
                                ? lyricAt(_systemLyrics, _systemPosition)
                                : lyricAt(_lyrics, _position))
                            ?.text ??
                        '歌词随歌曲播放位置同步。',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '音乐律动随本应用播放的 WAV 音频运行。保持应用与键盘连接。',
                    style: TextStyle(fontSize: 12),
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
                  FilledButton(
                    onPressed: live ? _toggleMonitor : null,
                    child: Text(_monitorTimer == null ? '启用监视器' : '停止监视器'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '系统盘显示空间占用率。GPU 取可读计数器，不可用时显示 --。局域网连接显示桌面主机的数据。',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton(
                    onPressed: live ? () => _operation(_clock) : null,
                    child: const Text('校准键盘时间'),
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
                    decoration: const InputDecoration(labelText: '城市'),
                    onChanged: (value) => _city = value,
                  ),
                  const SizedBox(height: 12),
                  if (_weather != null)
                    Text(
                      '${_weather!.name}\n${_weather!.temperature} °C · 湿度 ${_weather!.humidity}%',
                    ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: live && !_weatherBusy
                        ? () => _weatherUpdate(show: true)
                        : null,
                    icon: _weatherBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_sync_outlined),
                    label: Text(_weatherBusy ? '正在同步…' : '同步天气到屏幕'),
                  ),
                  const SizedBox(height: 8),
                  Text(_weatherStatus, style: const TextStyle(fontSize: 12)),
                  if (_weatherTimer != null)
                    TextButton(
                      onPressed: enabled
                          ? () => setState(() {
                              _weatherTimer?.cancel();
                              _weatherTimer = null;
                            })
                          : null,
                      child: const Text('停止自动更新'),
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Open-Meteo · 每 15 分钟更新，免费接口用于非商业用途。',
                    style: TextStyle(fontSize: 12),
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
