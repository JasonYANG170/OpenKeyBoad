import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:keyboard_control/main.dart';
import 'package:keyboard_control/app_settings.dart';
import 'package:keyboard_control/application_settings_panel.dart';
import 'package:keyboard_control/app_theme.dart';
import 'package:keyboard_control/models.dart';
import 'package:keyboard_control/updates.dart';
import 'package:keyboard_control/window_control.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryPreferences implements SharedPreferencesAsync {
  final values = <String, Object>{};
  @override
  Future<int?> getInt(String key) async => values[key] as int?;
  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;
  @override
  Future<void> setInt(String key, int value) async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    values[key] = value;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DesktopWindowFixture extends WindowControl {
  @override
  bool get available => true;
  @override
  bool get trayReady => true;
}

class UpdateCheckFixture extends UpdateCenter {
  int calls = 0;
  @override
  Future<void> check({AppSettings? settings}) async {
    calls++;
    checkedAt = DateTime.now();
  }
}

void main() {
  testWidgets('startup checks updates even after a recent previous session', (
    tester,
  ) async {
    final board = Board.fromJson(
      jsonDecode(File('assets/rs2.json').readAsStringSync()) as Json,
    );
    final settings = AppSettings()..lastUpdateCheck = DateTime.now();
    final updates = UpdateCheckFixture();
    addTearDown(settings.dispose);
    addTearDown(updates.dispose);
    await tester.pumpWidget(
      Console(
        boards: [board],
        catalog: const {},
        settings: settings,
        updates: updates,
      ),
    );
    await tester.pumpAndSettle();
    expect(updates.calls, 1);
  });
  test('invalid saved selections recover to usable defaults', () async {
    final store = MemoryPreferences()
      ..values.addAll({'app.theme': 999, 'app.close': -1});
    final settings = AppSettings(storage: store);
    addTearDown(settings.dispose);
    await settings.load();
    expect(settings.theme, ThemeMode.system);
    expect(settings.closeBehavior, CloseBehavior.minimize);
  });
  test('rapid settings edits persist the latest complete snapshot', () async {
    final store = MemoryPreferences();
    final settings = AppSettings(storage: store);
    addTearDown(settings.dispose);
    settings.theme = ThemeMode.light;
    final first = settings.save();
    settings.theme = ThemeMode.dark;
    settings.minimizeToTray = true;
    final second = settings.save();
    await Future.wait([first, second]);
    await settings.flush();
    final loaded = AppSettings(storage: store);
    addTearDown(loaded.dispose);
    await loaded.load();
    expect(loaded.theme, ThemeMode.dark);
    expect(loaded.minimizeToTray, true);
  });
  testWidgets(
    'system appearance follows changes; manual dark overrides system',
    (tester) async {
      final board = Board.fromJson(
        jsonDecode(File('assets/rs2.json').readAsStringSync()) as Json,
      );
      final prefs = AppSettings()..checkUpdates = false;
      addTearDown(prefs.dispose);
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark;
      addTearDown(
        tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
      );
      await tester.pumpWidget(
        Console(boards: [board], catalog: const {}, settings: prefs),
      );
      await tester.pumpAndSettle();
      BuildContext context() => tester.element(find.byType(Scaffold).first);
      expect(Theme.of(context()).brightness, Brightness.dark);
      expect(AppColors.of(context()).panel, AppColors.dark.panel);
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      await tester.pumpAndSettle();
      expect(Theme.of(context()).brightness, Brightness.light);
      prefs.theme = ThemeMode.dark;
      await prefs.save();
      await tester.pumpAndSettle();
      expect(Theme.of(context()).brightness, Brightness.dark);
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 390.0, 1280.0]) {
    testWidgets('application settings and update cards adapt at $width px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final settings = AppSettings()..theme = ThemeMode.dark;
      final updates = UpdateCenter();
      addTearDown(settings.dispose);
      addTearDown(updates.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: consoleTheme(Brightness.dark),
          home: Scaffold(
            body: ApplicationSettingsPanel(
              settings: settings,
              window: DesktopWindowFixture(),
              updates: updates,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('深色'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('更新'));
      await tester.pumpAndSettle();
      expect(find.text('检查全部更新'), findsOneWidget);
      expect(find.text('RS2 3.0 固件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
