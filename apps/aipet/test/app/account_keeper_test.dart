import 'dart:io';

import 'package:aipet/app/pet_window/account_keeper.dart';
import 'package:aipet/domain/account_view.dart';
import 'package:aipet/services/account_store.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';
import '../support/fake_sync_local.dart';

const _login = {
  'token': '9|tok',
  'created': true,
  'user': {'id': 9, 'name': '用户1234', 'phone_masked': '138****1234'},
};

void main() {
  late Directory root;
  late FakeHttp http;
  late DateTime now;
  late List<String> tracked;
  late List<AccountView> pushed;
  late AccountKeeper keeper;
  late SyncService sync;

  AccountKeeper make() {
    late final AccountKeeper k;
    final api = ApiClient(http, baseUrl: 'https://x.test', token: () => k.token, onUnauthorized: () => k.expired());
    sync = SyncService(root, api: api, local: FakeLocal(), signedIn: () => k.signedIn, now: () => now);
    return k = AccountKeeper(
      store: AccountStore(root),
      api: api,
      sync: sync,
      track: (name, {petId, props}) => tracked.add(name),
      deviceId: '0b6c3d4e-1111-4222-8333-444455556666',
      deviceName: 'MY-PC',
      push: (v) async => pushed.add(v),
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('keeper_acct_');
    http = FakeHttp();
    now = DateTime.fromMillisecondsSinceEpoch(1790000000000);
    tracked = [];
    pushed = [];
    http.reply = (r) => switch (r.url.path) {
          '/api/aipet/auth/login' => FakeHttp.ok(_login),
          '/api/aipet/sms/send' => FakeHttp.ok({'retry_after': 60}),
          '/api/aipet/sync' => FakeHttp.ok({'version': 4, 'data': r.json['data']}),
          _ => FakeHttp.ok(null),
        };
    keeper = make();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('signed out to begin with', () {
    expect(keeper.signedIn, isFalse);
    expect(keeper.view, AccountView.signedOut);
  });

  test('sendSms: the wait from the server, or its message', () async {
    var r = await keeper.sendSms('13800138000');
    expect((r.ok, r.retryAfter), (true, 60));
    http.reply = (_) => FakeHttp.fail(5001, '发送太频繁，请稍后再试', {'retry_after': 37});
    r = await keeper.sendSms('13800138000');
    expect((r.ok, r.message, r.retryAfter), (false, '发送太频繁，请稍后再试', 37));
    http.reply = (_) => throw Exception('down');
    r = await keeper.sendSms('13800138000');
    expect((r.ok, r.message), (false, '网络连接失败，请稍后再试'));
  });

  test('login: saved, announced, tracked, then synced with the new token', () async {
    final r = await keeper.login('13800138000', '123456');
    expect(r.ok, isTrue);
    expect(http.to('/api/aipet/auth/login').single.json, {
      'phone': '13800138000',
      'code': '123456',
      'device_id': '0b6c3d4e-1111-4222-8333-444455556666',
      'device_name': 'MY-PC',
    });
    expect(keeper.view.phoneMasked, '138****1234');
    expect(AccountStore(root).load()!.token, '9|tok');
    expect(tracked, ['login']);
    expect(pushed.first.signedIn, isTrue);
    await keeper.syncNow(); // joins the sync login started
    final puts = http.to('/api/aipet/sync');
    expect(puts, hasLength(1));
    expect(puts.single.headers['Authorization'], 'Bearer 9|tok');
    expect(keeper.view.lastSyncAt, now);
    expect(pushed.last.lastSyncAt, now);
    expect(make().signedIn, isTrue, reason: 'a restart stays signed in');
  });

  test('a wrong code: the server says so, nothing saved', () async {
    http.reply = (_) => FakeHttp.fail(5002, '验证码错误或已过期');
    final r = await keeper.login('13800138000', '000000');
    expect((r.ok, r.message), (false, '验证码错误或已过期'));
    expect(keeper.signedIn, isFalse);
    expect(AccountStore(root).file.existsSync(), isFalse);
    expect(tracked, isEmpty);
  });

  test('logout: the server is told with the token, then everything local is forgotten', () async {
    await keeper.login('13800138000', '123456');
    await keeper.syncNow();
    await keeper.logout();
    final out = http.to('/api/aipet/auth/logout').single;
    expect(out.headers['Authorization'], 'Bearer 9|tok');
    expect(keeper.signedIn, isFalse);
    expect(AccountStore(root).file.existsSync(), isFalse);
    expect(sync.version, 0);
    expect(tracked, ['login', 'logout']);
    expect(pushed.last, AccountView.signedOut);
  });

  test('logout offline still signs out here', () async {
    await keeper.login('13800138000', '123456');
    http.reply = (_) => throw Exception('down');
    await keeper.logout();
    expect(keeper.signedIn, isFalse);
  });

  test('a 401 on any call signs out and says so', () async {
    await keeper.login('13800138000', '123456');
    await keeper.syncNow();
    http.reply = (_) => FakeHttp.fail(1003, 'Unauthenticated.', null, 401);
    final r = await keeper.syncNow();
    expect(r.ok, isFalse);
    expect(r.message, '登录已过期，请重新登录');
    expect(keeper.signedIn, isFalse);
    expect(AccountStore(root).file.existsSync(), isFalse);
    expect(pushed.last, AccountView.signedOut);
  });

  test('syncNow signed out asks to sign in first', () async {
    final r = await keeper.syncNow();
    expect((r.ok, r.message), (false, '请先登录'));
    expect(http.sent, isEmpty);
  });

  test('start: a signed-in launch syncs; a signed-out one does not', () async {
    keeper.start();
    expect(http.sent, isEmpty);
    AccountStore(root).save(Account.fromLogin(_login)!);
    keeper = make()..start();
    await keeper.syncNow();
    expect(http.to('/api/aipet/sync'), hasLength(1));
  });

  test('tick syncs what changed after 5 minutes and pushes the new time', () async {
    await keeper.login('13800138000', '123456');
    await keeper.syncNow();
    sync.statsChanged();
    now = now.add(const Duration(minutes: 5));
    pushed.clear();
    await keeper.tick();
    expect(http.to('/api/aipet/sync'), hasLength(2));
    expect(pushed.last.lastSyncAt, now);
  });
}
