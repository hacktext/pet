import 'package:aipet/app/hud_window/hud_panel.dart';
import 'package:aipet/app/hud_window/hud_window_entry.dart';
import 'package:aipet/services/hud_bridge.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';

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

/// The panel window's widget over its bridge (spec 2026-09-19 E 3.1);
/// runHudWindow itself needs a desktop (window_manager, FFI) and is not here.
void main() {
  late ValueNotifier<HudView?> shown;
  late List<String> got; // what arrived at the pet window

  Future<void> pump(WidgetTester t) async {
    final (petEnd, panelEnd) = FakeTransport.pair();
    got = [];
    PetHudBridge(petEnd,
            onAction: (k) => got.add('action $k'),
            onClose: () => got.add('close'),
            onHover: (inside) => got.add('hover $inside'))
        .start();
    shown = ValueNotifier<HudView?>(null);
    addTearDown(shown.dispose);
    final bridge = HudWindowBridge(panelEnd,
        onShow: (_, v) async => shown.value = v, onUpdate: (v) => shown.value = v, onHide: () async {})
      ..start();
    await t.pumpWidget(HudApp(view: shown, bridge: bridge));
  }

  testWidgets('nobody on the desktop: the panel draws nothing', (t) async {
    await pump(t);
    expect(find.byType(HudPanel), findsNothing);
    expect(find.textContaining('体验版'), findsNothing);
  });

  testWidgets('a view puts the panel on screen and a later one replaces it', (t) async {
    await pump(t);
    shown.value = view;
    await t.pump();
    expect(find.byType(HudPanel), findsOneWidget);
    expect(find.text('今日互动 7 次'), findsOneWidget);
    shown.value = const HudView(
      name: '体验版：柯基',
      cover: 'Z:\\missing\\cover.png',
      status: '有点饿了',
      companionDays: 1,
      todayInteractions: 0,
      intimacy: 50,
      satiety: 40,
      health: 100,
      buttons: kHudButtons,
      enabled: {'stand'},
    );
    await t.pump();
    expect(find.text('体验版：柯基'), findsOneWidget);
    expect(find.text('今日互动 0 次'), findsOneWidget);
  });

  testWidgets('the pointer entering and leaving the panel is reported to the pet window', (t) async {
    await pump(t);
    shown.value = view;
    await t.pump();
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500)); // off the panel
    addTearDown(mouse.removePointer);
    await t.pump();
    expect(got, isEmpty);
    await mouse.moveTo(t.getCenter(find.byType(HudPanel)));
    await t.pump();
    await mouse.moveTo(const Offset(700, 500));
    await t.pump();
    expect(got, ['hover true', 'hover false']);
  });

  testWidgets('a button and the x reach the pet window', (t) async {
    await pump(t);
    shown.value = view;
    await t.pump();
    await t.tap(find.byKey(const Key('hud-button-feed')));
    await t.tap(find.byKey(const Key('hud-button-play'))); // the pet has no play: disabled
    await t.tap(find.byKey(const Key('hud-close')));
    await t.pump();
    expect(got, ['action feed', 'close']);
  });
}
