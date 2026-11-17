import 'package:flutter/foundation.dart';

import 'models.dart';

class PaletteModel extends ChangeNotifier {
  PaletteModel(this.board)
    : colors = List.filled(
        board.keys.where((key) => !key.encoder).length,
        0x4dccb0,
      );
  final Board board;
  List<int> colors;
  int selected = 0, animation = 0;
  bool perKey = false;

  int ledAt(int physical) {
    if (board.keys[physical].encoder) return -1;
    return board.keys.take(physical).where((key) => !key.encoder).length;
  }

  int get selectedLed => ledAt(selected);
  int get color => colors[selectedLed];
  void select(int physical) {
    if (ledAt(physical) < 0) return;
    selected = physical;
    notifyListeners();
  }

  void paint(int color) {
    colors[selectedLed] = color;
    notifyListeners();
  }

  void fill() {
    colors = List.filled(colors.length, color);
    notifyListeners();
  }

  void replace(List<int> next) {
    colors = List.of(next);
    notifyListeners();
  }

  void toggle(bool value) {
    perKey = value;
    notifyListeners();
  }
}
