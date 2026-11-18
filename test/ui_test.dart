import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyboard_control/main.dart';
import 'package:keyboard_control/models.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('layouts and RGB controls work at desktop and phone widths', (
    tester,
  ) async {
    final boards = [
      for (final id in ['rs2', 'ak650'])
        Board.fromJson(
          jsonDecode(File('assets/$id.json').readAsStringSync()) as Json,
        ),
    ];
    final codes = (jsonDecode(
      File('assets/keycodes.json').readAsStringSync(),
    ) as Json).cast<String, int>();
    await tester.binding.setSurfaceSize(const Size(1350, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(Console(boards: boards, catalog: codes));
    await tester.pumpAndSettle();
    expect(find.text('JamesDonkey RS2 3.0'), findsOneWidget);
    expect(find.text('离线预览'), findsOneWidget);
    await tester.tap(find.text('AK650'));
    await tester.pumpAndSettle();
    expect(find.text('AJAZZ AK650'), findsOneWidget);
    await tester.tap(find.text('灯光'));
    await tester.pumpAndSettle();
    expect(find.text('RGB 灯光'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(320, 800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
