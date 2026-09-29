import 'package:aipet/app/hud_window/hud_panel.dart';
import 'package:aipet/services/hud_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const view = HudView(
  name: '体验版：金毛',
  cover: 'Z:\\missing\\cover.png',
  status: '状态很好',
  companionDays: 3,
  todayInteractions: 7,
  intimacy: 57,
  satiety: 100,
  health: 100,
  enabled: {'stand', 'walk', 'feed'},
);

void main() {
  late List<String> got;
  Future<void> pump(WidgetTester t) async {
    got = [];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: HudPanel(view: view, onAction: (k) => got.add(k), onClose: () => got.add('close'))))));
  }

  testWidgets('shows the name, status, days, today and the three numbers', (t) async {
    await pump(t);
    for (final s in ['体验版：金毛', '状态很好', '陪伴 3 天', '今日互动 7 次', '亲密度', '饱食度', '健康度', '57%', '100%']) {
      expect(find.textContaining(s), findsWidgets, reason: s);
    }
  });

  testWidgets('a button sends its action; a missing action is disabled', (t) async {
    await pump(t);
    await t.tap(find.byKey(const Key('hud-button-feed')));
    await t.tap(find.byKey(const Key('hud-button-play')));
    await t.tap(find.byKey(const Key('hud-close')));
    expect(got, ['feed', 'close']);
  });

  testWidgets('labels read 站立 / 行走 / 喂食 / 玩耍', (t) async {
    await pump(t);
    for (final s in ['站立', '行走', '喂食', '玩耍']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
  });
}
