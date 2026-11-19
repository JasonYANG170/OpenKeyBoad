import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_settings.dart';
import 'models.dart';
import 'online_card.dart';
import 'updates.dart';
import 'window_control.dart';

Future<void> showApplicationSettings(
  BuildContext context,
  AppSettings settings,
  WindowControl window,
  UpdateCenter updates,
  DeviceRef? device,
) => showDialog<void>(
  context: context,
  builder: (_) => ApplicationSettingsPanel(
    settings: settings,
    window: window,
    updates: updates,
    device: device,
  ),
);

class ApplicationSettingsPanel extends StatefulWidget {
  const ApplicationSettingsPanel({
    super.key,
    required this.settings,
    required this.window,
    required this.updates,
    this.device,
    this.openLink,
  });
  final AppSettings settings;
  final WindowControl window;
  final UpdateCenter updates;
  final DeviceRef? device;
  final Future<bool> Function(Uri)? openLink;
  @override
  State<ApplicationSettingsPanel> createState() =>
      _ApplicationSettingsPanelState();
}

class _ApplicationSettingsPanelState extends State<ApplicationSettingsPanel> {
  String? _download;
  String? _error;
  Future<void> _open(Uri uri) async {
    if (uri.scheme != 'https' || uri.host != 'github.com') return;
    final ok =
        await (widget.openLink?.call(uri) ??
            launchUrl(uri, mode: LaunchMode.externalApplication));
    if (!ok && mounted) setState(() => _error = '无法打开下载链接，请从 GitHub 发布页下载。');
  }

  Widget _scroll(List<Widget> children) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
  Widget _link(String text, Uri uri, IconData icon) => OutlinedButton.icon(
    onPressed: () => _open(uri),
    icon: Icon(icon, size: 18),
    label: Text(text),
  );
  Widget _general() => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      OnlineCard(
        title: '外观与更新',
        child: _scroll([
          DropdownButtonFormField<ThemeMode>(
            key: ValueKey(widget.settings.theme),
            initialValue: widget.settings.theme,
            decoration: const InputDecoration(labelText: '应用主题'),
            isExpanded: true,
            items: const [
              DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
            ],
            onChanged: (value) {
              if (value != null) {
                widget.settings.theme = value;
                unawaited(widget.settings.save());
              }
            },
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('自动检查更新'),
            subtitle: const Text('启动时及每 6 小时检查上位机和键盘固件'),
            value: widget.settings.checkUpdates,
            onChanged: (value) {
              widget.settings.checkUpdates = value;
              unawaited(widget.settings.save());
            },
          ),
          if (widget.settings.storageError != null)
            Text(widget.settings.storageError!),
        ]),
      ),
      OnlineCard(
        title: '窗口与后台',
        child: _scroll([
          if (widget.window.available) ...[
            DropdownButtonFormField<CloseBehavior>(
              key: ValueKey(widget.settings.closeBehavior),
              initialValue: widget.settings.closeBehavior,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '点击关闭按钮时'),
              items: [
                const DropdownMenuItem(
                  value: CloseBehavior.exit,
                  child: Text('退出程序'),
                ),
                const DropdownMenuItem(
                  value: CloseBehavior.minimize,
                  child: Text('最小化，继续运行'),
                ),
                if (widget.window.trayReady)
                  const DropdownMenuItem(
                    value: CloseBehavior.tray,
                    child: Text('收起到系统托盘'),
                  ),
                if (!widget.window.trayReady &&
                    widget.settings.closeBehavior == CloseBehavior.tray)
                  const DropdownMenuItem(
                    value: CloseBehavior.tray,
                    child: Text('托盘不可用，将最小化'),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  widget.settings.closeBehavior = value;
                  unawaited(widget.settings.save());
                }
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('最小化时收起到托盘'),
              value: widget.settings.minimizeToTray,
              onChanged: widget.window.trayReady
                  ? (value) {
                      widget.settings.minimizeToTray = value;
                      unawaited(widget.settings.save());
                    }
                  : null,
            ),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: () => widget.window.minimize(),
                  icon: const Icon(Icons.minimize, size: 18),
                  label: const Text('最小化'),
                ),
                if (widget.window.trayReady)
                  OutlinedButton.icon(
                    onPressed: () => widget.window.hide(),
                    icon: const Icon(Icons.desktop_windows_outlined, size: 18),
                    label: const Text('后台运行'),
                  ),
                TextButton.icon(
                  onPressed: () => widget.window.quit(),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('退出程序'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(widget.window.status),
        ]),
      ),
    ],
  );
  Widget _appUpdate() {
    final u = widget.updates, version = u.appVersion;
    final choices = u.clientDownloads;
    final preferred = switch (defaultTargetPlatform) {
      TargetPlatform.windows => 'OpenKeyBoad-Windows-native-x64.zip',
      TargetPlatform.macOS => 'OpenKeyBoad-macos-x86_64.tar.gz',
      TargetPlatform.linux => 'OpenKeyBoad-linux-x86_64.tar.gz',
      TargetPlatform.android => 'OpenKeyBoad-Android.apk',
      _ => 'OpenKeyBoad-iOS-unsigned.ipa',
    };
    final selected =
        choices.where((a) => a.name == _download).firstOrNull ??
        choices.where((a) => a.name == preferred).firstOrNull ??
        choices.firstOrNull;
    final newer = version == null
        ? null
        : compareVersions(version, consoleVersion);
    return OnlineCard(
      title: '上位机',
      details: _scroll([
        const Text('下载后按系统方式替换或安装客户端。iOS IPA 需要自行签名，macOS 版本未公证。'),
        if (u.appRelease != null) ...[
          const SizedBox(height: 12),
          Text('发布：${u.appRelease!.tag}'),
          if (u.appRelease!.published != null)
            Text('时间：${u.appRelease!.published!.toLocal()}'),
        ],
      ]),
      child: _scroll([
        Text(
          '当前 $consoleVersion',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        Text(
          version == null
              ? '尚未获取已发布版本'
              : newer! > 0
              ? '发现新版本 $version'
              : newer == 0
              ? '已是最新版本'
              : '本地版本高于已发布的 $version',
        ),
        const SizedBox(height: 10),
        if (selected != null) ...[
          DropdownButtonFormField<String>(
            key: ValueKey(selected.name),
            initialValue: selected.name,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '下载客户端',
              isDense: true,
            ),
            items: [
              for (final asset in choices)
                DropdownMenuItem(
                  value: asset.name,
                  child: Text(
                    packageLabel(asset.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _download = v),
          ),
          _link(
            newer != null && newer < 0 ? '下载已发布版本' : '下载更新',
            selected.url,
            Icons.download_outlined,
          ),
        ],
        if (u.appRelease != null)
          _link('GitHub 发布页', u.appRelease!.page, Icons.open_in_new),
        if (u.errors['上位机'] != null) Text(u.errors['上位机']!),
      ]),
    );
  }

  Widget _firmware(String model) {
    final update = widget.updates.firmware[model];
    final d = widget.device?.model == model ? widget.device : null;
    final current = d?.firmwareVersion;
    final newer = current != null && update != null
        ? compareVersions(update.version, current)
        : null;
    return OnlineCard(
      title: model == 'rs2' ? 'RS2 3.0 固件' : 'AK650 固件',
      details: _scroll([
        const Text('仅下载对应型号固件。刷入前先导出键位与宏，保持有线供电并进入 ISP。'),
        if (update != null) ...[
          const SizedBox(height: 12),
          Text('来源：${update.release.repo}'),
          Text('发布：${update.release.tag}'),
          if (update.sha256 != null) ...[
            const SizedBox(height: 10),
            const Text('固件 SHA-256'),
            SelectableText(update.sha256!),
          ],
        ],
      ]),
      child: _scroll([
        Text(
          d == null
              ? '未连接此型号'
              : current == null
              ? '设备未上报版本'
              : '当前 $current',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        if (update == null)
          const Text('尚未获取已发布固件')
        else ...[
          Text(
            newer == null
                ? '最新 ${update.version}'
                : newer > 0
                ? '发现新固件 ${update.version}'
                : newer == 0
                ? '已是最新固件'
                : '设备版本高于已发布的 ${update.version}',
          ),
          const SizedBox(height: 12),
          _link(
            update.download.name.endsWith('.zip') ? '下载固件包' : '下载固件',
            update.download.url,
            Icons.download_outlined,
          ),
          if (update.layout != null)
            _link('VIA 布局', update.layout!.url, Icons.keyboard_outlined),
          _link('发布页', update.release.page, Icons.open_in_new),
        ],
        if (widget.updates.errors[UpdateCenter.firmwareRepos[model]] != null)
          Text(widget.updates.errors[UpdateCenter.firmwareRepos[model]]!),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.settings,
      widget.window,
      widget.updates,
    ]),
    builder: (context, _) => Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: 1000,
        height: max(
          240,
          min(
            MediaQuery.sizeOf(context).width >= 1050 ? 520 : 740,
            MediaQuery.sizeOf(context).height - 32,
          ),
        ),
        child: DefaultTabController(
          length: 2,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '应用设置',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭设置',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: '常规'),
                  Tab(text: '更新'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: _general(),
                    ),
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: widget.updates.checking
                                    ? null
                                    : () => widget.updates.check(
                                        settings: widget.settings,
                                      ),
                                icon: const Icon(Icons.refresh, size: 18),
                                label: Text(
                                  widget.updates.checking ? '检查中…' : '检查全部更新',
                                ),
                              ),
                              Text(
                                widget.updates.checkedAt == null
                                    ? '从 GitHub 稳定版发布检查'
                                    : '上次检查：${widget.updates.checkedAt!.toLocal().toString().substring(0, 16)}',
                              ),
                            ],
                          ),
                          if (widget.updates.checking)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: LinearProgressIndicator(minHeight: 3),
                            ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              _appUpdate(),
                              _firmware('rs2'),
                              _firmware('ak650'),
                            ],
                          ),
                          if (_error != null) Text(_error!),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
