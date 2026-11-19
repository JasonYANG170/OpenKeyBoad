import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart' as wm;
import 'package:tray_manager/tray_manager.dart' as tray;

import 'app_settings.dart';
import 'window_control.dart';

WindowControl createWindowControl() =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux
    ? DesktopWindowControl()
    : WindowControl();

class DesktopWindowControl extends WindowControl {
  wm.Window? _window;
  tray.TrayIcon? _tray;
  tray.Menu? _menu;
  final _items = <tray.MenuItem>[];
  AppSettings? _settings;
  bool _quitting = false;
  String? _error;
  @override
  bool get available => _window != null;
  @override
  bool get trayReady => _tray != null;
  @override
  String get status => _error ?? '最小化或收起到托盘后，在线同步继续运行。可从托盘恢复窗口或退出。';
  @override
  Future<void> initialize(AppSettings settings) async {
    _settings = settings;
    try {
      _window = wm.WindowManager.instance.getCurrent();
      final window = _window;
      if (window == null) throw StateError('窗口未就绪');
      window.title = 'OpenKeyBoad';
      window.minimumSize = const Size(320, 480).toNative();
      window.addListener((event) {
        if (event is wm.WindowCloseRequestedEvent && !_quitting) {
          event.request.cancel();
          switch (settings.closeBehavior) {
            case CloseBehavior.exit:
              unawaited(quit());
            case CloseBehavior.minimize:
              unawaited(minimize());
            case CloseBehavior.tray:
              unawaited(hide());
          }
        } else if (event is wm.WindowMinimizedEvent &&
            settings.minimizeToTray &&
            trayReady) {
          window.hide();
        }
      });
      _tray = tray.TrayIcon.create();
      if (_tray == null) throw StateError('系统托盘不可用');
      final icon = tray.ImageAsset.fromAsset('assets/tray.png');
      if (icon == null) throw StateError('托盘图标无法载入');
      _tray!.icon = icon;
      _tray!.setTooltip('OpenKeyBoad · 键盘在线同步');
      _menu = tray.Menu.create();
      if (_menu == null) throw StateError('托盘菜单不可用');
      void item(String label, Future<void> Function() action) {
        final entry = tray.MenuItem.createWithLabelAndType(
          label,
          tray.MenuItemType.normal,
        )!;
        entry.addListener((event) {
          if (event is tray.MenuItemClickedEvent) unawaited(action());
        });
        _items.add(entry);
        _menu!.addItem(entry);
      }

      item('显示控制台', show);
      item('最小化', minimize);
      _menu!.addSeparator();
      item('退出 OpenKeyBoad', quit);
      _tray!.setContextMenu(_menu);
      _tray!.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
      _tray!.addListener((event) {
        if (event is tray.TrayIconClickedEvent ||
            event is tray.TrayIconDoubleClickedEvent) {
          unawaited(show());
        }
      });
      _tray!.setVisible(true);
    } catch (_) {
      _tray?.dispose();
      _tray = null;
      _error = '托盘不可用，将保留任务栏窗口。可正常最小化。';
    }
    notifyListeners();
  }

  @override
  Future<void> minimize() async {
    if (_settings?.minimizeToTray == true && trayReady) {
      await hide();
    } else {
      _window?.minimize();
    }
  }

  @override
  Future<void> hide() async {
    if (trayReady) {
      _window?.hide();
    } else {
      _window?.minimize();
    }
  }

  @override
  Future<void> show() async {
    _window?.restore();
    _window?.show();
    _window?.focus();
  }

  @override
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await beforeExit?.call().timeout(const Duration(seconds: 3));
      await _settings?.flush().timeout(const Duration(seconds: 2));
    } catch (_) {
      // A disconnected keyboard must not prevent an explicit application exit.
    }
    _tray?.dispose();
    _tray = null;
    _window?.close();
    exit(0);
  }
}
