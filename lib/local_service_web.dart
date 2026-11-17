import 'package:web/web.dart';

import 'bridge_client.dart';
import 'models.dart';

KeyboardService? localService(List<Board> boards) {
  final base = Uri.base;
  const key = 'OpenKeyBoad.bridgeToken';
  String? token = base.fragment.length >= 32 ? base.fragment : null;
  if (token == null) {
    try {
      token = window.sessionStorage.getItem(key);
    } catch (_) {
      /* Storage may be disabled. */
    }
  }
  if (token == null || token.length < 32) return null;
  final service = BridgeService.fromLink(
    base.replace(fragment: token).toString(),
    boards,
  );
  // Flutter's hash router may clear the connection fragment after startup.
  // Keep this temporary credential in this tab, scoped to the bridge origin.
  try {
    window.sessionStorage.setItem(key, token);
  } catch (_) {
    /* The original link still works. */
  }
  return service;
}

bool openBridgeLink(String link) {
  window.location.assign(link.trim());
  return true;
}
