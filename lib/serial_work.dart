import 'dart:async';
import 'dart:collection';

/// Serializes device work without tying periodic transfers to UI loading state.
/// Each background source keeps only its latest pending update.
class SerialWork {
  SerialWork({bool Function()? blocked}) : _blocked = blocked ?? (() => false);
  final bool Function() _blocked;
  final _foreground = Queue<_Work>();
  final _background = <String, _Work>{};
  Completer<void>? _active;
  Timer? _retry;
  bool _draining = false, _disposed = false;

  Future<void> get activeIdle => _active?.future ?? Future.value();

  Future<T?> foreground<T>(Future<T> Function() action) {
    final work = _Work<T>(action);
    if (_disposed) return Future.value();
    _foreground.add(work);
    wake();
    return work.done.future;
  }

  Future<T?> background<T>(String source, Future<T> Function() action) {
    final work = _Work<T>(action);
    if (_disposed) return Future.value();
    _background.remove(source)?.cancel();
    _background[source] = work;
    wake();
    return work.done.future;
  }

  void wake() {
    _retry?.cancel();
    _retry = null;
    if (!_draining && !_disposed) unawaited(_drain());
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (!_disposed && (_foreground.isNotEmpty || _background.isNotEmpty)) {
        if (_foreground.isEmpty && _blocked()) {
          _retry = Timer(const Duration(milliseconds: 25), wake);
          break;
        }
        final work = _foreground.isNotEmpty
            ? _foreground.removeFirst()
            : _background.remove(_background.keys.first)!;
        final active = Completer<void>();
        _active = active;
        await work.execute();
        _active = null;
        active.complete();
      }
    } finally {
      _draining = false;
    }
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    for (final work in [..._foreground, ..._background.values]) {
      work.cancel();
    }
    _foreground.clear();
    _background.clear();
  }
}

class _Work<T> {
  _Work(this.action);
  final Future<T> Function() action;
  final done = Completer<T?>();
  Future<void> execute() async {
    try {
      done.complete(await action());
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  }

  void cancel() => done.complete(null);
}
