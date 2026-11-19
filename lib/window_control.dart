import 'package:flutter/foundation.dart';

import 'app_settings.dart';

class WindowControl extends ChangeNotifier {
  bool get available => false;
  bool get trayReady => false;
  String get status =>
      kIsWeb ? '网页窗口由浏览器管理。持续后台同步请使用桌面客户端。' : '手机后台运行由系统管理，离开应用后不能保证持续同步。';
  Future<void> Function()? beforeExit;
  Future<void> initialize(AppSettings settings) async {}
  Future<void> minimize() async {}
  Future<void> hide() async {}
  Future<void> show() async {}
  Future<void> quit() async {}
}
