import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'device_settings.dart';
import 'models.dart';
import 'online_card.dart';

class DeviceSettingsPanel extends StatefulWidget {
  const DeviceSettingsPanel({
    super.key,
    required this.board,
    required this.device,
    required this.service,
    required this.busy,
    required this.run,
    required this.beforeDeparture,
  });
  final Board board;
  final DeviceRef? device;
  final KeyboardService? service;
  final bool busy;
  final Future<void> Function(Future<void> Function(), String) run;
  final Future<void> Function() beforeDeparture;
  @override
  State<DeviceSettingsPanel> createState() => _DeviceSettingsPanelState();
}

class _DeviceSettingsPanelState extends State<DeviceSettingsPanel> {
  bool _expanded = false, _working = false;
  DeviceSettings? _settings;
  String _status = '展开后读取键盘设置。';
  DeviceSettingsClient get _client =>
      DeviceSettingsClient(widget.service!, widget.device!);
  bool get _enabled => !_working && !widget.busy && _settings != null;
  bool get _connected => widget.service != null && widget.device != null;

  @override
  void didUpdateWidget(covariant DeviceSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device?.id != widget.device?.id ||
        oldWidget.board.id != widget.board.id ||
        oldWidget.service != widget.service) {
      _settings = null;
      _status = '展开后读取键盘设置。';
      if (_expanded && _connected) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
      }
    }
  }

  Future<void> _operation(
    Future<void> Function() action, {
    bool silent = false,
  }) async {
    if (!_connected || _working || widget.busy) return;
    final id = widget.device!.id;
    setState(() => _working = true);
    await widget.run(() async {
      try {
        await action();
      } on SettingsConflict catch (error) {
        if (mounted && widget.device?.id == id) {
          setState(() {
            _settings = error.current;
            _status = error.message;
          });
        }
      } catch (error) {
        if (mounted && widget.device?.id == id && !silent) {
          setState(
            () => _status = error.toString().replaceFirst('Bad state: ', ''),
          );
        }
      }
    }, silent ? '正在读取键盘状态…' : '正在更新键盘设置…');
    if (mounted) setState(() => _working = false);
  }

  Future<void> _refresh({bool silent = false}) => _operation(() async {
    final current = await _client.read();
    if (mounted) {
      setState(() {
        _settings = current;
        if (!silent) _status = '已读取键盘当前设置。修改后自动写入并验证。';
      });
    }
  }, silent: silent);
  Future<void> _set(SettingField field, int value) => _operation(() async {
    final current = await _client.set(_settings!, field, value);
    if (mounted) {
      setState(() {
        _settings = current;
        _status = '已应用并读回验证。';
      });
    }
  });
  Future<void> _action(DeviceAction action) async {
    if (!_enabled || !_settings!.canRun(action)) return;
    if (action == DeviceAction.isp || action == DeviceAction.reset) {
      final reset = action == DeviceAction.reset;
      final confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(reset ? '恢复键盘出厂设置？' : '进入刷机模式？'),
              content: Text(
                reset ? '这会清除键位、宏和键盘偏好设置并重启。建议先导出配置。' : '键盘将暂时停止输入，等待刷入固件。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('确认'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) return;
      await widget.beforeDeparture();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    await _operation(() async {
      await _client.run(_settings!, action);
      if (mounted) {
        setState(
          () => _status = switch (action) {
            DeviceAction.isp => '键盘已进入刷机模式。',
            DeviceAction.reset => '键盘正在恢复默认设置并重启，请稍后重新连接。',
            DeviceAction.pair => '已开始配对当前无线槽位。',
            _ => '操作已发送。电脑亮度需要操作系统及显示器支持亮度按键。',
          },
        );
      }
      if (action.index < DeviceAction.isp.index) {
        final current = await _client.read();
        if (mounted) setState(() => _settings = current);
      }
    });
  }

  Widget _select(
    String title,
    SettingField field,
    List<String> labels, {
    List<int>? values,
  }) {
    final s = _settings!;
    if (!s.has(field)) return const SizedBox.shrink();
    final choices = values ?? List.generate(labels.length, (i) => i);
    final selected = choices.contains(s[field]) ? s[field] : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<int>(
        key: ValueKey('device-setting-${field.name}-${s[field]}'),
        initialValue: selected,
        isExpanded: true,
        decoration: InputDecoration(labelText: title, isDense: true),
        items: [
          for (var i = 0; i < labels.length; i++)
            DropdownMenuItem(
              value: choices[i],
              child: Text(
                labels[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: _enabled && s.canSet(field)
            ? (v) {
                if (v != null) _set(field, v);
              }
            : null,
      ),
    );
  }

  Widget _toggle(String title, SettingField field) {
    final s = _settings!;
    if (!s.has(field)) return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(child: Text(title)),
        Switch(
          key: ValueKey('device-setting-${field.name}'),
          value: s[field] == 1,
          onChanged: _enabled && s.canSet(field)
              ? (v) => _set(field, v ? 1 : 0)
              : null,
        ),
      ],
    );
  }

  Widget _button(String title, DeviceAction action, IconData icon) =>
      OutlinedButton.icon(
        onPressed: _enabled && _settings!.canRun(action)
            ? () => _action(action)
            : null,
        icon: Icon(icon, size: 18),
        label: Text(title),
      );
  Widget _body(List<Widget> children) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  List<Widget> _cards() {
    final s = _settings!;
    final battery = s[SettingField.battery];
    return [
      OnlineCard(
        title: '屏幕外观',
        details: _body([
          _toggle('屏幕开启', SettingField.screen),
          _select(
            '屏幕背光',
            SettingField.backlight,
            ['20%', '40%', '60%', '80%', '100%'],
            values: [1, 2, 3, 4, 5],
          ),
          _select('无操作后熄屏', SettingField.timeout, [
            '30 秒',
            '1 分钟',
            '3 分钟',
            '5 分钟',
            '10 分钟',
            '常亮',
          ]),
          _toggle('首页自动显示音乐', SettingField.media),
          _button('唤醒屏幕', DeviceAction.wake, Icons.wb_sunny_outlined),
        ]),
        child: _body([
          _select('主题', SettingField.theme, ['深色', '浅色', '暖沙']),
          _select('配色', SettingField.accent, [
            '冰蓝',
            '琥珀',
            '红色',
            '橙色',
            '金黄',
            '青柠',
            '草绿',
            '薄荷',
            '青绿',
            '天蓝',
            '宝蓝',
            '靛蓝',
            '丁香',
            '紫色',
            '玫红',
            '珊瑚',
          ]),
          _select('屏幕语言', SettingField.english, ['简体中文', 'English']),
        ]),
      ),
      OnlineCard(
        title: '按键与旋钮',
        details: _body([
          _toggle('RGB 灯光开启', SettingField.rgbEnabled),
          if (s.has(SettingField.fkeys))
            _select('数字行默认功能', SettingField.fkeys, ['数字优先', 'F1–F12 优先']),
          const Text('电脑屏幕亮度'),
          Wrap(
            spacing: 8,
            children: [
              _button('降低', DeviceAction.dim, Icons.brightness_low),
              _button('提高', DeviceAction.brighten, Icons.brightness_high),
            ],
          ),
          const Text('RGB 的颜色、亮度、速度和效果，以及逐键配色，在上方灯光区域设置。'),
        ]),
        child: _body([
          _select('系统映射', SettingField.mac, ['Windows', 'Mac（交换 Alt / GUI）']),
          _toggle('锁定 Win / GUI 键', SettingField.guiLock),
          _select('旋钮模式', SettingField.encoder, ['音量调节', '屏幕交互']),
        ]),
      ),
      OnlineCard(
        title: '连接与设备',
        details: _body([
          Text(
            widget.board.id == 'rs2'
                ? '有线 / 无线由键盘自锁开关控制。'
                : 'USB / 蓝牙 / 2.4G 由键盘实体拨杆控制。',
          ),
          const SizedBox(height: 12),
          _button('进入刷机模式', DeviceAction.isp, Icons.system_update_alt),
          _button('恢复出厂设置', DeviceAction.reset, Icons.restore),
          const Text('这些操作会中断输入，执行前会再次确认。'),
        ]),
        child: _body([
          Text(
            '${s[SettingField.wired] == 1 ? "有线模式" : "无线模式"} · 电池 ${battery <= 100 ? "$battery%" : "未上报"}',
          ),
          const SizedBox(height: 10),
          _select(
            '无线槽位',
            SettingField.profile,
            widget.board.id == 'rs2' || s[SettingField.profile] == 0
                ? ['2.4G', '蓝牙 1', '蓝牙 2', '蓝牙 3']
                : ['蓝牙 1', '蓝牙 2', '蓝牙 3'],
            values: widget.board.id == 'rs2' || s[SettingField.profile] == 0
                ? [0, 1, 2, 3]
                : [1, 2, 3],
          ),
          _button('配对当前槽位', DeviceAction.pair, Icons.bluetooth_searching),
          Text(
            s[SettingField.wired] == 1
                ? '可预设蓝牙槽位。切换到无线档后可发起配对。'
                : '无线状态：${['空闲', '连接中', '配对中', '已连接', '被拒绝'].elementAtOrNull(s[SettingField.connection]) ?? "未知"}',
          ),
        ]),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: TextButton.icon(
              onPressed: () {
                setState(() => _expanded = !_expanded);
                if (_expanded && _connected) {
                  unawaited(_refresh());
                }
              },
              icon: Icon(
                _expanded ? Icons.expand_less : Icons.settings_outlined,
              ),
              label: const Align(
                alignment: Alignment.centerLeft,
                child: Text('键盘设置'),
              ),
            ),
          ),
          IconButton(
            tooltip: '读取键盘设置',
            onPressed: _connected && !_working && !widget.busy
                ? () {
                    setState(() => _expanded = true);
                    unawaited(_refresh());
                  }
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      if (_expanded) ...[
        const SizedBox(height: 8),
        if (_settings != null)
          Wrap(spacing: 12, runSpacing: 12, children: _cards()),
        const SizedBox(height: 10),
        Text(_connected ? _status : '连接键盘后可以读取并修改设备设置。'),
      ],
    ],
  );
}
