import 'package:aipet/app/pet_window/pet_dragger.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_mover.dart';

/// The system cursor, logical pixels, and whether the primary button is held.
class FakePointer implements DragPointer {
  Offset at = const Offset(250, 650);
  bool down = true;

  @override
  Offset position() => at;

  @override
  bool primaryDown() => down;
}

void main() {
  const tick = Duration(milliseconds: 16);
  late FakeMover mover;
  late FakePointer pointer;
  late PetDragger d;

  setUp(() {
    mover = FakeMover(); // window at (100, 500), 360 x 360
    pointer = FakePointer();
    d = PetDragger(mover, pointer, tick: tick);
  });
  tearDown(() => d.dispose());

  testWidgets('the window follows the cursor, keeping the spot that was grabbed under it', (t) async {
    final done = d.drag();
    await t.pump();
    pointer.at = const Offset(400, 300);
    await t.pump(tick);
    expect(mover.rect.topLeft, const Offset(250, 150)); // grabbed at (150, 150) inside the window
    pointer.at = const Offset(410, 320);
    await t.pump(tick);
    expect(mover.rect.topLeft, const Offset(260, 170));
    pointer.down = false;
    await t.pump(tick);
    await done;
    expect(d.dragging, isFalse);
  });

  testWidgets('does not move while the cursor stands still', (t) async {
    final done = d.drag();
    await t.pump();
    await t.pump(tick);
    await t.pump(tick);
    expect(mover.moves, isEmpty);
    pointer.down = false;
    await t.pump(tick);
    await done;
  });

  testWidgets('ends when the button is released even if the pointer left the window', (t) async {
    final done = d.drag();
    await t.pump();
    pointer.at = const Offset(1500, 900);
    await t.pump(tick);
    pointer.down = false;
    await t.pump(tick);
    await done;
    final moves = mover.moves.length;
    pointer.at = const Offset(0, 0);
    await t.pump(tick * 3);
    expect(mover.moves.length, moves); // stopped following
  });

  testWidgets('a button already up when the drag begins ends it at once', (t) async {
    pointer.down = false;
    await d.drag();
    expect(d.dragging, isFalse);
    expect(mover.moves, isEmpty);
  });

  testWidgets('a second drag while one is running joins it instead of starting another', (t) async {
    final a = d.drag();
    final b = d.drag();
    await t.pump();
    pointer.down = false;
    await t.pump(tick);
    await a;
    await b;
    expect(d.dragging, isFalse);
  });
}
