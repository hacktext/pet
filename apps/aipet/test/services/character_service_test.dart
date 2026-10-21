import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/character_service.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';

void main() {
  late FakeHttp http;
  late CharacterService svc;
  var expired = 0;

  setUp(() {
    expired = 0;
    http = FakeHttp();
    svc = CharacterService(ApiClient(http, baseUrl: 'https://example.test', token: () => 't'),
        onLoginExpired: () => expired++);
  });

  test('catalog, owned, order and status: method, path and parsed answers', () async {
    http.reply = (r) => switch (r.url.path) {
          '/api/aipet/characters' => FakeHttp.ok([
              {'code': 'suwan', 'name': '苏晚', 'species': 'girl', 'price_cents': 1990},
              {'nope': 1},
            ]),
          '/api/aipet/characters/owned' => FakeHttp.ok([
              {'code': 'suwan', 'name': '苏晚', 'species': 'girl', 'price_cents': 1990, 'card_url': 'https://oss/s.jpg'},
            ]),
          '/api/aipet/characters/suwan/order' =>
            FakeHttp.ok({'order_no': 'PX9', 'amount_cents': 1990, 'code_url': 'weixin://x', 'expires_in': 900}),
          _ => FakeHttp.ok({'status': 'paid'}),
        };
    expect((await svc.catalog()).map((c) => c.code), ['suwan']);
    final owned = await svc.owned();
    expect(owned.codes, {'suwan'});
    expect(owned.items.single.cardUrl, 'https://oss/s.jpg');
    expect((await svc.order('suwan')).orderNo, 'PX9');
    expect(await svc.status('PX9'), PayStatus.paid);
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'], [
      'GET /api/aipet/characters',
      'GET /api/aipet/characters/owned',
      'POST /api/aipet/characters/suwan/order',
      'GET /api/aipet/characters/orders/PX9',
    ]);
  });

  test('owned: an item this app cannot show is still owned; a bare code (older server) too', () async {
    http.reply = (_) => FakeHttp.ok([
          {'code': 'suwan', 'name': '苏晚', 'species': 'girl', 'price_cents': 1990},
          {'code': 'robo', 'name': 'R', 'species': 'robot', 'price_cents': 1990},
          'guchen',
          {'nope': 1},
        ]);
    final owned = await svc.owned();
    expect(owned.codes, {'suwan', 'robo', 'guchen'});
    expect(owned.items.map((c) => c.code), ['suwan']);
  });

  test('ordering what is already owned fails with 5016', () async {
    http.reply = (_) => FakeHttp.fail(kCharacterOwnedCode, '已解锁');
    await expectLater(
        svc.order('suwan'),
        throwsA(isA<CustomFailure>()
            .having((f) => f.code, 'code', 5016)
            .having((f) => f.message, 'message', '已解锁')));
  });

  test('a login that ran out is announced, then fails with 1003', () async {
    http.reply = (_) => FakeHttp.fail(1003, '请登录');
    await expectLater(svc.owned(), throwsA(isA<CustomFailure>().having((f) => f.code, 'code', 1003)));
    expect(expired, 1);
  });

  test('no network is a CustomFailure without a code', () async {
    http.reply = (_) => throw Exception('down');
    await expectLater(svc.catalog(), throwsA(isA<CustomFailure>().having((f) => f.code, 'code', isNull)));
  });

  test('assets parses pet_id and files', () async {
    http.reply = (_) => FakeHttp.ok({
          'pet_id': 'paid-suwan',
          'files': [
            {'path': 'pet.json', 'bytes': 10, 'sha256': 'a' * 64, 'url': 'https://oss.test/p'},
            {'path': 'stand.mp4', 'bytes': 20, 'sha256': 'b' * 64, 'url': 'https://oss.test/s'},
          ],
        });
    final a = await svc.assets('suwan');
    expect(a.petId, 'paid-suwan');
    expect(a.files.map((f) => f.path), ['pet.json', 'stand.mp4']);
    expect(http.sent.single.url.path, '/api/aipet/characters/suwan/assets');
  });

  test('assets of a character not owned (bare 403) say so', () async {
    http.reply = (_) => const HttpReply(403, 'Forbidden');
    await expectLater(
        svc.assets('suwan'), throwsA(isA<CustomFailure>().having((f) => f.message, 'message', '还没有解锁这个人物')));
  });
}
