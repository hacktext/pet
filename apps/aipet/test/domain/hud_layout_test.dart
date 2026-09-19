import 'dart:ui';

import 'package:aipet/domain/hud_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const work = Rect.fromLTWH(0, 0, 1707, 1027);

  test('centred above the pet, overlapping the empty top of its window', () {
    // top 500 + 24 - 250 = 274; centre 1180 - 220 = 960
    expect(hudPosition(const Rect.fromLTWH(1000, 500, 360, 360), kHudSize, work), const Offset(960, 274));
  });

  test('flips below when there is no room above', () {
    // above would be 100 + 24 - 250 < 0 -> below: 460 + 6
    expect(hudPosition(const Rect.fromLTWH(1000, 100, 360, 360), kHudSize, work), const Offset(960, 466));
  });

  test('kept inside the work area left and right', () {
    expect(hudPosition(const Rect.fromLTWH(1500, 500, 360, 360), kHudSize, work).dx, 1707 - 440);
    expect(hudPosition(const Rect.fromLTWH(-100, 500, 360, 360), kHudSize, work).dx, 0);
  });

  test('flipped below but kept above the bottom of a short work area', () {
    expect(hudPosition(const Rect.fromLTWH(1000, 100, 360, 360), kHudSize, const Rect.fromLTWH(0, 0, 1707, 500)).dy, 250);
  });
}
