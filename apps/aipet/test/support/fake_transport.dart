import 'dart:async';

import 'package:aipet/services/window_bridge.dart';

/// Two in-memory ends of one channel. Values are copied the way the platform
/// channel copies them (maps arrive as `Map<Object?, Object?>`).
class FakeTransport implements BridgeTransport {
  FakeTransport._();

  late FakeTransport peer;
  BridgeHandler? _handler;

  /// When true, calls arriving at THIS end never get an answer (a hung window).
  bool silent = false;

  /// When set on the end being CALLED (peer), invoke throws it.
  Object? failWith;

  static (FakeTransport, FakeTransport) pair() {
    final a = FakeTransport._();
    final b = FakeTransport._();
    a.peer = b;
    b.peer = a;
    return (a, b);
  }

  @override
  Future<Object?> invoke(String method, [Object? args]) async {
    final h = peer._handler;
    if (h == null) throw StateError('nothing is listening on the other side');
    if (peer.failWith != null) throw peer.failWith!;
    if (peer.silent) return Completer<Object?>().future;
    return _wire(await h(method, _wire(args)));
  }

  @override
  void setHandler(BridgeHandler? handler) => _handler = handler;
}

Object? _wire(Object? v) {
  if (v is Map) return <Object?, Object?>{for (final e in v.entries) e.key: _wire(e.value)};
  if (v is List) return <Object?>[for (final x in v) _wire(x)];
  return v;
}
