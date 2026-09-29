/// Which way an animal faces or walks.
enum Facing { left, right }

/// Walking speed across the desktop, logical pixels per second (spec
/// 2026-09-19 E 3.4; tune by eye against the clips' stride at acceptance).
const double kWalkSpeed = 90;

/// A walk starts toward the side with more room.
Facing roomierSide(double x, double minX, double maxX) => (x - minX) > (maxX - x) ? Facing.left : Facing.right;

/// One walk along [minX, maxX] (the window's left edge): turns at either end.
class Walker {
  Walker({
    required double x,
    required this.minX,
    required this.maxX,
    required Facing heading,
    required Duration length,
    this.speed = kWalkSpeed,
  })  : _x = x < minX ? minX : (x > maxX ? maxX : x),
        // ignore: prefer_initializing_formals
        _heading = heading,
        _left = length;

  final double minX;
  final double maxX;
  final double speed;
  double _x;
  Facing _heading;
  Duration _left;

  double get x => _x;
  Facing get heading => _heading;
  bool get done => _left <= Duration.zero;

  /// Moves for [dt] (never past the walk's time); returns false once it is over.
  bool step(Duration dt) {
    if (done) return false;
    final d = dt > _left ? _left : dt;
    _left -= d;
    if (maxX <= minX) return !done; // no room to walk: stand still
    var dist = speed * d.inMicroseconds / Duration.microsecondsPerSecond;
    while (dist > 0) {
      final room = _heading == Facing.right ? maxX - _x : _x - minX;
      if (dist <= room) {
        _x += _heading == Facing.right ? dist : -dist;
        dist = 0;
      } else {
        _x = _heading == Facing.right ? maxX : minX;
        dist -= room;
        _heading = _heading == Facing.right ? Facing.left : Facing.right;
      }
    }
    return !done;
  }
}
