import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';

void main() {
  late FakeHttp http;
  late CustomService svc;

  setUp(() {
    http = FakeHttp();
    svc = CustomService(ApiClient(http, baseUrl: 'https://example.test', token: () => 't'));
  });

  test('every call: method, path and body as the server reads them', () async {
    http.reply = (r) => switch (r.url.path) {
          '/api/aipet/custom/plans' => FakeHttp.ok([]),
          '/api/aipet/custom/upload-tickets' => FakeHttp.ok([
              for (final k in ['k1', 'k2']) {'key': k, 'url': 'https://b.oss', 'fields': {'key': k}},
            ]),
          '/api/aipet/custom/requests' when r.method == 'GET' => FakeHttp.ok([]),
          '/api/aipet/custom/requests' => FakeHttp.ok({'id': 3, 'name': 'a', 'species': 'cat', 'status': 'draft'}),
          '/api/aipet/custom/requests/3/order' =>
            FakeHttp.ok({'order_no': 'PX9', 'amount_cents': 3900, 'code_url': 'weixin://x', 'expires_in': 900}),
          _ => FakeHttp.ok({'status': 'paid'}),
        };
    await svc.plans();
    expect((await svc.tickets(2)).map((t) => t.key), ['k1', 'k2']);
    await svc.create(name: '豆豆', species: 'cat', photoKeys: ['k1', 'k2']);
    await svc.order(3, 'pro');
    expect(await svc.status('PX9'), PayStatus.paid);
    await svc.list();
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'], [
      'GET /api/aipet/custom/plans',
      'POST /api/aipet/custom/upload-tickets',
      'POST /api/aipet/custom/requests',
      'POST /api/aipet/custom/requests/3/order',
      'GET /api/aipet/custom/orders/PX9',
      'GET /api/aipet/custom/requests',
    ]);
    expect(http.sent[1].json, {'count': 2});
    expect(http.sent[2].json, {'name': '豆豆', 'species': 'cat', 'photo_keys': ['k1', 'k2']});
    expect(http.sent[3].json, {'plan_code': 'pro'});
    expect(http.sent.first.headers['Authorization'], 'Bearer t');
  });

  test('server refusals become CustomFailure with code and field', () async {
    http.reply = (_) => FakeHttp.fail(5010, '名字需要 1–8 个字', {'field': 'name'});
    await expectLater(
      svc.create(name: '', species: 'cat', photoKeys: ['k']),
      throwsA(isA<CustomFailure>()
          .having((f) => f.code, 'code', 5010)
          .having((f) => f.field, 'field', 'name')
          .having((f) => f.message, 'message', '名字需要 1–8 个字')),
    );
  });

  test('offline and 401 become CustomFailure with the client words', () async {
    http.reply = (_) => throw Exception('down');
    await expectLater(svc.plans(), throwsA(isA<CustomFailure>().having((f) => f.message, 'm', '网络连接失败，请稍后再试')));
    http.reply = (_) => FakeHttp.fail(1003, 'x', null, 401);
    await expectLater(svc.plans(), throwsA(isA<CustomFailure>().having((f) => f.message, 'm', '登录已过期，请重新登录')));
  });

  test('a malformed reply is a failure, not a crash', () async {
    http.reply = (_) => FakeHttp.ok({'unexpected': true});
    await expectLater(svc.order(1, 'pro'), throwsA(isA<CustomFailure>()));
    http.reply = (_) => FakeHttp.ok([{'code': 'bad'}, {'code': 'ok', 'name': 'n', 'subtitle': '', 'price_cents': 1,
      'valid_days': 0, 'tags': [], 'features': [], 'feature_count': 0, 'fidelity': 0, 'revisions': 0, 'icon': 'standard'}]);
    expect((await svc.plans()).map((p) => p.code), ['ok']);
  });
  test('a 1003 (login expired) tells onLoginExpired before failing; other failures do not', () async {
    var expired = 0;
    svc = CustomService(ApiClient(http, baseUrl: 'https://example.test', token: () => 't'),
        onLoginExpired: () => expired++);
    http.reply = (_) => FakeHttp.fail(1003, 'token invalid', null, 401);
    await expectLater(svc.list(), throwsA(isA<CustomFailure>().having((f) => f.code, 'code', 1003)));
    expect(expired, 1);
    http.reply = (_) => FakeHttp.fail(5011, '已支付');
    await expectLater(svc.order(1, 'pro'), throwsA(isA<CustomFailure>()));
    expect(expired, 1);
  });
}
