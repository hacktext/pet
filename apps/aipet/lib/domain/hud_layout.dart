import 'dart:math' as math;
import 'dart:ui';

/// The panel window, logical pixels (spec 2026-09-19 E 3.1).
const Size kHudSize = Size(440, 250);

/// The panel overlaps the empty top of the pet window so it sits just above
/// the head; below the window it keeps a small gap.
const double kHudOverlap = 24;
const double kHudBelowGap = 6;

/// Top-left of the panel: centred over the pet, flipped below it when it
/// would leave the work area at the top, and kept inside left and right.
Offset hudPosition(Rect pet, Size hud, Rect work) {
  var y = pet.top + kHudOverlap - hud.height;
  if (y < work.top) y = math.min(pet.bottom + kHudBelowGap, work.bottom - hud.height);
  final x = (pet.center.dx - hud.width / 2).clamp(work.left, math.max(work.left, work.right - hud.width)).toDouble();
  return Offset(x, y);
}
