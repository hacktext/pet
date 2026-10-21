import 'dart:ui';

import 'package:aipet/app/pet_window/click_through.dart';
import 'package:aipet/services/native_window.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 100 x 100 window; [at] is where the cursor is relative to it.
class _FakeWindow implements NativeWindow {
  Offset at = const Offset(50, 50);
  final through = <bool>[];

  @override
  Future<WindowCursor?> cursor() async => (cursor: at, size: const Size(100, 100));

  @override
  void setClickThrough(bool on) => through.add(on);

  @override
  void moveTo(Offset topLeft) {}

  @override
  void setRect(Rect rect) {}

  @override
  void showAt(Offset topLeft) {}
}

void main() {
  late _FakeWindow w;
  late List<String> log;
  late List<(double, double)> asked;
  var mirrored = false;
  var active = true;
  NativeWindow? window;

  // The pet: the left half of the square, x < 0.5.
  ClickThrough make() => ClickThrough(
        window: () => window,
        opaqueAt: (u, v) async {
          asked.add((u, v));
          return u < 0.5;
        },
        mirrored: () => mirrored,
        active: () => active,
        onEnter: () => log.add('enter'),
        onExit: () => log.add('exit'),
      );

  setUp(() {
    w = _FakeWindow();
    window = w;
    log = [];
    asked = [];
    mirrored = false;
    active = true;
  });

  test('on the pet the window takes the mouse; beside it the mouse passes through', () async {
    final c = make();
    w.at = const Offset(20, 50);
    await c.tick();
    expect(w.through, [false]);
    expect(log, ['enter']);
    expect(c.over, isTrue);
    w.at = const Offset(80, 50);
    await c.tick();
    expect(w.through, [false, true]);
    expect(log, ['enter', 'exit']);
    expect(c.over, isFalse);
    await c.tick(); // nothing changed: the window is not told again
    expect(w.through, [false, true]);
  });

  test('outside the window counts as off the pet, and is never asked about', () async {
    final c = make();
    w.at = const Offset(-5, 50);
    await c.tick();
    w.at = const Offset(50, 130);
    await c.tick();
    expect(asked, isEmpty);
    expect(w.through, [true]);
    expect(log, isEmpty);
  });

  test('a mirrored clip is asked about the point as drawn', () async {
    final c = make();
    mirrored = true;
    w.at = const Offset(80, 25); // drawn flipped: the pet is now on the right
    await c.tick();
    expect(asked.single.$1, closeTo(0.2, 1e-9));
    expect(asked.single.$2, closeTo(0.25, 1e-9));
    expect(c.over, isTrue);
  });

  test('while held (a drag, the menu) the whole window takes the mouse and polls wait', () async {
    final c = make();
    w.at = const Offset(80, 50);
    await c.tick();
    expect(w.through, [true]);
    c.hold();
    expect(w.through, [true, false]);
    await c.tick();
    expect(asked, hasLength(1), reason: 'no polling while held');
    c.release();
    await c.tick();
    expect(w.through, [true, false, true]);
  });

  test('a hidden pet is never under the cursor', () async {
    final c = make();
    w.at = const Offset(20, 50);
    await c.tick();
    active = false;
    await c.tick();
    expect(log, ['enter', 'exit']);
    expect(asked, hasLength(1));
  });

  test('until the window exists nothing happens; stop gives the mouse back', () async {
    window = null;
    final c = make();
    await c.tick();
    expect(log, isEmpty);
    window = w;
    w.at = const Offset(80, 50);
    await c.tick();
    c.stop();
    expect(w.through, [true, false]);
  });
}
