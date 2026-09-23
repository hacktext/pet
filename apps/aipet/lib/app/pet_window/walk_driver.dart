import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../domain/walker.dart';
import 'window_mover.dart';

/// A stalled frame or a laptop resume must make the walk slower, never a
/// teleport: the pet advances at most this much per tick.
const Duration _maxStep = Duration(milliseconds: 100);

/// One walk across the desktop (spec 2026-09-19 E 3.4): the window follows a
/// Walker about 30 times a second at its current height. [mirrored] tells the
/// view to flip the walk clip when it walks against the clip's facing.
class WalkDriver extends ChangeNotifier {
  WalkDriver(
    this._mover, {
    required this.facing,
    DateTime Function()? clock,
    this.frame = const Duration(milliseconds: 33),
    this.speed = kWalkSpeed,
  }) : _clock = clock ?? DateTime.now;

  final WindowMover _mover;

  /// The current pet's walk clip facing (pet.json walkFacing).
  final Facing Function() facing;
  final DateTime Function() _clock;
  final Duration frame;
  final double speed;

  Walker? _walker;
  Timer? _timer;
  Completer<bool>? _done;
  int _gen = 0;

  bool get walking => _walker != null;

  bool get mirrored {
    final w = _walker;
    return w != null && w.heading != facing();
  }

  /// Walks for [length]. Completes true when the time is up; false when it
  /// could not start (no work area) or was stopped / replaced.
  Future<bool> walk(Duration length) async {
    stop();
    final gen = ++_gen;
    final b = await _mover.bounds();
    final work = await _mover.workArea(b);
    if (gen != _gen || work == null) return false;
    final minX = work.left;
    final maxX = work.right - b.width;
    final w = Walker(
        x: b.left, minX: minX, maxX: maxX, heading: roomierSide(b.left, minX, maxX), length: length, speed: speed);
    _walker = w;
    final done = _done = Completer<bool>();
    var last = _clock();
    var heading = w.heading;
    notifyListeners();
    _timer = Timer.periodic(frame, (_) {
      final now = _clock();
      final elapsed = now.difference(last);
      final more = w.step(elapsed > _maxStep ? _maxStep : elapsed);
      last = now;
      _mover.moveTo(Offset(w.x, b.top));
      if (w.heading != heading) {
        heading = w.heading;
        notifyListeners();
      }
      if (!more) _finish(true);
    });
    return done.future;
  }

  void stop() {
    _gen++;
    _finish(false);
  }

  void _finish(bool completed) {
    _timer?.cancel();
    _timer = null;
    if (_walker == null) return;
    _walker = null;
    final d = _done;
    _done = null;
    notifyListeners();
    d?.complete(completed);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
