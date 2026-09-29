import 'dart:async';
import 'dart:io';

import 'package:aipet/app/main_window/main_window_app.dart';
import 'package:aipet/app/main_window/main_window_model.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';
import '../support/pet_fixtures.dart';

void main() {
  late Directory tmp;
  late LibraryState petState;
  late Future<void> Function(String) adoptImpl;
  late PetWindowBridge petSide;
  late MainWindowModel model;
  late FakeTransport petEnd;
  var quits = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mainwin_');
    final builtin = Directory('${tmp.path}\\builtin')..createSync();
    writePet(builtin, id: 'builtin-gold', name: '金毛');
    writePet(builtin, id: 'builtin-ragdoll', species: 'cat', name: '布偶猫');
    final (pe, mainEnd) = FakeTransport.pair();
    petEnd = pe;
    petState = LibraryState.empty;
    quits = 0;
    adoptImpl = (id) async {};
    petSide = PetWindowBridge(petEnd,
        state: () => petState,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async {},
        onQuit: () async => quits++)
      ..start();
    model = MainWindowModel(
      library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
      // Both timeouts short: a pending 60 s Timer fails a widget test at teardown.
      bridge: MainWindowBridge(mainEnd,
          ackTimeout: const Duration(milliseconds: 50), adoptTimeout: const Duration(milliseconds: 200)),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 740);
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

  testWidgets('plaza: banner, categories and one adoptable card per pet', (tester) async {
    await open(tester);
    expect(find.text('定制专属宠物'), findsOneWidget);
    expect(find.text('上传您的爱宠照片，生成桌面伙伴'), findsOneWidget);
    for (final label in ['全部', '狗狗', '猫猫', '其他小宠', '宠物广场', '我的']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('金毛'), findsOneWidget);
    expect(find.text('布偶猫'), findsOneWidget);
    expect(find.text('带它回家'), findsNWidgets(2));
  });

  testWidgets('category chips filter the grid', (tester) async {
    await open(tester);
    await tester.tap(find.text('猫猫'));
    await tester.pump();
    expect(find.text('布偶猫'), findsOneWidget);
    expect(find.text('金毛'), findsNothing);
    await tester.tap(find.text('其他小宠'));
    await tester.pump();
    expect(find.text('这里还没有小伙伴'), findsOneWidget);
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

  testWidgets('立即定制 is not open yet', (tester) async {
    await open(tester);
    await tester.tap(find.text('立即定制'));
    await tester.pumpAndSettle();
    expect(find.text('即将开放，敬请期待'), findsOneWidget);
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
    expect(model.statusOf(model.plazaPets.firstWhere((p) => p.id == 'builtin-gold')), CardStatus.companion);
  });
}
