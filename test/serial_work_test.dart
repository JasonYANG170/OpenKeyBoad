import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:keyboard_control/serial_work.dart';

void main() {
  test(
    'Serial device work keeps all streams and prioritizes foreground edits',
    () async {
      final queue = SerialWork();
      final gate = Completer<void>();
      final order = <String>[];
      final a = queue.background('lyrics', () async {
        order.add('lyrics');
        await gate.future;
        return 1;
      });
      final dropped = queue.background('monitor', () async {
        order.add('old monitor');
        return 0;
      });
      final monitor = queue.background('monitor', () async {
        order.add('monitor');
        return 2;
      });
      final weather = queue.background('weather', () async {
        order.add('weather');
        return 3;
      });
      final edit = queue.foreground(() async {
        order.add('edit');
        return 4;
      });
      expect(await dropped, isNull);
      gate.complete();
      await Future.wait([a, monitor, weather, edit]);
      expect(order, ['lyrics', 'edit', 'monitor', 'weather']);
      queue.dispose();
    },
  );
  test('Background pause preserves updates until an external profile operation ends', () async {
    var busy = true;
    final queue = SerialWork(blocked: () => busy);
    var ran = false;
    final pending = queue.background('monitor', () async {
      ran = true;
    });
    await queue.activeIdle;
    expect(ran, isFalse);
    busy = false;
    queue.wake();
    await pending;
    expect(ran, isTrue);
    queue.dispose();
  });
  test('One failed feed does not cancel the remaining queued feeds', () async {
    final queue = SerialWork();
    final failure = queue.background(
      'lyrics',
      () async => throw StateError('disconnected'),
    );
    final healthy = queue.background('weather', () async => 42);
    await expectLater(failure, throwsStateError);
    expect(await healthy, 42);
    queue.dispose();
  });
  test(
    'Disposing cancels queued updates while the current transaction finishes',
    () async {
      final queue = SerialWork();
      final gate = Completer<int>();
      final current = queue.background('lyrics', () => gate.future);
      final pending = queue.background(
        'weather',
        () async => throw StateError('must not run'),
      );
      queue.dispose();
      expect(await pending, isNull);
      gate.complete(3);
      expect(await current, 3);
    },
  );
}
