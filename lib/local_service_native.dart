import 'dart:io';

import 'android_usb.dart';
import 'hid.dart';
import 'models.dart';

KeyboardService? localService(List<Board> boards) {
  if (Platform.isAndroid) return AndroidService(boards);
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    return DesktopService(boards);
  }
  return null;
}

bool openBridgeLink(String link) => false;
