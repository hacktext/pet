import 'dart:ui';

import 'package:aipet/app/pet_window/walk_driver.dart';
import 'package:aipet/domain/walker.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_mover.dart';

void main() {
  const frame = Duration(milliseconds: 33);
  late DateTime now;
  late FakeMover mover;
  late WalkDriver d;
  var facing = Facing.left;

  Future<void> run(WidgetTester t, Duration span) async {
    final end = now.add(span);
    while (now.isBefore(end)) {
      now = now.add(frame);
      await t.pump(frame);
    }
  }

  setUp(() {
    now = DateTime(2026, 9, 19);
    mover = FakeMover();
    facing = Facing.left;
    d = WalkDriver(mover, facing: () => facing, clock: () => now, frame: frame);
  });
  tearDown(() => d.dispose());

  testWidgets('walks toward the roomier side at the walking speed, mirrored when facing the other way', (t) async {
    final done = d.walk(const Duration(seconds: 2));
    await t.pump();
    expect(d.walking, isTrue);
    expect(d.mirrored, isTrue); // heading right, clip faces left
    await run(t, const Duration(seconds: 1)); // 31 frames of 33 ms = 1.023 s -> ~92 px
    expect(mover.moves.last.dx, closeTo(192, 3));
    expect(mover.moves.last.dy, 500);
    await run(t, const Duration(seconds: 2));
    expect(await done, isTrue);
    expect(d.walking, isFalse);
  });

  testWidgets('turns at the edge of the work area', (t) async {
    mover.work = const Rect.fromLTWH(0, 0, 500, 1027); // maxX 140; from 100: left has more room
    facing = Facing.right;
    final done = d.walk(const Duration(seconds: 3));
    await t.pump();
    expect(d.mirrored, isTrue); // heading left
    await run(t, const Duration(milliseconds: 1500)); // 46 frames = 1.518 s -> 136.6 px: 100 to 0, then 36.6 back
    expect(mover.moves.map((m) => m.dx).reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(3)); // within a frame of 0
    expect(mover.moves.last.dx, closeTo(36.6, 3));
    expect(d.mirrored, isFalse); // heading right now
    d.stop();
    expect(await done, isFalse);
  });

  testWidgets('stop ends it early; no more moves', (t) async {
    final done = d.walk(const Duration(seconds: 5));
    await run(t, const Duration(milliseconds: 500));
    d.stop();
    expect(await done, isFalse);
    final n = mover.moves.length;
    await run(t, const Duration(seconds: 1));
    expect(mover.moves, hasLength(n));
    expect(d.walking, isFalse);
  });

  testWidgets('no work area: does not start', (t) async {
    mover.work = null;
    expect(await d.walk(const Duration(seconds: 5)), isFalse);
    expect(mover.moves, isEmpty);
    expect(d.walking, isFalse);
  });

  testWidgets('a new walk ends the previous one', (t) async {
    final first = d.walk(const Duration(seconds: 5));
    await run(t, const Duration(milliseconds: 200));
    final second = d.walk(const Duration(seconds: 1));
    expect(await first, isFalse);
    await run(t, const Duration(milliseconds: 1200));
    expect(await second, isTrue);
  });
}
