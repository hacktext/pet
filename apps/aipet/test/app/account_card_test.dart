import 'dart:io';

import 'package:aipet/app/main_window/main_window_app.dart';
import 'package:aipet/app/main_window/main_window_model.dart';
import 'package:aipet/domain/account_view.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_account.dart';
import '../support/fake_transport.dart';
import '../support/pet_fixtures.dart';

void main() {
  late Directory tmp;
  late FakeAccount account;
  late PetWindowBridge petSide;
  late MainWindowModel model;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('account_card_');
    final builtin = Directory('${tmp.path}\\builtin')..createSync();
    writePet(builtin, id: 'builtin-gold', name: '金毛');
    final (petEnd, mainEnd) = FakeTransport.pair();
    account = FakeAccount();
    petSide = PetWindowBridge(petEnd,
        state: () => LibraryState.empty,
        onAdopt: (id) async {},
        onMainWindowClosing: () async {},
        onQuit: () async {},
        account: account)
      ..start();
    model = MainWindowModel(
      library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
      bridge: MainWindowBridge(mainEnd,
          ackTimeout: const Duration(milliseconds: 50), adoptTimeout: const Duration(milliseconds: 200)),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final phone = find.byKey(const Key('account-phone'));
  final code = find.byKey(const Key('account-code'));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await model.start();
    await tester.pumpWidget(MainWindowApp(model: model));
    await tester.tap(find.text('我的'));
    await tester.pump();
  }

  /// Lets a bridge round trip (several microtask hops) finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
  }

  testWidgets('signed out: phone, code, 获取验证码 and 登录', (tester) async {
    await open(tester);
    expect(phone, findsOneWidget);
    expect(code, findsOneWidget);
    expect(find.text('获取验证码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('还没有领养小伙伴，去广场看看吧'), findsOneWidget);
  });

  testWidgets('a bad phone number is caught here, not sent', (tester) async {
    await open(tester);
    await tester.enterText(phone, '12345');
    await tester.tap(find.text('获取验证码'));
    await settle(tester);
    expect(find.text('请输入正确的手机号'), findsOneWidget);
    expect(account.calls, isEmpty);
  });

  testWidgets('获取验证码 counts down from the wait the server gave', (tester) async {
    account.smsReply = const AccountReply(ok: true, retryAfter: 60);
    await open(tester);
    await tester.enterText(phone, '13800138000');
    await tester.tap(find.text('获取验证码'));
    await settle(tester);
    expect(account.calls, ['sms 13800138000']);
    expect(find.text('60秒后重发'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('59秒后重发'), findsOneWidget);
    await tester.tap(find.text('59秒后重发')); // disabled
    await settle(tester);
    expect(account.calls, hasLength(1));
    await tester.pump(const Duration(seconds: 59));
    expect(find.text('获取验证码'), findsOneWidget);
  });

  testWidgets('too frequent: the server message inline, and its own wait', (tester) async {
    await open(tester); // FakeAccount's default: 5001-like, retry after 42
    await tester.enterText(phone, '13800138000');
    await tester.tap(find.text('获取验证码'));
    await settle(tester);
    expect(find.text('发送太频繁'), findsOneWidget);
    expect(find.text('42秒后重发'), findsOneWidget);
    await tester.pump(const Duration(seconds: 42));
  });

  testWidgets('a wrong code shows what the server said', (tester) async {
    account.loginReply = const AccountReply(ok: false, message: '验证码错误或已过期');
    await open(tester);
    await tester.enterText(phone, '13800138000');
    await tester.enterText(code, '12');
    await tester.tap(find.text('登录'));
    await settle(tester);
    expect(find.text('请输入6位验证码'), findsOneWidget);
    await tester.enterText(code, '000000');
    await tester.tap(find.text('登录'));
    await settle(tester);
    expect(find.text('验证码错误或已过期'), findsOneWidget);
    expect(phone, findsOneWidget);
  });

  testWidgets('signing in turns the card into the account, with sync and sign out', (tester) async {
    await open(tester);
    await tester.enterText(phone, '13800138000');
    await tester.enterText(code, '123456');
    await tester.tap(find.text('登录'));
    await settle(tester);
    expect(account.calls, ['login 13800138000 123456']);
    expect(find.text('138****1234'), findsOneWidget);
    expect(find.text('尚未同步'), findsOneWidget);
    expect(phone, findsNothing);

    // The pet window pushes the sync time once a sync lands.
    await petSide.pushAccount(account.view = AccountView(
        phoneMasked: '138****1234', name: '用户1234', lastSyncAt: DateTime(2026, 10, 2, 14, 5)));
    await settle(tester);
    expect(find.text('上次同步：10-02 14:05'), findsOneWidget);

    await tester.tap(find.text('立即同步'));
    await settle(tester);
    expect(account.calls.last, 'sync');
    expect(find.text('同步完成'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // the SnackBar goes away

    account.syncReply = const AccountReply(ok: false, message: '网络连接失败，请稍后再试');
    await tester.tap(find.text('立即同步'));
    await settle(tester);
    expect(find.text('网络连接失败，请稍后再试'), findsOneWidget);

    await tester.tap(find.text('退出登录'));
    await settle(tester);
    expect(account.calls.last, 'logout');
    expect(phone, findsOneWidget);
    expect(find.text('网络连接失败，请稍后再试'), findsNothing);
  });

  testWidgets('a pet window already signed in shows the account straight away', (tester) async {
    account.view = const AccountView(phoneMasked: '139****0000', name: 'n', syncing: true);
    await open(tester);
    expect(find.text('139****0000'), findsOneWidget);
    expect(find.text('同步中…'), findsOneWidget);
  });
}
