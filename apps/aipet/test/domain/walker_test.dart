import 'package:aipet/domain/walker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const s1 = Duration(seconds: 1);

  test('walks at the speed toward its heading', () {
    final w = Walker(x: 100, minX: 0, maxX: 1000, heading: Facing.right, length: const Duration(seconds: 5));
    expect(w.step(s1), isTrue);
    expect(w.x, closeTo(190, 1e-9));
    expect(w.heading, Facing.right);
  });

  test('turns at the end and walks back the rest of the way', () {
    // 90 px: 50 to reach 1000, then 40 back
    final w = Walker(x: 950, minX: 0, maxX: 1000, heading: Facing.right, length: const Duration(seconds: 5));
    w.step(s1);
    expect(w.x, closeTo(960, 1e-9));
    expect(w.heading, Facing.left);
  });

  test('stops when its time is up, using only the time left', () {
    final w = Walker(x: 100, minX: 0, maxX: 1000, heading: Facing.right, length: const Duration(milliseconds: 1500));
    expect(w.step(s1), isTrue);
    expect(w.step(s1), isFalse); // only 0.5 s left: 45 px
    expect(w.x, closeTo(235, 1e-9));
    expect(w.done, isTrue);
    expect(w.step(s1), isFalse);
    expect(w.x, closeTo(235, 1e-9));
  });

  test('no room: stays put instead of spinning', () {
    final w = Walker(x: 300, minX: 300, maxX: 300, heading: Facing.left, length: const Duration(seconds: 5));
    w.step(s1);
    expect(w.x, 300);
  });

  test('starts toward the roomier side', () {
    expect(roomierSide(100, 0, 1000), Facing.right);
    expect(roomierSide(900, 0, 1000), Facing.left);
  });
}
