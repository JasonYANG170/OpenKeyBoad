import 'window_control.dart';
import 'window_runtime_stub.dart'
    if (dart.library.io) 'window_runtime_native.dart'
    as runtime;

WindowControl createWindowControl() => runtime.createWindowControl();
