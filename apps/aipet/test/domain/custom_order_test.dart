import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/pet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('plans parse, with price and validity as the cards show them', () {
    final p = CustomPlan.fromJson({
      'code': 'pro', 'name': '高级Pro版', 'subtitle': '更丰富', 'price_cents': 5900, 'valid_days': 0,
      'tags': ['AI 定制形象'], 'features': ['站立', '行走'], 'feature_count': 13, 'fidelity': 98,
      'revisions': 5, 'badge': '推荐', 'icon': 'pro',
    })!;
    expect(p.priceText, '¥59');
    expect(p.validText, '永久解锁');
    expect(p.badge, '推荐');
    expect(p.features, ['站立', '行走']);
    final s = CustomPlan.fromJson({
      'code': 'standard', 'name': '标准版', 'subtitle': '', 'price_cents': 3950, 'valid_days': 365,
      'tags': [], 'features': [], 'feature_count': 8, 'fidelity': 85, 'revisions': 2, 'badge': null, 'icon': 'standard',
    })!;
    expect(s.priceText, '¥39.50');
    expect(s.validText, '解锁一年');
    expect(CustomPlan.fromJson({'code': 'x'}), isNull);
  });

  test('requests, tickets and pay orders parse; species labels match the plaza', () {
    final r = CustomRequestInfo.fromJson({
      'id': 7, 'name': '豆豆', 'species': 'girl', 'plan_code': 'pro', 'plan_name': '高级Pro版',
      'price_cents': 5900, 'status': 'paid', 'order_no': 'PX1', 'cover_url': 'https://x/y.jpg',
    })!;
    expect(r.species, Species.girl);
    expect(r.status, CustomStatus.paid);
    expect(speciesLabel(Species.girl), '女生');
    expect(speciesLabel(Species.other), '其他宠物');
    final t = UploadTicket.fromJson({'key': 'k', 'url': 'https://b.oss', 'fields': {'key': 'k', 'policy': 'p'}})!;
    expect(t.fields, {'key': 'k', 'policy': 'p'});
    final o = PayOrder.fromJson({'order_no': 'PX2', 'amount_cents': 3900, 'code_url': 'weixin://x', 'expires_in': 900})!;
    expect(o.expiresIn, const Duration(seconds: 900));
    expect(yuan(3900), '¥39');
  });

  test('statuses follow the generation flow (generation spec 3 / 9)', () {
    const want = {
      'draft': '待支付',
      'pending_payment': '待支付',
      'paid': '待生成',
      'generating': '生成中',
      'review': '审核中',
      'delivered': '已完成',
      'failed': '生成失败',
      'refunded': '已退款',
    };
    want.forEach((wire, label) => expect(CustomStatus.fromWire(wire)?.label, label, reason: wire));
    expect(CustomStatus.fromWire('making'), isNull);
    expect(CustomStatus.fromWire('done'), isNull);
    expect(CustomStatus.fromWire('nope'), isNull);
    expect(PayStatus.fromWire('paid'), PayStatus.paid);
    expect(PayStatus.fromWire('weird'), PayStatus.pending);
  });

  test('我的定制 status text: progress while generating, the promise of help when it failed', () {
    CustomRequestInfo r(Map<String, Object?> extra) =>
        CustomRequestInfo.fromJson({'id': 1, 'name': '豆豆', 'species': 'cat', ...extra})!;
    expect(r({'status': 'generating', 'stage': 'video', 'stage_done': 3, 'stage_total': 7}).statusText, '生成中（动作 3/7）');
    expect(r({'status': 'generating', 'stage': 'refs', 'stage_done': 1, 'stage_total': 3}).statusText, '生成中（参考图 1/3）');
    expect(r({'status': 'generating', 'stage': 'upload', 'stage_done': 2, 'stage_total': 9}).statusText, '生成中');
    expect(r({'status': 'generating'}).statusText, '生成中');
    expect(r({'status': 'generating', 'stage': 'video', 'stage_done': 9, 'stage_total': 7}).statusText, '生成中（动作 7/7）');
    final failed = r({'status': 'failed', 'fail_reason': 'refs: gate failed twice'});
    expect(failed.statusText, '生成失败（我们会联系你处理或退款）');
    expect(failed.failReason, 'refs: gate failed twice');
    expect(r({'status': 'review'}).statusText, '审核中');
    expect(r({'status': 'paid'}).statusText, '待生成');
    final done = r({'status': 'delivered', 'pet_id': 'custom-1'});
    expect((done.statusText, done.petId), ('已完成', 'custom-1'));
    expect(r({'status': 'delivered', 'pet_id': '../x'}).petId, isNull);
  });

  test('deliveries: the usable ones only', () {
    final ds = CustomDelivery.listFrom([
      {'id': 7, 'pet_id': 'custom-7', 'name': '豆豆', 'delivered_at': '2026-10-10 12:00:00'},
      {'id': 8, 'pet_id': 'Custom 8', 'name': 'x'},
      {'id': '9', 'pet_id': 'custom-9', 'name': 'y'},
      'junk',
    ]);
    expect([for (final d in ds) (d.id, d.petId, d.name)], [(7, 'custom-7', '豆豆')]);
    expect(CustomDelivery.listFrom(null), isEmpty);
    expect(isCustomPetId('custom-123'), isTrue);
    expect(isCustomPetId('.downloading'), isFalse);
  });

  test('assets: every file safe and checkable, pet.json among them, or nothing at all', () {
    final hash = 'ab' * 32;
    Map<String, Object?> file(String path) =>
        {'path': path, 'bytes': 10, 'sha256': hash.toUpperCase(), 'url': 'https://oss.test/$path?sig=1'};
    final a = CustomAssets.fromJson({
      'pet_id': 'custom-7',
      'files': [file('pet.json'), file('stand.mp4'), file('voices/a/stand-1.wav')],
    })!;
    expect(a.petId, 'custom-7');
    expect(a.files.map((f) => f.path), ['pet.json', 'stand.mp4', 'voices/a/stand-1.wav']);
    expect(a.files.first.sha256, hash);
    expect(a.files.first.bytes, 10);
    for (final bad in ['../evil.exe', '/abs.mp4', r'a\b.mp4', 'C:/x.mp4', '.hidden', 'a//b', '']) {
      expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [file('pet.json'), file(bad)]}), isNull,
          reason: bad);
    }
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [file('stand.mp4')]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [file('pet.json'), file('PET.json')]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [{...file('pet.json'), 'sha256': 'xyz'}]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [{...file('pet.json'), 'url': 'ftp://x/y'}]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': [{...file('pet.json'), 'bytes': -1}]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': '../x', 'files': [file('pet.json')]}), isNull);
    expect(CustomAssets.fromJson({'pet_id': 'custom-7', 'files': []}), isNull);
  });
}
