import 'dart:async';
import 'dart:developer' as developer;

import '../../domain/account_view.dart';
import '../../services/account_store.dart';
import '../../services/api_client.dart';
import '../../services/sync_service.dart';
import '../../services/telemetry_queue.dart';
import '../../services/window_bridge.dart';

/// The signed-in user (web platform spec 8), kept by the pet window: the only
/// writer of account.json. The library's account card asks through the
/// window bridge; every change is pushed back to it as an [AccountView].
class AccountKeeper implements AccountHandler {
  AccountKeeper({
    required AccountStore store,
    required this._api,
    required this._sync,
    required this._track,
    required this.deviceId,
    required this.deviceName,
    required this._push,
    this.onSynced,
    this.onLoggedOut,
  })  : _store = store,
        _account = store.load();

  final String deviceId;
  final String deviceName;
  final AccountStore _store;
  final ApiClient _api;
  final SyncService _sync;
  final TrackFn _track;
  final Future<void> Function(AccountView) _push;
  /// After every sync (generation spec 6.1: delivered custom pets are looked
  /// for then). The sync after login counts, so this covers signing in too.
  final void Function()? onSynced;

  /// The user signed out on purpose (not a refused token: an expired login
  /// keeps what this computer knew, paid characters included).
  final void Function()? onLoggedOut;
  Account? _account;

  String? get token => _account?.token;
  bool get signedIn => _account != null;

  @override
  AccountView get view {
    final a = _account;
    if (a == null) return AccountView.signedOut;
    return AccountView(
      phoneMasked: a.user.phoneMasked,
      name: a.user.name,
      lastSyncAt: _sync.lastSyncAt,
      syncing: _sync.syncing,
    );
  }

  /// A signed-in launch syncs once, in the background.
  void start() {
    if (signedIn) unawaited(syncNow());
  }

  /// Called every minute: syncs what changed, at most every 5 minutes.
  Future<void> tick() async {
    final before = _sync.lastSyncAt;
    await _sync.maybeSync();
    if (_sync.lastSyncAt != before) {
      unawaited(_push(view));
      onSynced?.call();
    }
  }

  @override
  Future<AccountReply> sendSms(String phone) async {
    final r = await _api.sendSms(phone);
    int? wait(Object? data) => data is Map && data['retry_after'] is int ? data['retry_after'] as int : null;
    return switch (r) {
      ApiOk(:final data) => AccountReply(ok: true, retryAfter: wait(data) ?? 60),
      ApiError(:final data) => AccountReply(ok: false, message: r.message, retryAfter: wait(data)),
      ApiOffline() => AccountReply(ok: false, message: r.message),
    };
  }

  @override
  Future<AccountReply> login(String phone, String code) async {
    final r = await _api.login(phone: phone, code: code, deviceId: deviceId, deviceName: deviceName);
    if (r is! ApiOk) return AccountReply(ok: false, message: r.message);
    final a = Account.fromLogin(r.data);
    if (a == null) return const AccountReply(ok: false, message: '登录失败，请稍后再试');
    _account = a;
    try {
      _store.save(a);
    } catch (e) {
      // Signed in for this run all the same; the next launch asks again.
      developer.log('account save failed: $e', name: 'aipet.account');
    }
    _track('login');
    unawaited(_push(view));
    unawaited(syncNow()); // the account's pets, stats and voices come down
    return const AccountReply(ok: true);
  }

  @override
  Future<void> logout() async {
    if (_account == null) return;
    // ApiClient reads the token as the call starts, so the request still
    // carries it after the line below forgets it; signing out here does not
    // wait for a server that may be unreachable.
    final told = _api.logout();
    _track('logout');
    _forget();
    onLoggedOut?.call();
    await told;
  }

  /// The server no longer takes our token (HTTP 401).
  void expired() {
    if (_account == null) return;
    developer.log('token refused; signed out', name: 'aipet.account');
    _forget();
  }

  void _forget() {
    _account = null;
    try {
      _store.clear();
    } catch (e) {
      developer.log('account clear failed: $e', name: 'aipet.account');
    }
    _sync.signedOut();
    unawaited(_push(view));
  }

  @override
  Future<AccountReply> syncNow() async {
    if (!signedIn) return const AccountReply(ok: false, message: '请先登录');
    final running = _sync.syncNow();
    unawaited(_push(view)); // syncing
    final r = await running;
    unawaited(_push(view));
    onSynced?.call();
    return AccountReply(ok: r is ApiOk, message: r.message);
  }
}
