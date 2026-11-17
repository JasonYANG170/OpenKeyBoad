import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'bridge_client.dart';
import 'local_service.dart';
import 'models.dart';
import 'palette.dart';
import 'features_panel.dart';
import 'chords.dart';
import 'chord_dialog.dart';

const _paper = Color(0xfff4f5ef);
const _ink = Color(0xff172722);
const _muted = Color(0xff53665e);
const _green = Color(0xff235f48);
const _soft = Color(0xffe6efe7);
const _border = Color(0xffdce4db);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final boards = [
    for (final model in ['rs2', 'ak650'])
      Board.fromJson(
        jsonDecode(await rootBundle.loadString('assets/$model.json')) as Json,
      ),
  ];
  final catalog = (jsonDecode(
    await rootBundle.loadString('assets/keycodes.json'),
  ) as Json).cast<String, int>();
  runApp(
    Console(boards: boards, catalog: catalog, service: localService(boards)),
  );
}

class Console extends StatelessWidget {
  const Console({
    super.key,
    required this.boards,
    required this.catalog,
    this.service,
  });
  final List<Board> boards;
  final Map<String, int> catalog;
  final KeyboardService? service;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpenKeyBoad',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Console SC',
      colorScheme: ColorScheme.fromSeed(
        seedColor: _green,
        surface: Colors.white,
        primary: _green,
      ),
      scaffoldBackgroundColor: _paper,
      visualDensity: VisualDensity.standard,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _paper,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: _Workbench(boards, catalog, service),
  );
}

class _Workbench extends StatefulWidget {
  const _Workbench(this.boards, this.catalog, this.service);
  final List<Board> boards;
  final Map<String, int> catalog;
  final KeyboardService? service;

  @override
  State<_Workbench> createState() => _WorkbenchState();
}

class _WorkbenchState extends State<_Workbench> {
  late Board board = widget.boards.first;
  late Profile draft = board.preview();
  late Profile baseline = draft;
  late KeyboardService? service = widget.service;
  late final Map<int, String> preferred = _preferredCodes(widget.catalog);
  List<DeviceRef> devices = [];
  DeviceRef? device;
  bool busy = false;
  int layer = 0;
  int selection = 0;
  bool lightingTab = false;
  late PaletteModel palette = PaletteModel(board);
  GlobalKey<FeaturesPanelState> featureKey = GlobalKey();
  final _paletteHex = TextEditingController(text: '4DCCB0');
  String status = '连接键盘，或预览布局。';
  bool bad = false;

  bool get dirty => baseline.serialized != draft.serialized;

  @override
  void initState() {
    super.initState();
    palette.addListener(_paletteChanged);
    if (widget.service != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
    }
  }

  void _paletteChanged() {
    final color = palette.color.toRadixString(16).padLeft(6, '0').toUpperCase();
    if (_paletteHex.text.toUpperCase() != color) {
      _paletteHex.value = TextEditingValue(
        text: color,
        selection: TextSelection.collapsed(offset: color.length),
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    palette.removeListener(_paletteChanged);
    palette.dispose();
    _paletteHex.dispose();
    super.dispose();
  }

  Future<void> _task(Future<void> Function() action, String label) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = label;
      bad = false;
    });
    try {
      await featureKey.currentState?.settleBackground();
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error.toString().replaceFirst('Bad state: ', '');
          bad = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        featureKey.currentState?.resumeBackground();
      }
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('放弃未应用的改动？'),
            content: const Text('可先导出配置，或返回编辑。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('放弃'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _switchBoard(Board next, Profile profile, DeviceRef? target) {
    if (board.id != next.id || device?.id != target?.id) {
      palette.removeListener(_paletteChanged);
      palette.dispose();
      palette = PaletteModel(next)..addListener(_paletteChanged);
      featureKey = GlobalKey();
    }
    board = next;
    draft = profile;
    baseline = profile;
    device = target;
    layer = 0;
    selection = 0;
  }

  Future<void> _scan() async {
    final current = service;
    if (current == null) {
      await _enterBridge();
      return;
    }
    await _task(() async {
      final found = await current.scan();
      if (!mounted) return;
      final plugged =
          device != null &&
          found.any(
            (item) => item.id == device!.id && item.model == device!.model,
          );
      if (!plugged && found.length == 1 && !dirty) {
        final target = found.single;
        final profile = await current.read(target);
        if (!mounted) return;
        setState(() {
          devices = found;
          _switchBoard(
            widget.boards.firstWhere((item) => item.id == target.model),
            profile,
            target,
          );
          status = '设备配置已读取。';
        });
      } else {
        setState(() {
          devices = found;
          if (!plugged) device = null;
          status = found.isEmpty ? '未发现设备。请用数据线连接并切换到有线模式。' : '请选择要配置的键盘。';
        });
      }
    }, '正在扫描 USB 设备…');
  }

  Future<void> _connect(DeviceRef target) async {
    if (!await _confirmDiscard()) return;
    await _task(() async {
      final profile = await service!.read(target);
      if (!mounted) return;
      setState(() {
        _switchBoard(
          widget.boards.firstWhere((item) => item.id == target.model),
          profile,
          target,
        );
        status = '设备配置已读取。';
      });
    }, '正在读取设备…');
  }

  Future<void> _enterBridge() async {
    var address = '';
    final link = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('连接桌面端'),
        content: SizedBox(
          width: 390,
          child: TextField(
            onChanged: (value) => address = value,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: '桌面端提供的完整连接链接'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, address),
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (!mounted || link == null || !await _confirmDiscard()) return;
    await _task(() async {
      final remote = BridgeService.fromLink(link, widget.boards);
      if (openBridgeLink(link)) return;
      final found = await remote.scan();
      if (!mounted) return;
      setState(() {
        service = remote;
        device = null;
        devices = found;
        status = found.isEmpty ? '已连接桌面端，等待 USB 键盘。' : '请选择要配置的键盘。';
      });
    }, '正在连接桌面端…');
  }

  Future<void> _apply() async {
    final active = device;
    if (active == null || !dirty) return;
    final current = baseline, target = draft;
    await _task(() async {
      final result = await service!.apply(active, current, target);
      if (!mounted) return;
      setState(() {
        baseline = draft = result;
        status = '已写入键盘并读回校验。';
      });
    }, '正在写入并验证键盘配置…');
  }

  Future<void> _import() async {
    await _task(() async {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      final file = picked?.files.single;
      if (!mounted || file == null) return;
      if (file.size > 65536 || file.bytes == null) {
        throw const FormatException('无法读取此配置文件。');
      }
      final profile = Profile.fromJson(
        board,
        jsonDecode(utf8.decode(file.bytes!)) as Json,
      );
      setState(() {
        draft = profile;
        status = '已载入配置，应用后写入键盘。';
      });
    }, '正在选择配置文件…');
  }

  Future<void> _export() async {
    await _task(() async {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: '导出配置',
        fileName: '${board.id}-profile.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: Uint8List.fromList(
          utf8.encode(
            const JsonEncoder.withIndent('  ').convert(draft.toJson()),
          ),
        ),
      );
      if (mounted) {
        setState(() => status = result == null ? '导出操作已结束。' : '配置已导出。');
      }
    }, '正在导出配置…');
  }

  String _code(int value) =>
      board.custom[value] ?? preferred[value] ?? '0x${hex(value)}';

  Future<void> _chooseCode({int? direction}) async {
    final code = direction == null
        ? draft.keys[layer][selection]
        : draft.encoders[layer][direction];
    final choices = {
      ...widget.catalog,
      for (final entry in board.custom.entries) entry.value: entry.key,
    };
    final result = await showDialog<int>(
      context: context,
      builder: (_) => _CodePicker(choices, _code(code)),
    );
    if (result != null && mounted) {
      setState(() {
        draft = draft.withKey(
          layer,
          direction ?? selection,
          result,
          encoder: direction != null,
        );
      });
    }
  }

  Future<void> _chooseChord() async {
    final keys = await showDialog<List<int>>(
      context: context,
      builder: (_) => ChordDialog(catalog: widget.catalog),
    );
    if (keys == null || !mounted) return;
    try {
      final value = assignChord(draft, layer, selection, keys);
      setState(() => draft = value);
    } catch (error) {
      if (mounted) {
        setState(() {
          status = error.toString();
          bad = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 930;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              wide ? 38 : 16,
              18,
              wide ? 38 : 16,
              24,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1440),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(),
                    const SizedBox(height: 24),
                    _devices(),
                    const SizedBox(height: 16),
                    if (busy) const LinearProgressIndicator(minHeight: 3),
                    const SizedBox(height: 6),
                    if (wide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _workspace()),
                          const SizedBox(width: 16),
                          SizedBox(width: 290, child: _inspector()),
                        ],
                      )
                    else ...[
                      _workspace(),
                      const SizedBox(height: 14),
                      _inspector(),
                    ],
                    const SizedBox(height: 16),
                    _footer(),
                    const SizedBox(height: 16),
                    _Panel(
                      child: FeaturesPanel(
                        key: featureKey,
                        palette: palette,
                        board: board,
                        device: device,
                        service: service,
                        locked: busy,
                        isLocked: () => busy,
                        onLock: (value) {
                          if (mounted) setState(() => busy = value);
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _header() => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    runSpacing: 12,
    spacing: 16,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: _green,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.keyboard_outlined, color: Colors.white),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'OpenKeyBoad',
                style: TextStyle(
                  color: _ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 23,
                ),
              ),
              Text(
                'RS2 3.0  /  AK650',
                style: TextStyle(
                  color: _muted,
                  fontSize: 12,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
        ],
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: busy ? null : _enterBridge,
            icon: const Icon(Icons.wifi, size: 18),
            label: const Text('局域网连接'),
          ),
          FilledButton.icon(
            onPressed: busy ? null : _scan,
            icon: const Icon(Icons.usb, size: 18),
            label: const Text('扫描设备'),
          ),
        ],
      ),
    ],
  );

  Widget _devices() => _Panel(
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 8,
      children: [
        const Text(
          '设备',
          style: TextStyle(fontWeight: FontWeight.w700, color: _ink),
        ),
        for (final model in widget.boards)
          ChoiceChip(
            label: Text(model.id == 'rs2' ? 'RS2 3.0' : 'AK650'),
            selected: board.id == model.id,
            onSelected: busy
                ? null
                : (_) async {
                    if (board.id == model.id || !await _confirmDiscard()) {
                      return;
                    }
                    setState(() {
                      _switchBoard(model, model.preview(), null);
                      status = '预览布局。';
                    });
                  },
          ),
        for (final available in devices)
          ActionChip(
            avatar: const Icon(Icons.usb, size: 16),
            label: Text(available.label),
            onPressed: busy || available.id == device?.id
                ? null
                : () => _connect(available),
          ),
        _Pill(device == null ? '离线预览' : 'VIA 已连接', live: device != null),
      ],
    ),
  );

  Widget _workspace() => _Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          runSpacing: 10,
          spacing: 20,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  board.name,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                Text(
                  '${board.keys.length} 个键位  ·  ${board.layers} 层  ·  ${board.usbId}',
                  style: const TextStyle(color: _muted, fontSize: 13),
                ),
              ],
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.grid_view_rounded, size: 16),
                  label: Text('改键'),
                ),
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.light_mode_outlined, size: 16),
                  label: Text('灯光'),
                ),
              ],
              selected: {lightingTab},
              onSelectionChanged: (value) =>
                  setState(() => lightingTab = value.single),
            ),
          ],
        ),
        const SizedBox(height: 17),
        Wrap(
          spacing: 7,
          runSpacing: 6,
          children: [
            for (var i = 0; i < board.layers; i++)
              ChoiceChip(
                label: Text(
                  board.id == 'ak650'
                      ? ['Win', 'Win Fn', 'Mac', 'Mac Fn'][i]
                      : '层 $i',
                ),
                selected: layer == i,
                onSelected: busy ? null : (_) => setState(() => layer = i),
              ),
          ],
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, layout) {
            final width = max(
              layout.maxWidth,
              board.id == 'rs2' ? 660.0 : 565.0,
            );
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _Keyboard(
                board: board,
                codes: draft.keys[layer],
                width: width,
                selected: lightingTab
                    ? (palette.perKey ? palette.selected : -1)
                    : selection,
                codeName: _code,
                disabled: busy || (lightingTab && !palette.perKey),
                colors: lightingTab && palette.perKey
                    ? [
                        for (var i = 0; i < board.keys.length; i++)
                          board.keys[i].encoder
                              ? null
                              : palette.colors[palette.ledAt(i)],
                      ]
                    : null,
                light: lightingTab ? draft.light : null,
                onSelect: (index) {
                  if (lightingTab) {
                    palette.select(index);
                  } else {
                    setState(() => selection = index);
                  }
                },
              ),
            );
          },
        ),
        const SizedBox(height: 14),
        Text(
          lightingTab
              ? palette.perKey
                    ? '点击键盘上的按键设置颜色。旋钮没有可配置的灯位。'
                    : '可切换到逐键配色，直接选择键盘上的按键。'
              : '选择键位后，在编辑面板更换键码。',
          style: const TextStyle(color: _muted, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _inspector() => _Panel(
    child: lightingTab
        ? _lightInspector()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '键位编辑',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                board.keys[selection].encoder
                    ? '旋钮按压'
                    : (board.keys[selection].label ??
                          _short(
                            preferred[board.defaults.first[selection]] ?? '键位',
                          )),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: _green,
                ),
              ),
              Text(
                '矩阵 ${board.keys[selection].row}, ${board.keys[selection].column}',
                style: const TextStyle(color: _muted),
              ),
              const SizedBox(height: 11),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _chooseCode(),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: Text(
                  _code(draft.keys[layer][selection]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(),
              ),
              OutlinedButton.icon(
                onPressed: busy || draft.macros == null ? null : _chooseChord,
                icon: const Icon(Icons.keyboard_command_key, size: 16),
                label: const Text('自定义组合键'),
              ),
              const Text('旋钮转向', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (var i = 0; i < 2; i++)
                ListTile(
                  onTap: busy ? null : () => _chooseCode(direction: i),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    i == 0 ? Icons.rotate_left : Icons.rotate_right,
                    color: _green,
                  ),
                  title: Text(i == 0 ? '逆时针' : '顺时针'),
                  subtitle: Text(
                    _code(draft.encoders[layer][i]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 16),
                ),
            ],
          ),
  );

  Widget _lightInspector() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'RGB 灯光',
        style: TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w800,
          color: _ink,
        ),
      ),
      const SizedBox(height: 12),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('整体灯效')),
          ButtonSegment(value: true, label: Text('逐键配色')),
        ],
        selected: {palette.perKey},
        onSelectionChanged: busy
            ? null
            : (values) => palette.toggle(values.single),
      ),
      const SizedBox(height: 16),
      if (palette.perKey) _paletteEditor() else _lighting(),
    ],
  );

  Widget _paletteEditor() {
    final key = board.keys[palette.selected];
    final label =
        key.label ??
        _short(preferred[board.defaults.first[palette.selected]] ?? '键位');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            color: _green,
          ),
        ),
        Text(
          '矩阵 ${key.row}, ${key.column}',
          style: const TextStyle(color: _muted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final c in [
              0xff5f57,
              0xffbd2e,
              0x28c840,
              0x4dccb0,
              0x409cff,
              0xbf5af2,
              0xffffff,
              0x000000,
            ])
              Tooltip(
                message:
                    '#${c.toRadixString(16).padLeft(6, '0').toUpperCase()}',
                child: InkWell(
                  onTap: busy ? null : () => palette.paint(c),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Color(0xff000000 | c),
                      border: Border.all(color: _border, width: 2),
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _paletteHex,
          maxLength: 6,
          enabled: !busy,
          decoration: const InputDecoration(labelText: '按键颜色', prefixText: '#'),
          onChanged: (value) {
            final c = int.tryParse(value, radix: 16);
            if (value.length == 6 && c != null) palette.paint(c);
          },
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              onPressed: busy ? null : palette.fill,
              child: const Text('填充全部'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => featureKey.currentState?.paletteFile(false),
              child: const Text('导入'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => featureKey.currentState?.paletteFile(true),
              child: const Text('导出'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
          initialValue: palette.animation,
          decoration: const InputDecoration(labelText: '动态灯效'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('静态配色')),
            DropdownMenuItem(value: 1, child: Text('波浪')),
            DropdownMenuItem(value: 2, child: Text('彩虹')),
          ],
          onChanged: busy
              ? null
              : (value) => setState(() => palette.animation = value ?? 0),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: busy || device == null
              ? null
              : () => featureKey.currentState?.applyPalette(),
          child: const Text('应用逐键配色'),
        ),
        OutlinedButton(
          onPressed: busy || device == null
              ? null
              : () => featureKey.currentState?.animatePalette(),
          child: const Text('播放／停止动态灯效'),
        ),
        TextButton(
          onPressed: busy || device == null
              ? null
              : () => featureKey.currentState?.restoreLighting(),
          child: const Text('恢复固件灯效'),
        ),
      ],
    );
  }

  Widget _lighting() {
    final light = draft.light;
    final count = max(light.effect + 1, board.effects.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey('${board.id}:${light.effect}'),
          initialValue: light.effect,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '灯效'),
          items: [
            for (var i = 0; i < count; i++)
              if (i < board.effects.length || i == light.effect)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    i < board.effects.length
                        ? _effect(board.effects[i])
                        : '固件灯效 $i',
                  ),
                ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  if (value != null) _light(light.copyWith(effect: value));
                },
        ),
        const SizedBox(height: 12),
        _slider(
          '亮度',
          light.brightness,
          (v) => _light(light.copyWith(brightness: v)),
        ),
        _slider('速度', light.speed, (v) => _light(light.copyWith(speed: v))),
        _slider(
          '色相',
          light.hue,
          (v) => _light(light.copyWith(hue: v)),
          hue: true,
        ),
        _slider(
          '饱和度',
          light.saturation,
          (v) => _light(light.copyWith(saturation: v)),
        ),
      ],
    );
  }

  void _light(Lighting value) => setState(() => draft = draft.withLight(value));

  Widget _slider(
    String label,
    int value,
    ValueChanged<int> update, {
    bool hue = false,
  }) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: _muted)),
          Text(
            hue
                ? '${(value * 359 / 255).round()}°'
                : '${(value * 100 / 255).round()}%',
            style: const TextStyle(color: _ink, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      Slider(
        value: value.toDouble(),
        max: 255,
        divisions: 255,
        onChanged: busy ? null : (next) => update(next.round()),
      ),
    ],
  );

  Widget _footer() => _Panel(
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      runSpacing: 12,
      spacing: 15,
      children: [
        Text(
          dirty && !bad && !busy ? '有未应用的改动。' : status,
          style: TextStyle(color: bad ? Colors.red.shade800 : _muted),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (device != null)
              TextButton(
                onPressed: busy ? null : () => _connect(device!),
                child: const Text('重新读取'),
              ),
            TextButton.icon(
              onPressed: busy ? null : _import,
              icon: const Icon(Icons.upload_file, size: 17),
              label: const Text('导入'),
            ),
            TextButton.icon(
              onPressed: busy ? null : _export,
              icon: const Icon(Icons.download_outlined, size: 17),
              label: const Text('导出'),
            ),
            FilledButton.icon(
              onPressed: busy || device == null || !dirty ? null : _apply,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('应用到键盘'),
            ),
          ],
        ),
      ],
    ),
  );
}

class _Keyboard extends StatelessWidget {
  const _Keyboard({
    required this.board,
    required this.codes,
    required this.width,
    required this.selected,
    required this.codeName,
    required this.disabled,
    required this.onSelect,
    this.light,
    this.colors,
  });
  final Board board;
  final List<int> codes;
  final double width;
  final int selected;
  final String Function(int) codeName;
  final bool disabled;
  final ValueChanged<int> onSelect;
  final Lighting? light;
  final List<int?>? colors;

  @override
  Widget build(BuildContext context) {
    final columns = board.keys.map((k) => k.x + k.width).reduce(max);
    final rows = board.keys.map((k) => k.y + k.height).reduce(max);
    final unit = min((width - 24) / columns, 61.0);
    final color = light == null
        ? _green
        : HSVColor.fromAHSV(
            1,
            light!.hue * 359 / 255,
            light!.saturation / 255,
            0.92,
          ).toColor();
    return Container(
      width: width,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xffe7ece3),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: _border),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: columns * unit,
          height: rows * unit,
          child: Stack(
            children: [
              for (var i = 0; i < board.keys.length; i++)
                Positioned(
                  left: board.keys[i].x * unit + 2,
                  top: board.keys[i].y * unit + 2,
                  width: board.keys[i].width * unit - 4,
                  height: board.keys[i].height * unit - 4,
                  child: _key(i, color),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _key(int index, Color color) {
    final selectedKey = index == selected;
    final pos = board.keys[index];
    final code = codes[index];
    final blank = code == 1;
    final normalFill = selectedKey
        ? _green
        : light == null || light!.effect == 0
        ? (blank ? const Color(0xffedf1e9) : Colors.white)
        : Color.lerp(Colors.white, color, (light!.brightness / 255) * 0.7)!;
    final led = colors?[index];
    final fill = led == null ? normalFill : Color(0xff000000 | led);
    final foreground = led == null
        ? (selectedKey ? Colors.white : _ink)
        : fill.computeLuminance() > 0.38
        ? _ink
        : Colors.white;
    final label = pos.encoder
        ? '◉'
        : blank
        ? '▽'
        : _short(codeName(code));
    return Tooltip(
      message: pos.encoder ? '旋钮按压 · ${codeName(code)}' : codeName(code),
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(pos.encoder ? 19 : 7),
          side: BorderSide(
            color: selectedKey ? _green : _border,
            width: selectedKey && colors != null ? 3 : 1,
          ),
        ),
        child: InkWell(
          onTap: disabled || (colors != null && pos.encoder)
              ? null
              : () => onSelect(index),
          borderRadius: BorderRadius.circular(7),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: _border),
      borderRadius: BorderRadius.circular(19),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: const EdgeInsets.all(17), child: child),
  );
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {required this.live});
  final String text;
  final bool live;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: live ? _soft : _paper,
      borderRadius: BorderRadius.circular(28),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    child: Text(
      text,
      style: TextStyle(
        color: live ? _green : _muted,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _CodePicker extends StatefulWidget {
  const _CodePicker(this.codes, this.current);
  final Map<String, int> codes;
  final String current;
  @override
  State<_CodePicker> createState() => _CodePickerState();
}

class _CodePickerState extends State<_CodePicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final search = query.trim().toUpperCase();
    final values = widget.codes.entries
        .where((item) => item.key.contains(search))
        .take(65)
        .toList();
    final custom = RegExp(r'^0X[0-9A-F]{1,4}$').hasMatch(search)
        ? int.parse(search.substring(2), radix: 16)
        : null;
    return AlertDialog(
      title: const Text('选择键码'),
      content: SizedBox(
        width: 480,
        height: 355,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              onChanged: (value) => setState(() => query = value),
              onSubmitted: (_) {
                if (custom != null) {
                  Navigator.pop(context, custom);
                } else if (values.length == 1) {
                  Navigator.pop(context, values.single.value);
                }
              },
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '搜索键码，或输入 0x…',
                helperText: '当前 ${widget.current}',
              ),
            ),
            const SizedBox(height: 8),
            if (custom != null)
              ListTile(
                title: Text('使用 0x${hex(custom)}'),
                onTap: () => Navigator.pop(context, custom),
              ),
            Expanded(
              child: values.isEmpty && custom == null
                  ? const Center(child: Text('没有匹配键码。'))
                  : ListView.builder(
                      itemCount: values.length,
                      itemBuilder: (context, index) {
                        final entry = values[index];
                        return ListTile(
                          dense: true,
                          title: Text(entry.key),
                          trailing: Text('0x${hex(entry.value)}'),
                          onTap: () => Navigator.pop(context, entry.value),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

Map<int, String> _preferredCodes(Map<String, int> names) {
  final result = <int, String>{};
  for (final entry in names.entries) {
    final old = result[entry.value];
    if (old == null || entry.key.length < old.length) {
      result[entry.value] = entry.key;
    }
  }
  return result;
}

String _short(String value) {
  const names = {
    'ESC': 'Esc',
    'SPC': 'Space',
    'ENT': 'Enter',
    'BSPC': '⌫',
    'TAB': 'Tab',
    'LSFT': 'Shift',
    'RSFT': 'Shift',
    'LCTL': 'Ctrl',
    'RCTL': 'Ctrl',
    'LGUI': 'Win',
    'LALT': 'Alt',
    'RALT': 'Alt',
    'LEFT': '←',
    'RGHT': '→',
    'UP': '↑',
    'DOWN': '↓',
    'MINS': '−',
    'EQL': '=',
    'LBRC': '[',
    'RBRC': ']',
    'BSLS': '\\',
    'QUOT': "'",
    'SCLN': ';',
    'COMM': ',',
    'SLSH': '/',
    'DOT': '.',
    'GRV': '`',
  };
  final key = value.startsWith('KC_') ? value.substring(3) : value;
  return names[key] ?? (key.startsWith('MO(') ? 'Fn' : key);
}

String _effect(String value) =>
    const {
      'NONE': '关闭',
      'SOLID_COLOR': '常亮',
      'BREATHING': '呼吸',
      'CYCLE_ALL': '循环变色',
      'CYCLE_LEFT_RIGHT': '横向彩虹',
      'CYCLE_UP_DOWN': '纵向彩虹',
      'CYCLE_PINWHEEL': '旋转彩虹',
      'JELLYBEAN_RAINDROPS': '彩色雨滴',
      'TYPING_HEATMAP': '打字热力',
      'BAND_SAT': '色带',
      'RAINBOW_MOVING_CHEVRON': '彩虹箭头',
    }[value] ??
    value;
