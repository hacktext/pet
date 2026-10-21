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
  buttons: kHudButtons,
  enabled: {'stand', 'walk', 'feed'},
);

void main() {
  late List<String> got;
  Future<void> pump(WidgetTester t, [HudView v = view]) async {
    got = [];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: HudPanel(view: v, onAction: (k) => got.add(k), onClose: () => got.add('close'))))));
  }

  HudView character(List<String> actions) => HudView(
        name: '小雅',
        cover: view.cover,
        status: view.status,
        companionDays: 1,
        todayInteractions: 0,
        intimacy: 50,
        satiety: 50,
        health: 100,
        buttons: actions,
        enabled: actions.toSet(),
      );

  testWidgets("a character's panel shows her own actions, and they play", (t) async {
    await pump(t, character(['stand', 'act_coy', 'dance', 'talk']));
    for (final s in ['站立', '撒娇', '跳舞', '说话']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    for (final s in ['行走', '喂食', '玩耍']) {
      expect(find.text(s), findsNothing, reason: s);
    }
    await t.tap(find.byKey(const Key('hud-button-dance')));
    await t.tap(find.byKey(const Key('hud-button-talk')));
    expect(got, ['dance', 'talk']);
  });

  testWidgets('no satiety (a character): 亲密度 and 健康度 only', (t) async {
    final c = character(['stand', 'act_coy']);
    await pump(
        t,
        HudView(
            name: c.name, cover: c.cover, status: c.status, companionDays: 1, todayInteractions: 0, intimacy: 50,
            satiety: null, health: 100, buttons: c.buttons, enabled: c.enabled));
    expect(find.text('亲密度'), findsOneWidget);
    expect(find.text('健康度'), findsOneWidget);
    expect(find.text('饱食度'), findsNothing);
    final back = HudView.fromJson(HudView(
            name: c.name, cover: c.cover, status: c.status, companionDays: 1, todayInteractions: 0, intimacy: 50,
            satiety: null, health: 100, buttons: c.buttons, enabled: c.enabled)
        .toJson());
    expect(back.satiety, isNull);
  });

  testWidgets("an animal's seven actions sit in a grid four wide, all of them tappable", (t) async {
    await pump(
        t,
        const HudView(
            name: '金毛', cover: '', status: '', companionDays: 1, todayInteractions: 0, intimacy: 50, satiety: 50,
            health: 100,
            buttons: ['stand', 'walk', 'feed', 'play', 'sleep', 'lick_paw', 'act_cute'],
            enabled: {'stand', 'walk', 'feed', 'play', 'sleep', 'lick_paw', 'act_cute'}));
    expect(t.takeException(), isNull); // no overflow
    for (final s in ['站立', '行走', '喂食', '玩耍', '睡觉', '舔爪子', '卖萌']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    final first = t.getTopLeft(find.byKey(const Key('hud-button-stand')));
    final fifth = t.getTopLeft(find.byKey(const Key('hud-button-sleep')));
    expect(fifth.dx, first.dx); // the fifth starts the second row
    expect(fifth.dy, greaterThan(first.dy));
    await t.tap(find.byKey(const Key('hud-button-act_cute')));
    expect(got, ['act_cute']);
  });

  testWidgets('an action with no label shows its key; past two rows the grid scrolls', (t) async {
    await pump(t, character(['stand', 'act_coy', 'dance', 'talk', 'wave', 'bow', 'a', 'b', 'c', 'd']));
    expect(find.text('wave'), findsOneWidget);
    expect(t.takeException(), isNull); // no overflow
    await t.drag(find.byKey(const Key('hud-buttons')), const Offset(0, -200));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('hud-button-d')));
    expect(got, ['d']);
    const c = HudView(
        name: '小雅', cover: '', status: '', companionDays: 1, todayInteractions: 0, intimacy: 50, satiety: 50,
        health: 100, buttons: ['stand', 'dance', 'talk'], enabled: {'stand', 'dance', 'talk'});
    expect(HudView.fromJson(Map<Object?, Object?>.from(c.toJson())), c);
  });

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
