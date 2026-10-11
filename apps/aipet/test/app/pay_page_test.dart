import 'dart:async';

import 'package:aipet/app/main_window/custom_flow/custom_deps.dart';
import 'package:aipet/app/main_window/custom_flow/pay_model.dart';
import 'package:aipet/app/main_window/custom_flow/pay_page.dart';
import 'package:aipet/app/main_window/custom_flow/submitted_page.dart';
import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';
import '../support/fake_oss.dart';

/// Waits (real time, 5 ms steps, 2 s cap) until [done]; no fixed sleeps.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeHttp http;
  late CustomService svc;
  var status = 'pending';
  const order = PayOrder(orderNo: 'PX1', amountCents: 3900, codeUrl: 'weixin://wxpay/x', expiresIn: Duration(minutes: 15));
  const request = CustomRequestInfo(id: 5, name: '豆豆', species: Species.cat, status: CustomStatus.pendingPayment);
  const plan = CustomPlan(code: 'standard', name: '标准版', subtitle: '', priceCents: 3900, validDays: 365, tags: [],
      features: [], featureCount: 8, fidelity: 85, revisions: 2, badge: null, icon: 'standard');
  const orders = '/api/aipet/custom/orders/PX1';
  const expiredMsg = '登录已过期，请重新登录';

  CustomDeps deps() => CustomDeps(service: svc, uploader: OssUploader(FakeOss()), pick: () async => []);

  setUp(() {
    status = 'pending';
    http = FakeHttp()
      ..reply = (r) => r.url.path.endsWith('/order')
          ? FakeHttp.ok({'order_no': 'PX2', 'amount_cents': 3900, 'code_url': 'weixin://wxpay/y', 'expires_in': 900})
          : FakeHttp.ok({'status': status});
    svc = CustomService(ApiClient(http, baseUrl: 'https://x', token: () => 't'));
  });

  PayModel model({Duration every = const Duration(seconds: 2), PayOrder o = order}) =>
      PayModel(service: svc, requestId: 5, planCode: 'standard', order: o, pollEvery: every);

  testWidgets('polls every 2 s and reports paid', (tester) async {
    var paid = 0;
    await tester.pumpWidget(MaterialApp(
        home: PayPage(deps: deps(), request: request, plan: plan, order: order, onPaid: (_) => paid++)));
    expect(find.text('¥39'), findsWidgets);
    expect(find.text('请使用微信扫码支付'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(http.to(orders), hasLength(1));
    status = 'paid';
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(paid, 1);
    await tester.pump(const Duration(seconds: 6));
    expect(http.to(orders), hasLength(2), reason: 'polling stops once paid');
  });

  testWidgets('expiry shows the refresh prompt; refreshing gets a new code', (tester) async {
    const short = PayOrder(orderNo: 'PX1', amountCents: 3900, codeUrl: 'weixin://wxpay/x', expiresIn: Duration(seconds: 3));
    await tester.pumpWidget(MaterialApp(
        home: PayPage(deps: deps(), request: request, plan: plan, order: short, onPaid: (_) {})));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.text('二维码已过期，点击刷新'), findsOneWidget);
    await tester.tap(find.text('二维码已过期，点击刷新'));
    await tester.pump();
    await tester.pump();
    expect(http.to('/api/aipet/custom/requests/5/order').single.json, {'plan_code': 'standard'});
    expect(find.text('二维码已过期，点击刷新'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('leaving the page stops polling', () async {
    final m = model(every: const Duration(milliseconds: 10))..start();
    await until(() => http.to(orders).isNotEmpty);
    expect(http.to(orders), isNotEmpty, reason: 'polling really happened before leaving');
    m.dispose();
    final n = http.sent.length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(http.sent.length, n);
  });

  test('a 401 while polling stops polling and says to log in again', () async {
    http.reply = (_) => FakeHttp.fail(1003, 'unauthorized');
    final m = model(every: const Duration(milliseconds: 10))..start();
    await until(() => m.message != null);
    expect(m.message, expiredMsg);
    final n = http.sent.length;
    expect(n, 1, reason: 'only the first poll was made');
    await Future<void>.delayed(const Duration(milliseconds: 50)); // negative check: nothing more arrives
    expect(http.sent.length, n);
    m.dispose();
  });

  test('other poll failures are swallowed and retried on the next tick', () async {
    var calls = 0;
    http.reply = (_) => ++calls == 1 ? FakeHttp.fail(5000, 'busy') : FakeHttp.ok({'status': 'paid'});
    final m = model(every: const Duration(milliseconds: 10))..start();
    await until(() => m.paid);
    expect(m.paid, isTrue);
    expect(m.message, isNull);
    m.dispose();
  });

  test('a 401 while re-ordering says to log in again and keeps the expired state', () async {
    final e = model(o: const PayOrder(orderNo: 'PX1', amountCents: 3900, codeUrl: 'x', expiresIn: Duration(seconds: 1)));
    http.reply = (_) => FakeHttp.fail(1003, 'unauthorized');
    await e.refresh();
    expect(e.message, expiredMsg);
    expect(e.order.orderNo, 'PX1');
    e.dispose();
  });

  test('overlapping refreshes make one request; refreshing after dispose is silent', () async {
    final m = model();
    final a = m.refresh();
    final b = m.refresh();
    await Future.wait([a, b]);
    expect(http.to('/api/aipet/custom/requests/5/order'), hasLength(1));
    expect(m.order.orderNo, 'PX2');
    m.dispose();
    final late = model();
    final f = late.refresh();
    late.dispose();
    await f; // must not throw from notifyListeners after dispose
  });

  test('a late answer for a replaced QR is ignored', () async {
    final held = Completer<HttpReply>();
    http.reply = (r) => r.url.path == orders
        ? held.future
        : FakeHttp.ok({'order_no': 'PX2', 'amount_cents': 3900, 'code_url': 'y', 'expires_in': 900});
    final m = model(every: const Duration(milliseconds: 10), o: const PayOrder(
        orderNo: 'PX1', amountCents: 3900, codeUrl: 'x', expiresIn: Duration(seconds: 1)))
      ..start();
    await until(() => http.to(orders).isNotEmpty);
    await m.refresh(); // PX2 replaces PX1 while PX1's poll is still out
    expect(m.order.orderNo, 'PX2');
    held.complete(FakeHttp.ok({'status': 'paid'}));
    await until(() => false == m.paid && http.to(orders).isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(m.paid, isFalse);
    m.dispose();
  });

  test('a slow answer is never overlapped by another request', () async {
    final held = Completer<HttpReply>();
    http.reply = (_) => held.future;
    final m = model(every: const Duration(milliseconds: 10))..start();
    await until(() => http.to(orders).isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 80)); // several ticks pass
    expect(http.to(orders), hasLength(1));
    held.complete(FakeHttp.ok({'status': 'pending'}));
    m.dispose();
  });

  test('paid at the boundary: the last check before expiry wins', () async {
    status = 'paid';
    final m = model(every: const Duration(milliseconds: 10), o: const PayOrder(
        orderNo: 'PX1', amountCents: 3900, codeUrl: 'x', expiresIn: Duration(milliseconds: 10)))
      ..start();
    await until(() => m.paid || m.expired);
    expect(m.paid, isTrue);
    expect(m.expired, isFalse);
    m.dispose();
  });

  test('countdown over and still unpaid: expired after one final check', () async {
    final m = model(every: const Duration(milliseconds: 10), o: const PayOrder(
        orderNo: 'PX1', amountCents: 3900, codeUrl: 'x', expiresIn: Duration(milliseconds: 10)))
      ..start();
    await until(() => m.expired);
    expect(m.expired, isTrue);
    expect(http.to(orders), hasLength(1));
    m.dispose();
  });

  testWidgets('the refresh shows progress, and the QR is labelled', (tester) async {
    final held = Completer<HttpReply>();
    http.reply = (r) => r.url.path.endsWith('/order') ? held.future : FakeHttp.ok({'status': 'pending'});
    const short = PayOrder(orderNo: 'PX1', amountCents: 3900, codeUrl: 'x', expiresIn: Duration(seconds: 1));
    await tester.pumpWidget(MaterialApp(
        home: PayPage(deps: deps(), request: request, plan: plan, order: short, onPaid: (_) {})));
    expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == '微信支付二维码'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.tap(find.text('二维码已过期，点击刷新'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('二维码已过期，点击刷新'), findsNothing);
    held.complete(FakeHttp.ok({'order_no': 'PX2', 'amount_cents': 3900, 'code_url': 'y', 'expires_in': 900}));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a 401 on the page shows the login message', (tester) async {
    http.reply = (_) => FakeHttp.fail(1003, 'unauthorized');
    await tester.pumpWidget(MaterialApp(
        home: PayPage(deps: deps(), request: request, plan: plan, order: order, onPaid: (_) {})));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text(expiredMsg), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(http.to(orders), hasLength(1));
  });

  test('re-ordering a QR that was in fact paid (5011) counts as paid', () async {
    final m = model(o: const PayOrder(orderNo: 'PX1', amountCents: 3900, codeUrl: 'x', expiresIn: Duration(seconds: 1)));
    http.reply = (_) => FakeHttp.fail(5011, '这个定制已经支付过了');
    await m.refresh();
    expect(m.paid, isTrue);
    m.dispose();
  });

  testWidgets('pay, expire, refresh gets 5011: the submitted page is shown', (tester) async {
    const short = PayOrder(orderNo: 'PX1', amountCents: 3900, codeUrl: 'x', expiresIn: Duration(seconds: 3));
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (ctx) => PayPage(
                deps: deps(),
                request: request,
                plan: plan,
                order: short,
                onPaid: (c) => Navigator.of(c).pushReplacement(
                    MaterialPageRoute<void>(builder: (_) => SubmittedPage(onDone: (_) {})))))));
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    http.reply = (_) => FakeHttp.fail(5011, '这个定制已经支付过了');
    await tester.tap(find.text('二维码已过期，点击刷新'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('定制已提交'), findsOneWidget);
  });

  test('a refunded order ends polling and says so', () async {
    status = 'refunded';
    final m = model(every: const Duration(milliseconds: 10))..start();
    await until(() => m.message != null);
    expect(m.message, '订单已退款');
    expect(m.paid, isFalse);
    final n = http.sent.length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(http.sent.length, n, reason: 'polling stopped');
    m.dispose();
  });

  testWidgets('submitted page says what happens next', (tester) async {
    var done = 0;
    await tester.pumpWidget(MaterialApp(home: SubmittedPage(onDone: (_) => done++)));
    expect(find.text('定制已提交'), findsOneWidget);
    expect(find.text('预计 1 小时左右完成，完成后可在「我的定制」查看'), findsOneWidget);
    await tester.tap(find.text('查看我的定制'));
    expect(done, 1);
  });
}
