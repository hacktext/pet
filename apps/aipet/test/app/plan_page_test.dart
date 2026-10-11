import 'dart:async';

import 'package:aipet/app/main_window/custom_flow/custom_deps.dart';
import 'package:aipet/app/main_window/custom_flow/plan_model.dart';
import 'package:aipet/app/main_window/custom_flow/plan_page.dart';
import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';
import '../support/fake_oss.dart';

Map<String, Object?> plan(String code, String name, int cents, {int days = 0, String? badge}) => {
      'code': code, 'name': name, 'subtitle': '$name副标题', 'price_cents': cents, 'valid_days': days,
      'tags': ['AI 定制形象'], 'features': ['站立', '行走'], 'feature_count': 8, 'fidelity': 85,
      'revisions': 2, 'badge': badge, 'icon': code == 'pro' ? 'pro' : 'standard',
    };

void main() {
  late FakeHttp http;
  late CustomService svc;
  const request = CustomRequestInfo(id: 5, name: '豆豆', species: Species.cat, status: CustomStatus.draft);

  setUp(() {
    http = FakeHttp();
    svc = CustomService(ApiClient(http, baseUrl: 'https://x', token: () => 't'));
    http.reply = (r) => r.url.path.endsWith('/plans')
        ? FakeHttp.ok([plan('standard', '标准版', 3900, days: 365), plan('pro', '高级Pro版', 5900, badge: '推荐')])
        : FakeHttp.ok({'order_no': 'PX1', 'amount_cents': 5900, 'code_url': 'weixin://x', 'expires_in': 900});
  });

  test('loads plans, selects the first, orders the chosen one', () async {
    final m = PlanModel(svc, request);
    await m.load();
    expect(m.selected!.code, 'standard');
    m.select('pro');
    final o = await m.createOrder();
    expect(o!.orderNo, 'PX1');
    expect(http.to('/api/aipet/custom/requests/5/order').single.json, {'plan_code': 'pro'});
  });

  test('a plan taken off sale reloads the list and says so; already paid says so', () async {
    final m = PlanModel(svc, request);
    await m.load();
    http.reply = (r) => r.url.path.endsWith('/plans')
        ? FakeHttp.ok([plan('pro', '高级Pro版', 5900)])
        : FakeHttp.fail(5013, '该套餐已下架');
    expect(await m.createOrder(), isNull);
    expect(m.message, '该套餐已下架');
    expect(m.plans.map((p) => p.code), ['pro']);
    expect(m.selected!.code, 'pro');
    expect(m.busy, isFalse);
    http.reply = (_) => FakeHttp.fail(5011, '这个定制已经支付过了');
    expect(await m.createOrder(), isNull);
    expect(m.message, '这个定制已经支付过了');
  });

  test('a 5011 on ordering sets alreadyPaid', () async {
    final m = PlanModel(svc, request);
    await m.load();
    expect(m.alreadyPaid, isFalse);
    http.reply = (_) => FakeHttp.fail(5011, '这个定制已经支付过了');
    expect(await m.createOrder(), isNull);
    expect(m.alreadyPaid, isTrue);
  });

  testWidgets('a 5011 on the page continues to the already-paid callback', (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var paid = 0;
    final deps = CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);
    await tester.pumpWidget(MaterialApp(
        home: PlanPage(deps: deps, request: request, onOrder: (_, _, _) {}, onAlreadyPaid: (_) => paid++)));
    await tester.pumpAndSettle();
    http.reply = (_) => FakeHttp.fail(5011, '这个定制已经支付过了');
    await tester.tap(find.text('创建宠物'));
    await tester.pumpAndSettle();
    expect(paid, 1);
  });

  test('the own plan of the request is preselected when listed, else the first', () async {
    const own = CustomRequestInfo(
        id: 5, name: '豆豆', species: Species.cat, status: CustomStatus.pendingPayment, planCode: 'pro');
    final m = PlanModel(svc, own);
    await m.load();
    expect(m.selected!.code, 'pro');
    const gone = CustomRequestInfo(
        id: 5, name: '豆豆', species: Species.cat, status: CustomStatus.pendingPayment, planCode: 'old');
    final g = PlanModel(svc, gone);
    await g.load();
    expect(g.selected!.code, 'standard');
  });

  testWidgets('page shows the cards as in the mock and hands back the order', (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    (CustomPlan, PayOrder)? got;
    final deps = CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);
    await tester.pumpWidget(MaterialApp(
        home: PlanPage(deps: deps, request: request, onOrder: (_, p, o) => got = (p, o))));
    await tester.pumpAndSettle();
    for (final t in ['选择宠物版本', '标准版', '¥39', '解锁一年', '高级Pro版', '¥59', '永久解锁', '推荐', '还原度85%', '2次修改机会',
      '微信支付', '支付宝（即将上线）']) {
      expect(find.text(t), findsWidgets, reason: t);
    }
    expect(find.text('已选 标准版'), findsOneWidget);
    await tester.tap(find.text('高级Pro版'));
    await tester.pump();
    expect(find.text('已选 高级Pro版'), findsOneWidget);
    await tester.tap(find.text('创建宠物'));
    await tester.pumpAndSettle();
    expect(got!.$1.code, 'pro');
    expect(got!.$2.orderNo, 'PX1');
  });

  test('a double create sends one order request; features render verbatim', () async {
    final gate = Completer<HttpReply>();
    final m = PlanModel(svc, request);
    await m.load();
    http.reply = (r) => r.url.path.endsWith('/order') ? gate.future : FakeHttp.ok([]);
    final a = m.createOrder();
    final b = await m.createOrder();
    expect(b, isNull);
    gate.complete(FakeHttp.ok({'order_no': 'PX2', 'amount_cents': 3900, 'code_url': 'weixin://x', 'expires_in': 900}));
    expect((await a)!.orderNo, 'PX2');
    expect(m.plans.first.features, ['站立', '行走']);
    expect(http.to('/api/aipet/custom/requests/5/order'), hasLength(1));
  });

  test('disposing mid-request does not throw on notify', () async {
    final gate = Completer<HttpReply>();
    final m = PlanModel(svc, request);
    await m.load();
    http.reply = (_) => gate.future;
    final f = m.createOrder();
    m.dispose();
    gate.complete(FakeHttp.fail(5011, '这个定制已经支付过了'));
    expect(await f, isNull);
  });

  testWidgets('WeChat is shown selected and alipay is disabled', (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final deps = CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);
    await tester.pumpWidget(MaterialApp(home: PlanPage(deps: deps, request: request, onOrder: (_, _, _) {})));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsWidgets);
    expect(find.bySemanticsLabel('微信支付，已选择'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '支付宝（即将上线）')).onPressed, isNull);
  });

  test('a failed reload after a withdrawn plan keeps the withdrawn message', () async {
    final m = PlanModel(svc, request);
    await m.load();
    http.reply = (r) => r.url.path.endsWith('/plans') ? FakeHttp.fail(5000, '网络错误') : FakeHttp.fail(5013, '该套餐已下架');
    expect(await m.createOrder(), isNull);
    expect(m.message, '该套餐已下架');
    expect(m.busy, isFalse);
  });

  test('features come through verbatim, including appended items', () async {
    http.reply = (_) => FakeHttp.ok([
          {...plan('pro', '高级Pro版', 5900), 'features': ['卖萌', '更多动作（后续追加）']}
        ]);
    final m = PlanModel(svc, request);
    await m.load();
    expect(m.plans.single.features, ['卖萌', '更多动作（后续追加）']);
  });

  test('validText and yuan', () {
    expect(CustomPlan.fromJson(plan('pro', 'P', 5900))!.validText, '永久解锁');
    expect(CustomPlan.fromJson(plan('s', 'S', 3900, days: 365))!.validText, '解锁一年');
    expect(yuan(1), '¥0.01');
    expect(yuan(3950), '¥39.50');
  });

  testWidgets('empty list shows text and retry; failed load then retry shows plans', (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    http.reply = (_) => FakeHttp.ok([]);
    final deps = CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);
    await tester.pumpWidget(MaterialApp(home: PlanPage(deps: deps, request: request, onOrder: (_, _, _) {})));
    await tester.pumpAndSettle();
    expect(find.text('暂无可选套餐'), findsOneWidget);
    http.reply = (_) => FakeHttp.fail(5000, '网络错误');
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('网络错误'), findsWidgets);
    http.reply = (_) => FakeHttp.ok([plan('standard', '标准版', 3900, days: 365)]);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('标准版'), findsWidgets);
    expect(find.text('重试'), findsNothing);
    expect(find.text('网络错误'), findsNothing);
  });

  testWidgets('plan card is announced as a selectable button', (tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final deps = CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);
    await tester.pumpWidget(MaterialApp(home: PlanPage(deps: deps, request: request, onOrder: (_, _, _) {})));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.button == true && w.properties.selected == true),
        findsOneWidget);
  });
}
