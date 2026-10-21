import 'package:aipet/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';

void main() {
  late FakeHttp http;
  late ApiClient api;
  String? token;
  var unauthorized = 0;

  setUp(() {
    http = FakeHttp();
    token = null;
    unauthorized = 0;
    api = ApiClient(http, baseUrl: 'https://example.test/', token: () => token, onUnauthorized: () => unauthorized++);
  });

  test('base URL: the default, overridden by AIPET_API_BASE', () {
    expect(apiBaseFrom(const {}), 'https://aipei.pixpickai.com');
    expect(apiBaseFrom(const {'AIPET_API_BASE': 'http://aipet.localhost:8000/'}), 'http://aipet.localhost:8000');
    expect(apiBaseFrom(const {'AIPET_API_BASE': '  '}), 'https://aipei.pixpickai.com');
  });

  test('hello posts JSON to the right path and returns the envelope data', () async {
    http.reply = (_) => FakeHttp.ok({'server_time': 123});
    final r = await api.hello(deviceId: 'd', os: 'windows', appVersion: '1.0.0');
    expect(r, isA<ApiOk>().having((o) => (o.data! as Map)['server_time'], 'server_time', 123));
    final s = http.sent.single;
    expect(s.method, 'POST');
    expect(s.url.toString(), 'https://example.test/api/aipet/device/hello');
    expect(s.headers['Content-Type'], 'application/json; charset=utf-8');
    expect(s.headers.containsKey('Authorization'), isFalse);
    expect(s.json, {'device_id': 'd', 'os': 'windows', 'app_version': '1.0.0'});
  });

  test('a token, when there is one, goes along as a Bearer header', () async {
    token = '12|abc';
    await api.me();
    expect(http.sent.single.headers['Authorization'], 'Bearer 12|abc');
    expect(http.sent.single.method, 'GET');
    expect(http.sent.single.body, isNull);
  });

  test('every endpoint: method, path and body as the server reads them', () async {
    await api.events('d', [
      {'uid': 'u', 'name': 'app_start', 'ts': 1}
    ]);
    await api.sendSms('13800138000');
    await api.login(phone: '13800138000', code: '123456', deviceId: 'd', deviceName: 'PC');
    await api.logout();
    await api.getSync();
    await api.putSync(3, {'settings': null});
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'], [
      'POST /api/aipet/events',
      'POST /api/aipet/sms/send',
      'POST /api/aipet/auth/login',
      'POST /api/aipet/auth/logout',
      'GET /api/aipet/sync',
      'PUT /api/aipet/sync',
    ]);
    expect(http.sent[0].json, {
      'device_id': 'd',
      'events': [
        {'uid': 'u', 'name': 'app_start', 'ts': 1}
      ]
    });
    expect(http.sent[1].json, {'phone': '13800138000'});
    expect(http.sent[2].json, {'phone': '13800138000', 'code': '123456', 'device_id': 'd', 'device_name': 'PC'});
    expect(http.sent[5].json, {
      'base_version': 3,
      'data': {'settings': null}
    });
  });

  test('a non-zero code is an ApiError carrying the message and data', () async {
    http.reply = (_) => FakeHttp.fail(5001, '发送太频繁', {'retry_after': 42});
    final r = await api.sendSms('13800138000');
    expect(r, isA<ApiError>());
    final e = r as ApiError;
    expect(e.code, 5001);
    expect(e.message, '发送太频繁');
    expect((e.data! as Map)['retry_after'], 42);
  });

  test('HTTP 401 with a token signs out', () async {
    token = 'stale';
    http.reply = (_) => FakeHttp.fail(1003, 'Unauthenticated.', null, 401);
    final r = await api.getSync();
    expect(r, isA<ApiError>().having((e) => e.code, 'code', 1003));
    expect(unauthorized, 1);
  });

  test('HTTP 401 without a token is just an error', () async {
    http.reply = (_) => FakeHttp.fail(1003, 'Unauthenticated.', null, 401);
    await api.getSync();
    expect(unauthorized, 0);
  });

  test('a thrown transport, a non-JSON body or a 500 are all offline', () async {
    http.reply = (_) => throw Exception('no route');
    expect(await api.me(), isA<ApiOffline>());
    http.reply = (_) => const HttpReply(404, 'Not Found');
    expect(await api.me(), isA<ApiOffline>());
    http.reply = (_) => const HttpReply(500, '<html>');
    expect(await api.me(), isA<ApiOffline>());
  });

  test('a throttled login (429, no envelope) reads as too frequent', () async {
    http.reply = (_) => const HttpReply(429, 'Too Many Requests');
    final r = await api.login(phone: '13800138000', code: '123456', deviceId: 'd', deviceName: 'PC');
    expect(r, isA<ApiError>().having((e) => e.message, 'message', '操作太频繁，请稍后再试'));
  });

  test('every result has a message to show', () async {
    http.reply = (_) => throw Exception('x');
    expect((await api.me()).message, '网络连接失败，请稍后再试');
  });

  test('the server answering with an error page is not called a network failure', () async {
    http.reply = (_) => const HttpReply(500, '<html>');
    expect((await api.me()).message, '服务器暂时出错，请稍后再试');
  });

  test('custom deliveries and assets: GET, with the token', () async {
    token = '1|t';
    await api.customDeliveries();
    await api.customAssets(7);
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'],
        ['GET /api/aipet/custom/deliveries', 'GET /api/aipet/custom/requests/7/assets']);
    expect(http.sent.last.headers['Authorization'], 'Bearer 1|t');
    expect(http.sent.last.body, isNull);
  });

  test('paid character calls: method and path, the order number encoded', () async {
    await api.characters();
    await api.ownedCharacters();
    await api.characterOrder('suwan');
    await api.characterOrderStatus('a/b');
    await api.characterAssets('suwan');
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'], [
      'GET /api/aipet/characters',
      'GET /api/aipet/characters/owned',
      'POST /api/aipet/characters/suwan/order',
      'GET /api/aipet/characters/orders/a%2Fb',
      'GET /api/aipet/characters/suwan/assets',
    ]);
  });
}
