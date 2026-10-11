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

  test('status labels follow the spec, draft reads as 待支付', () {
    expect(CustomStatus.fromWire('draft')!.label, '待支付');
    expect(CustomStatus.fromWire('pending_payment')!.label, '待支付');
    expect(CustomStatus.fromWire('paid')!.label, '待制作');
    expect(CustomStatus.fromWire('making')!.label, '制作中');
    expect(CustomStatus.fromWire('done')!.label, '已完成');
    expect(CustomStatus.fromWire('refunded')!.label, '已退款');
    expect(CustomStatus.fromWire('nope'), isNull);
    expect(PayStatus.fromWire('paid'), PayStatus.paid);
    expect(PayStatus.fromWire('weird'), PayStatus.pending);
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
}
