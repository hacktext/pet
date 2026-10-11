import 'dart:async';
import 'dart:developer' as developer;

import 'package:desktop_multi_window/desktop_multi_window.dart';

import '../domain/account_view.dart';
import '../domain/library_state.dart';

/// Spec 3.2. Small messages only; clips never cross the channel.
abstract final class BridgeMethods {
  static const getState = 'getState';
  static const adopt = 'adopt';
  static const stateChanged = 'stateChanged';
  static const mainWindowClosing = 'mainWindowClosing';
  static const quit = 'quit';

  // The account card on 我的 (web platform spec 8): the library asks, the pet
  // window -- the only writer of account.json -- does it and pushes the result.
  static const getAccount = 'getAccount';
  static const sendSms = 'sendSms';
  static const login = 'login';
  static const logout = 'logout';
  static const syncNow = 'syncNow';
  static const accountChanged = 'accountChanged';

  // Delivered custom pets (generation spec 6.1 / 6.2): the pet window tells
  // the library a pet arrived, the library may ask what arrived while it was
  // closed, and may ask the pet window to look for deliveries now.
  static const petsReady = 'petsReady';
  static const takeReady = 'takeReady';
  static const refreshCustom = 'refreshCustom';
}

/// A custom pet that has just been downloaded and installed.
class ReadyPet {
  const ReadyPet({required this.petId, required this.name});

  final String petId;
  final String name;

  Map<String, Object?> toJson() => {'petId': petId, 'name': name};

  static ReadyPet? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['petId'], name = j['name'];
    if (id is! String || name is! String) return null;
    return ReadyPet(petId: id, name: name);
  }

  /// `{pets: [...]}` as it crosses the channel.
  static List<ReadyPet> listFrom(Object? j) {
    final raw = j is Map ? j['pets'] : null;
    return [for (final v in (raw is List ? raw : const [])) ?ReadyPet.fromJson(v)];
  }

  @override
  bool operator ==(Object other) => other is ReadyPet && other.petId == petId && other.name == name;

  @override
  int get hashCode => Object.hash(petId, name);

  @override
  String toString() => 'ReadyPet($petId, $name)';
}

/// What the pet window does for the account card; AccountKeeper in production.
abstract class AccountHandler {
  AccountView get view;
  Future<AccountReply> sendSms(String phone);
  Future<AccountReply> login(String phone, String code);
  Future<void> logout();
  Future<AccountReply> syncNow();
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
    this.account,
    this.onRefreshCustom,
  });

  final BridgeTransport _transport;
  final LibraryState Function() state;

  /// The library asked to look for delivered custom pets now; null ignores it.
  final Future<void> Function()? onRefreshCustom;

  /// Ready pets the library has not received yet (it was not running).
  final _ready = <ReadyPet>[];

  /// Null leaves the library's account card signed out.
  final AccountHandler? account;

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
      case BridgeMethods.getAccount:
        return (account?.view ?? AccountView.signedOut).toJson();
      case BridgeMethods.sendSms || BridgeMethods.login || BridgeMethods.logout || BridgeMethods.syncNow:
        return (await _accountRequest(method, args)).toJson();
      case BridgeMethods.takeReady:
        final out = [for (final p in _ready) p.toJson()];
        _ready.clear();
        return {'pets': out};
      case BridgeMethods.refreshCustom:
        final refresh = onRefreshCustom;
        if (refresh != null) {
          unawaited(refresh().catchError((Object e) {
            developer.log('refreshCustom failed: $e', name: 'aipet.custom');
          }));
        }
        return null;
      default:
        return null;
    }
  }

  Future<AccountReply> _accountRequest(String method, Object? args) async {
    final a = account;
    if (a == null) return const AccountReply(ok: false, message: '暂不可用');
    try {
      final m = (args as Map<Object?, Object?>?) ?? const {};
      switch (method) {
        case BridgeMethods.sendSms:
          return await a.sendSms(m['phone']! as String);
        case BridgeMethods.login:
          return await a.login(m['phone']! as String, m['code']! as String);
        case BridgeMethods.logout:
          await a.logout();
          return const AccountReply(ok: true);
        default:
          return await a.syncNow();
      }
    } catch (e) {
      developer.log('$method failed: $e', name: 'aipet.bridge');
      return const AccountReply(ok: false, message: '操作失败，请重试');
    }
  }

  /// Best effort, like [pushState].
  Future<void> pushAccount(AccountView v) async {
    try {
      await _transport.invoke(BridgeMethods.accountChanged, v.toJson()).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Best effort: the main window may simply not be open.
  Future<void> pushState(LibraryState s) async {
    try {
      await _transport.invoke(BridgeMethods.stateChanged, s.toJson()).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Tells the library [pets] arrived. If it is not there to hear it, they
  /// wait (in memory) for its takeReady when it next starts.
  Future<void> pushReady(List<ReadyPet> pets) async {
    for (final p in pets) {
      _ready
        ..removeWhere((x) => x.petId == p.petId)
        ..add(p);
    }
    final sent = List<ReadyPet>.of(_ready); // later overlapping pushes add to _ready meanwhile
    try {
      await _transport
          .invoke(BridgeMethods.petsReady, {'pets': [for (final p in sent) p.toJson()]})
          .timeout(const Duration(seconds: 3));
      _ready.removeWhere(sent.contains);
    } catch (_) {}
  }
}

/// Main-window end.
class MainWindowBridge {
  MainWindowBridge(
    this._transport, {
    this.ackTimeout = const Duration(seconds: 3),
    this.adoptTimeout = const Duration(seconds: 60),
    this.accountTimeout = const Duration(seconds: 25),
  });

  final BridgeTransport _transport;
  final Duration ackTimeout;
  final Duration adoptTimeout;

  /// Longer than the pet window's own network timeout (10 s), so its answer
  /// -- with the server's message -- normally arrives first.
  final Duration accountTimeout;
  final _states = StreamController<LibraryState>.broadcast();
  final _accounts = StreamController<AccountView>.broadcast();
  final _readies = StreamController<List<ReadyPet>>.broadcast();

  Stream<LibraryState> get states => _states.stream;
  Stream<AccountView> get accounts => _accounts.stream;
  Stream<List<ReadyPet>> get readyPets => _readies.stream;

  void start() => _transport.setHandler((method, args) async {
        if (method == BridgeMethods.stateChanged && !_states.isClosed) {
          _states.add(LibraryState.fromJson(args! as Map<Object?, Object?>));
        }
        if (method == BridgeMethods.accountChanged && !_accounts.isClosed) {
          _accounts.add(AccountView.fromJson(args! as Map<Object?, Object?>));
        }
        if (method == BridgeMethods.petsReady && !_readies.isClosed) {
          final pets = ReadyPet.listFrom(args);
          if (pets.isNotEmpty) _readies.add(pets);
        }
        return null;
      });

  /// What arrived while this window was not running; empty when nothing did
  /// or the pet window does not answer.
  Future<List<ReadyPet>> takeReady() async {
    try {
      return ReadyPet.listFrom(await _transport.invoke(BridgeMethods.takeReady).timeout(ackTimeout));
    } catch (_) {
      return const [];
    }
  }

  /// Ask the pet window to look for delivered custom pets now. Fire and forget.
  void refreshCustom() => _transport.invoke(BridgeMethods.refreshCustom).ignore();

  /// Null when the pet window does not answer.
  Future<AccountView?> getAccount() async {
    try {
      final v = await _transport.invoke(BridgeMethods.getAccount).timeout(ackTimeout);
      return AccountView.fromJson(v! as Map<Object?, Object?>);
    } catch (_) {
      return null;
    }
  }

  Future<AccountReply> sendSms(String phone) => _account(BridgeMethods.sendSms, {'phone': phone});

  Future<AccountReply> login(String phone, String code) =>
      _account(BridgeMethods.login, {'phone': phone, 'code': code});

  Future<AccountReply> logout() => _account(BridgeMethods.logout);

  Future<AccountReply> syncNow() => _account(BridgeMethods.syncNow);

  Future<AccountReply> _account(String method, [Object? args]) async {
    try {
      final v = await _transport.invoke(method, args).timeout(accountTimeout);
      return AccountReply.fromJson(v! as Map<Object?, Object?>);
    } on TimeoutException {
      return const AccountReply(ok: false, message: '操作超时，请重试');
    } catch (e) {
      developer.log('$method failed: $e', name: 'aipet.bridge');
      return const AccountReply(ok: false, message: '操作失败，请重试');
    }
  }

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

  Future<void> dispose() async {
    await _states.close();
    await _accounts.close();
    await _readies.close();
  }
}
