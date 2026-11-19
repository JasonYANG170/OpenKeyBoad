import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

enum CloseBehavior { exit, minimize, tray }

class AppSettings extends ChangeNotifier {
  AppSettings({this.storage});
  final SharedPreferencesAsync? storage;
  ThemeMode theme = ThemeMode.system;
  CloseBehavior closeBehavior = CloseBehavior.minimize;
  bool minimizeToTray = false;
  bool checkUpdates = true;
  DateTime? lastUpdateCheck;
  String? storageError;
  Future<void> _writes = Future.value();
  Future<void> flush() => _writes;

  Future<void> load() async {
    final storage = this.storage;
    if (storage == null) return;
    try {
      theme =
          ThemeMode.values.elementAtOrNull(
            await storage.getInt('app.theme') ?? 0,
          ) ??
          ThemeMode.system;
      closeBehavior =
          CloseBehavior.values.elementAtOrNull(
            await storage.getInt('app.close') ?? 1,
          ) ??
          CloseBehavior.minimize;
      minimizeToTray = await storage.getBool('app.minimizeToTray') ?? false;
      checkUpdates = await storage.getBool('app.checkUpdates') ?? true;
      final last = await storage.getInt('app.lastUpdateCheck');
      lastUpdateCheck = last == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(last);
    } catch (_) {
      storageError = '设置存储不可用，本次修改仅在当前运行期间生效。';
    }
    notifyListeners();
  }

  Future<void> save() {
    notifyListeners();
    final storage = this.storage;
    if (storage == null) return Future.value();
    // Capture a complete snapshot and serialize writes to preserve rapid edits.
    final mode = theme.index,
        close = closeBehavior.index,
        tray = minimizeToTray,
        updates = checkUpdates;
    final checked = lastUpdateCheck?.millisecondsSinceEpoch;
    _writes = _writes.then((_) async {
      try {
        await storage.setInt('app.theme', mode);
        await storage.setInt('app.close', close);
        await storage.setBool('app.minimizeToTray', tray);
        await storage.setBool('app.checkUpdates', updates);
        if (checked != null) {
          await storage.setInt('app.lastUpdateCheck', checked);
        }
        storageError = null;
      } catch (_) {
        storageError = '无法保存设置，本次修改在当前运行期间生效。';
      }
      notifyListeners();
    });
    return _writes;
  }
}
