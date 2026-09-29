import 'package:aipet/app/pet_window/hud_presenter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> log;
  late HudPresenter p;
  const ms = Duration(milliseconds: 1);
  setUp(() {
    log = [];
    p = HudPresenter(show: () => log.add('show'), hide: () => log.add('hide'));
  });
  tearDown(() => p.dispose());

  testWidgets('hovering the pet shows the panel after 300 ms', (t) async {
    p.petEnter();
    await t.pump(ms * 299);
    expect(log, isEmpty);
    await t.pump(ms);
    expect(log, ['show']);
    expect(p.shown, isTrue);
  });

  testWidgets('a quick pass never shows it', (t) async {
    p.petEnter();
    await t.pump(ms * 200);
    p.petExit();
    await t.pump(const Duration(seconds: 1));
    expect(log, isEmpty);
  });

  testWidgets('leaving hides after 600 ms unless the pointer reaches the panel', (t) async {
    p.petEnter();
    await t.pump(ms * 300);
    p.petExit();
    await t.pump(ms * 400);
    p.hudEnter();
    await t.pump(const Duration(seconds: 1));
    expect(log, ['show']);
    p.hudExit();
    await t.pump(ms * 599);
    expect(log, ['show']);
    await t.pump(ms);
    expect(log, ['show', 'hide']);
  });

  testWidgets('x hides at once and keeps it hidden until the pointer leaves the pet', (t) async {
    p.petEnter();
    await t.pump(ms * 300);
    p.hudEnter();
    p.close();
    expect(log, ['show', 'hide']);
    p.hudExit(); // still over the pet
    await t.pump(const Duration(seconds: 1));
    expect(log, ['show', 'hide']);
    p.petExit();
    p.petEnter();
    await t.pump(ms * 300);
    expect(log, ['show', 'hide', 'show']);
  });

  testWidgets('busy hides at once and blocks it; idle again while hovering shows it', (t) async {
    p.petEnter();
    await t.pump(ms * 300);
    p.busy = true;
    expect(log, ['show', 'hide']);
    await t.pump(const Duration(seconds: 1));
    expect(log, ['show', 'hide']);
    p.busy = false;
    await t.pump(ms * 300);
    expect(log, ['show', 'hide', 'show']);
  });

  testWidgets('a hidden panel drops the hover, so leaving the pet still hides it later', (t) async {
    p.petEnter();
    await t.pump(ms * 300);
    expect(log, ['show']);
    p.hudEnter(); // the pointer moves onto the panel; the window may never see it leave once hidden
    p.busy = true; // hides at once, without a hudExit ever arriving
    expect(log, ['show', 'hide']);
    p.busy = false;
    p.petEnter();
    await t.pump(ms * 300);
    expect(log, ['show', 'hide', 'show']);
    p.petExit();
    await t.pump(ms * 600);
    expect(log, ['show', 'hide', 'show', 'hide']);
  });

  testWidgets('x on the panel then straight back to the pet shows it again, whichever event lands first', (t) async {
    for (final hudExitFirst in [true, false]) {
      log.clear();
      p.dispose();
      p = HudPresenter(show: () => log.add('show'), hide: () => log.add('hide'));
      p.petEnter();
      await t.pump(ms * 300);
      p.hudEnter();
      p.petExit();
      p.close();
      expect(log, ['show', 'hide']);
      if (hudExitFirst) {
        p.hudExit();
        p.petEnter();
      } else {
        p.petEnter();
        p.hudExit();
      }
      await t.pump(ms * 300);
      expect(log, ['show', 'hide', 'show'], reason: 'hudExitFirst=$hudExitFirst');
    }
  });

  testWidgets('dispose() is final: nothing asks for the panel again', (t) async {
    p.petEnter();
    await t.pump(ms * 300);
    expect(log, ['show']);
    p.dispose();
    expect(p.shown, isFalse, reason: 'the panel is on its way off the screen, so it is not up any more');
    p.petExit();
    await t.pump(const Duration(seconds: 1));
    p.petEnter();
    await t.pump(const Duration(seconds: 1));
    expect(log, ['show'], reason: 'the pointer still crosses the pet while the engine is torn down');
    expect(p.shown, isFalse);
  });
}
