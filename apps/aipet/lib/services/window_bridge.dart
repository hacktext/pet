import 'dart:async';
import 'dart:developer' as developer;

import 'package:desktop_multi_window/desktop_multi_window.dart';

import '../domain/library_state.dart';

/// Spec 3.2. Small messages only; clips never cross the channel.
abstract final class BridgeMethods {
  static const getState = 'getState';
  static const adopt = 'adopt';
  static const stateChanged = 'stateChanged';
  static const mainWindowClosing = 'mainWindowClosing';
  static const quit = 'quit';
}

typedef BridgeHandler = Future<Object?> Function(String method, Object? args);

abstract class BridgeTransport {
  Future<Object?> invoke(String method, [Object? args]);
  void setHandler(BridgeHandler? handler);
}

class WindowChannelTransport implements BridgeTransport {
  WindowChannelTransport([this._channel = const WindowMethodChannel('aipet/pet')]);

  final WindowMethodChannel _channel;

  @override
  Future<Object?> invoke(String method, [Object? args]) => _channel.invokeMethod<Object?>(method, args);

  @override
  void setHandler(BridgeHandler? handler) {
    unawaited(_channel.setMethodCallHandler(
        handler == null ? null : (call) => handler(call.method, call.arguments))
        .catchError((Object e) { developer.log('setMethodCallHandler failed: $e', name: 'aipet.bridge'); }));
  }
}

class AdoptError implements Exception {
  const AdoptError(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => 'AdoptError($code: $message)';
}

class BridgeTimeout implements Exception {
  const BridgeTimeout(this.stage);
  final String stage;
  @override
  String toString() => 'BridgeTimeout($stage)';
}

/// Pet-window end. The pet window owns the state; the main window only asks.
class PetWindowBridge {
  PetWindowBridge(
    this._transport, {
    required this.state,
    required this.onAdopt,
    required this.onMainWindowClosing,
    required this.onQuit,
  });

  final BridgeTransport _transport;
  final LibraryState Function() state;

  /// Must push a preparing state right away, finish once the pet is on the
  /// desktop, and throw [AdoptError] on failure.
  final Future<void> Function(String petId) onAdopt;
  final Future<void> Function() onMainWindowClosing;
  final Future<void> Function() onQuit;

  void start() => _transport.setHandler(_handle);

  Future<Object?> _handle(String method, Object? args) async {
    switch (method) {
      case BridgeMethods.getState:
        return state().toJson();
      case BridgeMethods.adopt:
        try {
          final petId = (args! as Map<Object?, Object?>)['petId']! as String;
          try {
            await onAdopt(petId);
            return {'ok': true};
          } on AdoptError catch (e) {
            return {'ok': false, 'code': e.code, 'message': e.message};
          }
        } catch (e) {
          developer.log('adopt(?) failed: $e', name: 'aipet.bridge');
          return {'ok': false, 'code': 'prepare_failed', 'message': '$e'};
        }
      case BridgeMethods.mainWindowClosing:
        await onMainWindowClosing();
        return null;
      case BridgeMethods.quit:
        unawaited(onQuit()); // answer before the process goes away
        return null;
      default:
        return null;
    }
  }

  /// Best effort: the main window may simply not be open.
  Future<void> pushState(LibraryState s) async {
    try {
      await _transport.invoke(BridgeMethods.stateChanged, s.toJson()).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }
}

/// Main-window end.
class MainWindowBridge {
  MainWindowBridge(
    this._transport, {
    this.ackTimeout = const Duration(seconds: 3),
    this.adoptTimeout = const Duration(seconds: 60),
  });

  final BridgeTransport _transport;
  final Duration ackTimeout;
  final Duration adoptTimeout;
  final _states = StreamController<LibraryState>.broadcast();

  Stream<LibraryState> get states => _states.stream;

  void start() => _transport.setHandler((method, args) async {
        if (method == BridgeMethods.stateChanged && !_states.isClosed) {
          _states.add(LibraryState.fromJson(args! as Map<Object?, Object?>));
        }
        return null;
      });

  Future<LibraryState> getState() async {
    try {
      final v = await _transport.invoke(BridgeMethods.getState).timeout(ackTimeout);
      return LibraryState.fromJson(v! as Map<Object?, Object?>);
    } on Exception {
      throw const BridgeTimeout('getState');
    }
  }

  /// Two-step confirmation (spec 3.2): a stateChanged naming [petId] within
  /// [ackTimeout], then the call's own result within [adoptTimeout].
  Future<void> adopt(String petId) async {
    final ack = states.firstWhere((s) => s.preparingPetId == petId || s.currentPetId == petId).timeout(ackTimeout);
    final call = _transport.invoke(BridgeMethods.adopt, {'petId': petId}).timeout(adoptTimeout);
    call.ignore(); // suppress errors if call fails early
    try {
      await ack;
    } on TimeoutException {
      throw const BridgeTimeout('ack');
    } on StateError {
      throw const BridgeTimeout('ack');
    }
    final Object? r;
    try {
      r = await call;
    } on Exception {
      throw const BridgeTimeout('adopt');
    }
    final m = r! as Map<Object?, Object?>;
    if (m['ok'] != true) throw AdoptError(m['code']! as String, (m['message'] as String?) ?? '');
  }

  Future<void> notifyClosing() async {
    try {
      await _transport.invoke(BridgeMethods.mainWindowClosing).timeout(ackTimeout);
    } catch (_) {}
  }

  void quit() => _transport.invoke(BridgeMethods.quit).ignore();

  Future<void> dispose() => _states.close();
}
