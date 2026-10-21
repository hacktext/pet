import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aipet/app/main_window/custom_flow/custom_deps.dart';
import 'package:aipet/app/main_window/main_window_app.dart';
import 'package:aipet/app/main_window/main_window_model.dart';
import 'package:aipet/domain/account_view.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/paid_character.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/catalog_store.dart';
import 'package:aipet/services/character_service.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_account.dart';
import '../support/fake_downloads.dart';
import '../support/fake_http.dart';
import '../support/fake_oss.dart';
import '../support/fake_transport.dart';
import '../support/pet_fixtures.dart';

void main() {
  late Directory tmp;
  late LibraryState petState;
  late Future<void> Function(String) adoptImpl;
  late PetWindowBridge petSide;
  late MainWindowModel model;
  late FakeTransport petEnd;
  late FakeTransport mainEnd;
  late FakeHttp api;
  late FakeAccount accountSide;
  late List<PickedFile> picks;
  var quits = 0;
  var refreshes = 0;

  setUp(() {
    api = FakeHttp();
    accountSide = FakeAccount();
    picks = [];
    tmp = Directory.systemTemp.createTempSync('mainwin_');
    final builtin = Directory('${tmp.path}\\builtin')..createSync();
    writePet(builtin, id: 'builtin-gold', name: '金毛');
    writePet(builtin, id: 'builtin-ragdoll', species: 'cat', name: '布偶猫');
    writePet(builtin, id: 'builtin-xiaoya', species: 'girl', name: '小雅');
    final (pe, me) = FakeTransport.pair();
    petEnd = pe;
    mainEnd = me;
    petState = LibraryState.empty;
    quits = 0;
    refreshes = 0;
    adoptImpl = (id) async {};
    petSide = PetWindowBridge(petEnd,
        state: () => petState,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async {},
        onQuit: () async => quits++,
        onRefreshCustom: () async => refreshes++,
        account: accountSide)
      ..start();
    model = MainWindowModel(
      library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
      // Both timeouts short: a pending 60 s Timer fails a widget test at teardown.
      bridge: MainWindowBridge(mainEnd,
          ackTimeout: const Duration(milliseconds: 50), adoptTimeout: const Duration(milliseconds: 200)),
      custom: CustomDeps(
        service: CustomService(ApiClient(api, baseUrl: 'https://x', token: () => 't'),
            onLoginExpired: () => model.loginExpired()),
        uploader: OssUploader(FakeOss()),
        pick: () async => picks,
        prep: (b) async => b,
      ),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await model.start();
    await tester.pumpWidget(MainWindowApp(model: model));
    await tester.pump();
  }

  // The pet-window side of a successful adopt, optionally held at "preparing".
  Future<void> Function(String) adoptingSucceeds([Completer<void>? hold]) => (id) async {
        petState = petState.preparing(id);
        await petSide.pushState(petState);
        if (hold != null) await hold.future;
        petState = petState.adopted(id);
        await petSide.pushState(petState);
      };

  testWidgets("a character's card shows 静音 until a voice is chosen on it, which the pet window keeps", (tester) async {
    // 小雅 with two voices; the pet window's side answers voice requests.
    final meta = File('${tmp.path}/builtin/builtin-xiaoya/pet.json');
    final j = jsonDecode(meta.readAsStringSync()) as Map<String, Object?>;
    j['voices'] = [
      {'id': 'xiaoya', 'name': '温柔小雅'},
      {'id': 'vivi', 'name': '元气 Vivi'},
    ];
    meta.writeAsStringSync(jsonEncode(j));
    final kept = <String, String>{};
    PetWindowBridge(petEnd,
        state: () => petState,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async {},
        onQuit: () async {},
        voices: _KeptVoices(kept)).start();
    await open(tester);
    await tester.tap(find.text('人物'));
    await tester.pump();
    expect(find.text('声音：静音'), findsOneWidget);
    expect(find.textContaining('声音：'), findsOneWidget, reason: 'only the speaking character has the line');
    await tester.tap(find.byKey(const Key('voice-builtin-xiaoya')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('温柔小雅').last);
    await tester.pumpAndSettle();
    expect(kept, {'builtin-xiaoya': 'xiaoya'});
    expect(find.text('声音：温柔小雅'), findsOneWidget);
    // Back to 静音.
    await tester.tap(find.byKey(const Key('voice-builtin-xiaoya')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('静音').last);
    await tester.pumpAndSettle();
    expect(kept, {'builtin-xiaoya': 'off'});
    expect(find.text('声音：静音'), findsOneWidget);
  });

  testWidgets('plaza: banner, categories and one adoptable card per pet', (tester) async {
    await open(tester);
    expect(find.text('定制专属宠物'), findsOneWidget);
    expect(find.text('上传你的爱宠照片，生成会陪伴你的桌面伙伴'), findsOneWidget);
    for (final label in ['宠物', '人物', '全部', '猫咪', '狗狗', '其他宠物', '发现', '我的']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('女生'), findsNothing);
    expect(find.text('金毛'), findsOneWidget);
    expect(find.text('布偶猫'), findsOneWidget);
    expect(find.text('小雅'), findsNothing);
    expect(find.text('带它回家'), findsNWidgets(2));
  });

  testWidgets('category chips filter the grid', (tester) async {
    await open(tester);
    await tester.tap(find.text('猫咪'));
    await tester.pump();
    expect(find.text('布偶猫'), findsOneWidget);
    expect(find.text('金毛'), findsNothing);
    await tester.tap(find.text('其他宠物'));
    await tester.pump();
    expect(find.text('这里还没有小伙伴'), findsOneWidget);
  });

  testWidgets('人物 shows the characters, its own sub-categories, and resets to 全部', (tester) async {
    await open(tester);
    await tester.tap(find.text('猫咪'));
    await tester.pump();
    await tester.tap(find.text('人物'));
    await tester.pump();
    expect(find.text('小雅'), findsOneWidget);
    expect(find.text('布偶猫'), findsNothing);
    for (final label in ['全部', '男生', '女生', '二次元']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('猫咪'), findsNothing);
    expect(find.text('定制专属人物'), findsOneWidget);
    expect(find.text('上传你的照片，生成会陪伴你的桌面伙伴'), findsOneWidget);
    expect(find.text('定制专属宠物'), findsNothing);
    // The banner sits under 宠物 | 人物 and above the categories: it belongs to the tab.
    expect(tester.getTopLeft(find.text('定制专属人物')).dy, greaterThan(tester.getBottomLeft(find.text('人物')).dy));
    expect(tester.getBottomLeft(find.text('立即定制')).dy, lessThan(tester.getTopLeft(find.text('女生')).dy));
    await tester.tap(find.text('男生'));
    await tester.pump();
    expect(find.text('这里还没有小伙伴'), findsOneWidget);
    await tester.tap(find.text('宠物'));
    await tester.pump();
    expect(find.text('定制专属宠物'), findsOneWidget);
    expect(find.text('金毛'), findsOneWidget);
    expect(find.text('布偶猫'), findsOneWidget);
  });

  testWidgets('adopting shows 正在准备… and then 陪伴中', (tester) async {
    final hold = Completer<void>();
    adoptImpl = adoptingSucceeds(hold);
    await open(tester);
    await tester.tap(find.text('带它回家').first);
    await tester.pump();
    expect(find.text('正在准备…'), findsOneWidget);
    hold.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('陪伴中'), findsOneWidget);
    expect(find.text('带它回家'), findsOneWidget);
  });

  testWidgets('no answer within 3 s (50 ms here) says 切换失败，请重试', (tester) async {
    adoptImpl = (id) => Completer<void>().future;
    await open(tester);
    await tester.tap(find.text('带它回家').first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.text('切换失败，请重试'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300)); // let the ignored adopt timeout fire
  });

  testWidgets('a failed prepare also says 切换失败，请重试', (tester) async {
    adoptImpl = (id) async {
      await petSide.pushState(petState.preparing(id));
      throw const AdoptError('prepare_failed', 'decode failed');
    };
    await open(tester);
    await tester.tap(find.text('带它回家').first);
    await tester.pump();
    await tester.pump();
    expect(find.text('切换失败，请重试'), findsOneWidget);
  });

  testWidgets('我的: empty state, adopted pets, and 退出程序', (tester) async {
    await open(tester);
    await tester.tap(find.text('我的'));
    await tester.pump();
    expect(find.text('还没有领养小伙伴，去广场看看吧'), findsOneWidget);

    petState = const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']);
    await petSide.pushState(petState);
    await tester.pump();
    expect(find.text('金毛'), findsOneWidget);
    expect(find.text('陪伴中'), findsOneWidget);
    expect(find.text('布偶猫'), findsNothing);

    await tester.tap(find.text('退出程序'));
    await tester.pump();
    expect(quits, 1);
  });

  test('a push during startup is not overwritten by the older getState reply', () async {
    var replied = false;
    final gate = Completer<void>();
    const older = LibraryState.empty;
    petEnd.setHandler((method, args) async {
      if (method == BridgeMethods.getState) {
        await gate.future;
        replied = true;
        return older.toJson();
      }
      return null;
    });
    final starting = model.start();
    await Future<void>.delayed(Duration.zero);
    final newer = const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']);
    await petSide.pushState(newer);
    gate.complete();
    await starting;
    expect(replied, isTrue);
    expect(model.statusOf(_plaza(model).firstWhere((p) => p.id == 'builtin-gold')), CardStatus.companion);
  });
  Future<void> signIn(WidgetTester tester) async {
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await tester.pump();
  }

  Map<String, Object?> plan(String code, String name, int cents) => {
        'code': code, 'name': name, 'subtitle': '', 'price_cents': cents, 'valid_days': 0,
        'tags': <String>[], 'features': <String>[], 'feature_count': 1, 'fidelity': 80,
        'revisions': 1, 'badge': null, 'icon': 'standard',
      };

  /// What the form and the plans page ask on the way to the plans: the
  /// photo ticket, the new order (id 9, 豆豆, unpaid) and one plan.
  HttpReply? formReply(SentRequest r) => switch (r.url.path) {
        '/api/aipet/custom/upload-tickets' => FakeHttp.ok([
            {'key': 'k1', 'url': 'https://b.oss', 'fields': {'key': 'k1'}},
          ]),
        '/api/aipet/custom/requests' when r.method == 'POST' =>
          FakeHttp.ok({'id': 9, 'name': '豆豆', 'species': 'cat', 'status': 'draft'}),
        '/api/aipet/custom/plans' => FakeHttp.ok([plan('standard', '标准版', 3900)]),
        _ => null,
      };

  /// 立即定制, a name and a photo, 下一步: the plans of a new, unpaid order --
  /// the only way to them now that 我的定制 lists no unpaid order.
  Future<void> toPlans(WidgetTester tester) async {
    picks = [const PickedFile('a.jpg', [1, 2, 3])];
    await tester.tap(find.text('立即定制'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '豆豆');
    await tester.tap(find.text('点击上传照片'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(find.text('下一步'), find.byType(ListView), const Offset(0, -300));
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
  }

  testWidgets('立即定制 while signed out opens the sign-in page over 我的', (tester) async {
    await open(tester);
    await tester.tap(find.text('立即定制'));
    await tester.pumpAndSettle();
    expect(model.tab, 1);
    expect(find.text('登录后即可定制你的专属宠物'), findsOneWidget);
    expect(find.byKey(const Key('account-phone')), findsOneWidget);
    expect(find.text('定制你的专属宠物'), findsNothing);
  });

  testWidgets('立即定制 while signed in opens the form', (tester) async {
    await open(tester);
    await signIn(tester);
    await tester.tap(find.text('立即定制'));
    await tester.pumpAndSettle();
    expect(find.text('定制你的专属宠物'), findsOneWidget);
  });

  testWidgets('我的定制: every stage in words; an unpaid order is not listed', (tester) async {
    api.reply = (r) => r.url.path.endsWith('/requests')
        ? FakeHttp.ok([
            {'id': 5, 'name': '豆豆', 'species': 'cat', 'plan_name': '标准版', 'status': 'generating',
              'stage': 'video', 'stage_done': 3, 'stage_total': 7},
            {'id': 4, 'name': '旺财', 'species': 'dog', 'status': 'review'},
            {'id': 3, 'name': '咪咪', 'species': 'cat', 'status': 'failed', 'fail_reason': 'refs: gate'},
            {'id': 2, 'name': '小黑', 'species': 'dog', 'status': 'paid'},
            {'id': 1, 'name': '小白', 'species': 'cat', 'status': 'pending_payment'},
          ])
        : FakeHttp.ok([]);
    await open(tester);
    tester.view.physicalSize = const Size(1200, 1600); // the whole list on screen
    await signIn(tester);
    try {
      model.setTab(1);
      await tester.pumpAndSettle();
      expect(find.text('我的定制'), findsOneWidget);
      expect(find.text('猫咪 · 标准版'), findsOneWidget);
      for (final t in ['生成中（动作 3/7）', '审核中', '生成失败（我们会联系你处理或退款）', '待生成']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      for (final t in ['小白', '待支付', '去支付']) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(find.text('refs: gate'), findsNothing);
    } finally {
      model.setTab(0); // stops the 30 s refresh before the timer check
    }
  });

  testWidgets('while something is generating and 我的 is on screen, 我的定制 refreshes every 30 s', (tester) async {
    var status = 'generating';
    api.reply = (r) => r.url.path.endsWith('/requests')
        ? FakeHttp.ok([
            {'id': 5, 'name': '豆豆', 'species': 'cat', 'status': status, 'stage': 'video', 'stage_done': 1, 'stage_total': 7},
          ])
        : FakeHttp.ok([]);
    await open(tester);
    await signIn(tester);
    int asks() => api.to('/api/aipet/custom/requests').length;
    try {
      model.setTab(1);
      await tester.pump();
      await tester.pump();
      var n = asks();
      await tester.pump(const Duration(seconds: 30));
      expect(asks(), ++n);
      expect(find.text('生成中（动作 1/7）'), findsOneWidget);

      model.setVisible(false); // × hid the library
      await tester.pump(const Duration(seconds: 60));
      expect(asks(), n);
      model.setVisible(true);
      await tester.pump(const Duration(seconds: 30));
      expect(asks(), ++n);

      model.setTab(0); // 广场: no refreshing
      await tester.pump(const Duration(seconds: 60));
      expect(asks(), n);
      model.setTab(1); // coming back loads once
      await tester.pump();
      expect(asks(), ++n);

      status = 'review';
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(asks(), ++n);
      expect(find.text('审核中'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30)); // 审核中 is still in progress
      await tester.pump();
      expect(asks(), ++n);

      status = 'delivered';
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(asks(), ++n);
      expect(find.text('已完成'), findsOneWidget);
      await tester.pump(const Duration(seconds: 60));
      expect(asks(), n); // nothing in progress any more
    } finally {
      model.setTab(0);
    }
  });

  for (final (status, polls) in [('paid', true), ('review', true), ('delivered', false), ('failed', false)]) {
    testWidgets('a $status-only list ${polls ? 'keeps' : 'does not start'} the 30 s refresh', (tester) async {
      api.reply = (r) => r.url.path.endsWith('/requests')
          ? FakeHttp.ok([
              {'id': 5, 'name': '豆豆', 'species': 'cat', 'status': status},
            ])
          : FakeHttp.ok([]);
      await open(tester);
      await signIn(tester);
      try {
        model.setTab(1);
        await tester.pump();
        await tester.pump();
        final n = api.to('/api/aipet/custom/requests').length;
        await tester.pump(const Duration(seconds: 30));
        expect(api.to('/api/aipet/custom/requests').length, polls ? n + 1 : n);
      } finally {
        model.setTab(0);
      }
    });
  }

  testWidgets('a delivered pet this computer lacks asks the pet window to fetch it', (tester) async {
    api.reply = (r) => r.url.path.endsWith('/requests')
        ? FakeHttp.ok([
            {'id': 9, 'name': '豆豆', 'species': 'cat', 'status': 'delivered', 'pet_id': 'custom-9'},
          ])
        : FakeHttp.ok([]);
    await open(tester);
    await signIn(tester);
    await tester.pump();
    await tester.pump();
    expect(refreshes, 1);
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-9', origin: 'custom', species: 'cat', name: '豆豆');
    await petSide.pushReady([const ReadyPet(petId: 'custom-9', name: '豆豆')]);
    await tester.pump();
    await tester.pump();
    expect(api.to('/api/aipet/custom/requests'), hasLength(2)); // reloaded when it arrived
    expect(refreshes, 1); // and nothing is missing now
  });

  testWidgets('signed out, 我的 shows no 我的定制 and asks the server nothing', (tester) async {
    await open(tester);
    model.setTab(1);
    await tester.pumpAndSettle();
    expect(find.text('我的定制'), findsNothing);
    expect(api.to('/api/aipet/custom/requests'), isEmpty);
  });

  testWidgets('我的 scrolls as a whole: many orders and no pets do not overflow', (tester) async {
    api.reply = (r) => FakeHttp.ok([
          for (var i = 1; i <= 50; i++) {'id': i, 'name': '宠物$i', 'species': 'dog', 'status': 'delivered'},
        ]);
    await open(tester);
    await signIn(tester);
    model.setTab(1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('宠物50').hitTestable(), findsNothing);
    final page = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('宠物50'), 300, scrollable: page);
    expect(find.text('宠物50'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('还没有领养小伙伴，去广场看看吧'), 300, scrollable: page);
    expect(find.text('退出程序'), findsOneWidget);
  });

  testWidgets('closing the plans unpaid asks the list again, and the unpaid order is not in it', (tester) async {
    api.reply = (r) =>
        formReply(r) ?? FakeHttp.ok(r.url.path == '/api/aipet/custom/requests'
            ? [{'id': 9, 'name': '豆豆', 'species': 'cat', 'status': 'draft'}]
            : []);
    await open(tester);
    await signIn(tester);
    await toPlans(tester);
    expect(find.text('选择宠物版本'), findsOneWidget);
    final asked = api.to('/api/aipet/custom/requests').length;
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(api.to('/api/aipet/custom/requests').length, greaterThan(asked));
    expect(model.customs, isEmpty);
  });

  testWidgets('我的定制 thumbnails decode at thumbnail size and rows build lazily', (tester) async {
    api.reply = (r) => r.url.path.endsWith('/requests')
        ? FakeHttp.ok([
            for (var i = 1; i <= 50; i++)
              {'id': i, 'name': '宠物$i', 'species': 'dog', 'status': 'delivered', 'cover_url': 'https://x/c$i.png'},
          ])
        : FakeHttp.ok([]);
    await open(tester);
    await signIn(tester);
    model.setTab(1);
    await tester.pump();
    await tester.pump();
    final img = tester.widgetList<Image>(find.descendant(of: find.byType(ListTile), matching: find.byType(Image))).first;
    expect(img.image, isA<ResizeImage>());
    expect((img.image as ResizeImage).width, 96);
    expect(find.text('宠物50'), findsNothing, reason: 'rows far down are not built');
  });

  testWidgets('form 下一步 goes on to the plans', (tester) async {
    api.reply = (r) => formReply(r) ?? FakeHttp.ok([]);
    await open(tester);
    await signIn(tester);
    await toPlans(tester);
    expect(find.text('选择宠物版本'), findsOneWidget);
    expect(find.text('已选 标准版'), findsOneWidget);
  });

  testWidgets('form → plans → pay → paid → submitted → back on 我的, list asked again', (tester) async {
    var status = 'pending';
    api.reply = (r) =>
        formReply(r) ??
        switch (r.url.path) {
          // delivered, not paid: a paid one would start the 30 s refresh
          '/api/aipet/custom/requests' => FakeHttp.ok([{'id': 9, 'name': '豆豆', 'species': 'cat', 'status': 'delivered'}]),
          '/api/aipet/custom/requests/9/order' =>
            FakeHttp.ok({'order_no': 'PX1', 'amount_cents': 3900, 'code_url': 'weixin://x', 'expires_in': 900}),
          _ => FakeHttp.ok({'status': status}),
        };
    await open(tester);
    await signIn(tester);
    await toPlans(tester);
    await tester.tap(find.text('创建宠物'));
    await tester.pumpAndSettle();
    expect(find.text('请使用微信扫码支付'), findsOneWidget);
    status = 'paid';
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('定制已提交'), findsOneWidget);
    final asked = api.to('/api/aipet/custom/requests').length;
    await tester.tap(find.text('查看我的定制'));
    await tester.pumpAndSettle();
    expect(find.text('定制已提交'), findsNothing);
    expect(find.text('选择宠物版本'), findsNothing);
    expect(model.tab, 1);
    expect(find.text('我的定制'), findsOneWidget);
    expect(api.to('/api/aipet/custom/requests').length, greaterThan(asked));
  });

  testWidgets('login expired on a custom page: back to 我的 with the reason', (tester) async {
    api.reply = (r) => r.url.path == '/api/aipet/custom/plans'
        ? FakeHttp.fail(1003, 'token invalid', null, 401)
        : formReply(r) ?? FakeHttp.ok([]);
    await open(tester);
    await signIn(tester);
    await toPlans(tester);
    expect(find.text('选择宠物版本'), findsNothing);
    expect(model.tab, 1);
    expect(find.text('登录已过期，请重新登录'), findsOneWidget);
    // The pet window was asked to sign out; 我的 is back to the sign-in form.
    expect(accountSide.calls, ['logout']);
    expect(model.account.signedIn, isFalse);
    expect(find.text('登录 / 注册'), findsOneWidget);
    expect(find.text('我的定制'), findsNothing);
    // No loop: nothing asked again on its own.
    final asked = api.sent.length;
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(api.sent.length, asked);
    expect(accountSide.calls, ['logout']);
  });

  test('several 1003s in a row: one message, one sign-out', () async {
    await model.start();
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await Future<void>.delayed(Duration.zero);
    final said = <String>[];
    model.addListener(() {
      final m = model.takeMessage();
      if (m != null) said.add(m);
    });
    model.loginExpired();
    model.loginExpired();
    model.loginExpired();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    model.loginExpired(); // signed out by now
    expect(said, ['登录已过期，请重新登录']);
    expect(accountSide.calls, ['logout']);
    expect(model.account.signedIn, isFalse);
  });

  test('a list that arrives after sign-out does not come back', () async {
    final reply = Completer<HttpReply>();
    api.reply = (_) => reply.future;
    await model.start();
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await Future<void>.delayed(Duration.zero); // the push starts a list request, held
    await petSide.pushAccount(AccountView.signedOut);
    await Future<void>.delayed(Duration.zero);
    reply.complete(FakeHttp.ok([
      {'id': 1, 'name': '小白', 'species': 'girl', 'status': 'pending_payment'},
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(model.customs, isEmpty);
  });

  test('an older list request cannot overwrite a newer one', () async {
    final first = Completer<HttpReply>();
    var n = 0;
    api.reply = (_) => ++n == 1
        ? first.future
        : FakeHttp.ok([
            {'id': 2, 'name': '豆豆', 'species': 'cat', 'status': 'generating'},
          ]);
    await model.start();
    await petSide.pushAccount(const AccountView(phoneMasked: '138****0000', name: 'n'));
    await Future<void>.delayed(Duration.zero);
    await model.loadCustoms();
    expect(model.customs.single.name, '豆豆');
    first.complete(FakeHttp.ok([
      {'id': 1, 'name': '小白', 'species': 'girl', 'status': 'pending_payment'},
    ]));
    await Future<void>.delayed(Duration.zero);
    expect(model.customs.single.name, '豆豆');
  });

  testWidgets('a custom pet finished downloading: 做好了, and 换它陪我 puts it on the desktop', (tester) async {
    adoptImpl = adoptingSucceeds();
    await open(tester);
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat', name: '豆豆');
    await petSide.pushReady([const ReadyPet(petId: 'custom-7', name: '豆豆')]);
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsOneWidget);
    expect(_plaza(model).map((p) => p.id), contains('custom-7')); // rescanned: in the plaza like the others
    await tester.tap(find.text('换它陪我'));
    await tester.pump();
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsNothing);
    expect(model.statusOf(_plaza(model).firstWhere((p) => p.id == 'custom-7')), CardStatus.companion);
  });

  testWidgets('pets that finished while the library was closed are announced when it opens', (tester) async {
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat', name: '豆豆');
    await petSide.pushReady([const ReadyPet(petId: 'custom-7', name: '豆豆')]); // nobody listening yet
    await open(tester);
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsOneWidget);
    await tester.tap(find.byTooltip('知道了'));
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsNothing);
  });

  testWidgets('the same pet arriving twice is announced once, even after it was dismissed', (tester) async {
    await open(tester);
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat', name: '豆豆');
    const ready = ReadyPet(petId: 'custom-7', name: '豆豆');
    await petSide.pushReady([ready]);
    await petSide.pushReady([ready]); // a resend
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsOneWidget);
    await tester.tap(find.byTooltip('知道了'));
    await tester.pump();
    await petSide.pushReady([ready]); // a late resend
    await tester.pump();
    expect(find.text('你的「豆豆」做好了'), findsNothing);
  });

  testWidgets('an announced pet arriving again after its folder reappears is listed, without a second banner',
      (tester) async {
    await open(tester);
    const ready = ReadyPet(petId: 'custom-7', name: '豆豆');
    await petSide.pushReady([ready]); // folder not there yet
    await tester.pump();
    await tester.tap(find.byTooltip('知道了'));
    await tester.pump();
    expect(_plaza(model).map((p) => p.id), isNot(contains('custom-7')));
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat', name: '豆豆');
    await petSide.pushReady([ready]);
    await tester.pump();
    expect(_plaza(model).map((p) => p.id), contains('custom-7'));
    expect(find.text('你的「豆豆」做好了'), findsNothing);
  });

  test('a push during startup and the same pet from takeReady show one banner', () async {
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat', name: '豆豆');
    const ready = ReadyPet(petId: 'custom-7', name: '豆豆');
    await petSide.pushReady([ready]); // held for takeReady
    var shown = 0;
    String? last;
    model.addListener(() {
      final r = model.readyPet?.petId;
      if (r != null && r != last) shown++;
      last = r;
    });
    final starting = model.start();
    await petSide.pushReady([ready]); // also live, while start is awaiting
    await starting;
    expect(model.readyPet, ready);
    expect(shown, 1);
  });

  group('paid characters', () {
    late _FakePaid paid;
    late FakeDownloads cards;
    late Directory appData;
    late PetWindowBridge paidSide;

    Map<String, Object?> item(String code, String name, String species, {String? card}) =>
        {'code': code, 'name': name, 'species': species, 'price_cents': 1990, 'card_url': card, 'tags': ['温柔']};

    final catalog = [item('suwan', '苏晚', 'girl'), item('guchen', '顾沉', 'boy'), item('xiaxia', '夏夏', 'girl')];

    setUp(() {
      appData = Directory('${tmp.path}\\appdata')..createSync();
      paid = _FakePaid({'xiaxia'});
      cards = FakeDownloads();
      paidSide = PetWindowBridge(petEnd,
          state: () => petState,
          onAdopt: (id) => adoptImpl(id),
          onMainWindowClosing: () async {},
          onQuit: () async {},
          account: accountSide,
          paid: paid)
        ..start();
      api.reply = (r) => r.url.path == '/api/aipet/characters' ? FakeHttp.ok(catalog) : FakeHttp.ok(null);
      model = MainWindowModel(
        library: PetLibrary(builtinRoot: Directory('${tmp.path}\\builtin'), customRoot: Directory('${tmp.path}\\custom')),
        bridge: MainWindowBridge(mainEnd,
            ackTimeout: const Duration(milliseconds: 50), adoptTimeout: const Duration(milliseconds: 200)),
        characters: CharacterService(ApiClient(api, baseUrl: 'https://x', token: () => 't')),
        catalogStore: CatalogStore(appData),
        cardTransport: cards,
      );
    });

    Future<void> people(WidgetTester tester) async {
      await open(tester);
      await tester.tap(find.text('人物'));
      await tester.pump();
    }

    void installPaid(String code, String name, {String species = 'girl'}) =>
        writePet(Directory('${tmp.path}\\custom'), id: 'paid-$code', origin: 'paid', species: species, name: name);

    testWidgets('the catalog failing with nothing cached: only the free characters, and no error', (tester) async {
      api.reply = (r) => throw const SocketException('offline');
      await people(tester);
      expect(find.text('小雅'), findsOneWidget);
      expect(find.text('苏晚'), findsNothing);
      expect(find.text('付费'), findsNothing);
      expect(find.textContaining('解锁'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(model.plazaPets.whereType<RemoteEntry>(), isEmpty);
    });

    testWidgets('the catalog failing with a cache: the cached characters, priced', (tester) async {
      CatalogStore(appData).save(paidCatalogFrom(catalog));
      api.reply = (r) => FakeHttp.fail(500, '服务器错误');
      await people(tester);
      expect(find.text('苏晚'), findsOneWidget);
      expect(find.text('顾沉'), findsOneWidget);
      expect(find.text('¥19.90 解锁'), findsNWidgets(2));
      expect(find.text('付费'), findsNWidgets(2));
      expect(find.text('已购'), findsOneWidget); // 夏夏, owned
      expect(find.text('下载'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('free characters first, then the catalog in its order; each in its own category', (tester) async {
      await people(tester);
      final names = [
        for (final e in model.plazaPets)
          switch (e) { InstalledEntry(:final pet) => pet.name, RemoteEntry(:final character) => character.name },
      ];
      expect(names, ['小雅', '苏晚', '顾沉', '夏夏']);
      await tester.tap(find.text('男生'));
      await tester.pump();
      expect(find.text('顾沉'), findsOneWidget);
      expect(find.text('苏晚'), findsNothing);
      await tester.tap(find.text('女生'));
      await tester.pump();
      expect(find.text('苏晚'), findsOneWidget);
      expect(find.text('顾沉'), findsNothing);
    });

    testWidgets('locked: 付费 and the price; 解锁 is left to the payment flow', (tester) async {
      await people(tester);
      expect(model.paidStateOf('suwan'), PaidState.locked);
      await tester.tap(find.text('¥19.90 解锁').first);
      await tester.pump();
      expect(paid.owned, {'xiaxia'});
    });

    testWidgets('owned: 已购 and 下载, which shows its progress and ends as 带TA回家', (tester) async {
      final hold = Completer<void>();
      paid.onDownload = (code) async {
        await paidSide.pushCharacterProgress(code, 5, 12);
        await hold.future;
        installPaid(code, '夏夏');
        return true;
      };
      await people(tester);
      expect(model.paidStateOf('xiaxia'), PaidState.owned);
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump();
      expect(find.text('下载中 42%'), findsOneWidget);
      final button = find.ancestor(of: find.text('下载中 42%'), matching: find.byType(FilledButton));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      hold.complete();
      await tester.pump();
      await tester.pump();
      expect(model.paidStateOf('xiaxia'), PaidState.installed);
      expect(find.text('带TA回家'), findsNWidgets(2)); // 小雅 and 夏夏
      expect(find.text('已购'), findsOneWidget);
      expect(find.text('下载'), findsNothing);
      expect(model.plazaPets[3], isA<InstalledEntry>());
    });

    testWidgets('a failed download says 下载失败，请重试 and offers 下载 again', (tester) async {
      paid.onDownload = (_) async => false;
      await people(tester);
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump();
      expect(find.text('下载失败，请重试'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(model.downloading, isEmpty);
    });

    testWidgets('installed but no longer owned is locked: never an adopt button', (tester) async {
      installPaid('suwan', '苏晚');
      await people(tester);
      expect(model.paidStateOf('suwan'), PaidState.locked);
      expect(model.plazaPets[1], isA<RemoteEntry>());
      expect(find.text('带TA回家'), findsOneWidget); // 小雅 only
      expect(find.text('¥19.90 解锁'), findsNWidgets(2));
    });

    testWidgets('what is owned follows the pet window', (tester) async {
      await people(tester);
      expect(find.text('已购'), findsOneWidget);
      await paidSide.pushOwned({'xiaxia', 'suwan'});
      await tester.pump();
      expect(find.text('已购'), findsNWidgets(2));
      await paidSide.pushOwned({});
      await tester.pump();
      expect(find.text('已购'), findsNothing);
      expect(find.text('付费'), findsNWidgets(3));
    });

    test('a fetched catalog is cached with its card photos', () async {
      api.reply = (r) => r.url.path == '/api/aipet/characters'
          ? FakeHttp.ok([item('suwan', '苏晚', 'girl', card: 'https://oss/suwan.jpg')])
          : FakeHttp.ok(null);
      cards.serve = (_) => kTinyPng;
      var changes = 0;
      model.addListener(() => changes++);
      await model.start();
      for (var i = 0; i < 50 && !CatalogStore(appData).cardFile('suwan').existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(CatalogStore(appData).load()!.items.single.code, 'suwan');
      expect(CatalogStore(appData).cardFile('suwan').existsSync(), isTrue);
      expect(cards.requested, ['https://oss/suwan.jpg']);
      expect(model.catalog.single.name, '苏晚');
      expect(changes, greaterThan(0));
      expect(File('${appData.path}\\catalog\\owned.json').existsSync(), isFalse, reason: "the pet window's file");
    });
  });
}

List<Pet> _plaza(MainWindowModel m) => [for (final e in m.plazaPets) if (e is InstalledEntry) e.pet];

class _FakePaid implements PaidHandler {
  _FakePaid(this.owned);

  @override
  Set<String> owned;

  Future<bool> Function(String code) onDownload = (_) async => false;

  @override
  Future<bool> download(String code) => onDownload(code);

  @override
  Future<void> refresh() async {}
}

class _KeptVoices implements VoiceHandler {
  _KeptVoices(this.map);

  final Map<String, String> map;

  @override
  VoiceChoices get choices => Map.of(map);

  @override
  void choose(String petId, String? voice) => map[petId] = voice ?? 'off';
}
