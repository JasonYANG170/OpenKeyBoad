import 'package:web/web.dart';

import 'bridge_client.dart';
import 'models.dart';

KeyboardService? localService(List<Board> boards) {
  final base = Uri.base;
  return base.fragment.length >= 32
      ? BridgeService.fromLink(base.toString(), boards)
      : null;
}

bool openBridgeLink(String link) {
  window.location.assign(link.trim());
  return true;
}
