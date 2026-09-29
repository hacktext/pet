import 'dart:ui';

import 'package:aipet/services/hud_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';

const view = HudView(
  name: '体验版：金毛',
  cover: 'C:\\pets\\builtin-gold\\cover.png',
  status: '状态很好',
  companionDays: 3,
  todayInteractions: 7,
  intimacy: 57,
  satiety: 100,
  health: 100,
  enabled: {'stand', 'walk', 'feed'},
);

void main() {
  test('HudView survives the channel', () {
    expect(HudView.fromJson(Map<Object?, Object?>.from(view.toJson())), view);
  });

  test('show / update / hide reach the panel with the pet window rectangle', () async {
    final (petEnd, panelEnd) = FakeTransport.pair();
    final got = <String>[];
    HudWindowBridge(panelEnd,
        onShow: (r, v) async => got.add('show $r ${v.name}'),
        onUpdate: (v) => got.add('update ${v.todayInteractions}'),
        onHide: () async => got.add('hide')).start();
    final pet = PetHudBridge(petEnd, onAction: (_) {}, onClose: () {}, onHover: (_) {})..start();
    await pet.show(const Rect.fromLTWH(10, 20, 360, 360), view);
    await pet.update(view);
    await pet.hide();
    expect(got, ['show ${const Rect.fromLTWH(10, 20, 360, 360)} 体验版：金毛', 'update 7', 'hide']);
  });

  test("the panel's buttons, close and hover reach the pet window", () async {
    final (petEnd, panelEnd) = FakeTransport.pair();
    final got = <String>[];
    PetHudBridge(petEnd, onAction: (k) => got.add('action $k'), onClose: () => got.add('close'), onHover: (i) => got.add('hover $i'))
        .start();
    final panel = HudWindowBridge(panelEnd, onShow: (_, _) async {}, onUpdate: (_) {}, onHide: () async {})..start();
    panel.action('feed');
    panel.close();
    panel.hover(true);
    await Future<void>.delayed(Duration.zero);
    expect(got, ['action feed', 'close', 'hover true']);
  });

  test('no panel listening: the pet window carries on', () async {
    final (petEnd, _) = FakeTransport.pair();
    final pet = PetHudBridge(petEnd, onAction: (_) {}, onClose: () {}, onHover: (_) {});
    await expectLater(pet.show(Rect.zero, view), completes);
  });

  test('a hung panel does not hold the pet window up', () async {
    final (petEnd, panelEnd) = FakeTransport.pair();
    HudWindowBridge(panelEnd, onShow: (_, _) async {}, onUpdate: (_) {}, onHide: () async {}).start();
    panelEnd.silent = true;
    final pet = PetHudBridge(petEnd,
        onAction: (_) {}, onClose: () {}, onHover: (_) {}, timeout: const Duration(milliseconds: 50));
    await expectLater(pet.hide(), completes);
  });
}
