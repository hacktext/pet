import 'dart:async';
import 'dart:developer' as developer;

import '../../services/native_window.dart';

/// The pet window is a square; the pet is not. Over the pet's own pixels the
/// window takes the mouse (drag, right-click, hover); everywhere else in the
/// square the mouse passes through to whatever is behind it, as if the
/// window were not there (user report 2026-10-21: the transparent square
/// blocked the buttons under it).
///
/// The cursor is polled rather than followed by events: a window letting the
/// mouse through gets none. For the same reason this, not the widget tree,
/// decides when the pointer is on the pet ([onEnter] / [onExit]).
class ClickThrough {
  ClickThrough({
    required this._window,
    required this._opaqueAt,
    required this._mirrored,
    required this._active,
    required this.onEnter,
    required this.onExit,
    this.every = const Duration(milliseconds: 50),
  });

  final NativeWindow? Function() _window;

  /// The frame on screen is opaque at (u, v), both 0..1 of the pet square
  /// from its top-left as the clip is drawn (before any mirroring); false
  /// with no clip.
  final Future<bool> Function(double u, double v) _opaqueAt;

  /// Walking the other way, the clip is drawn flipped left to right.
  final bool Function() _mirrored;

  /// False while the pet is hidden or not on the desktop: a hidden window
  /// still has a rectangle the cursor can be "in".
  final bool Function() _active;

  final void Function() onEnter;
  final void Function() onExit;
  final Duration every;

  Timer? _timer;
  bool _busy = false;
  bool _over = false;
  bool? _through; // what the window was last told; null: not yet
  int _holds = 0;
  bool _logged = false;

  /// Whether the pointer is on the pet right now.
  bool get over => _over;

  void start() => _timer ??= Timer.periodic(every, (_) => unawaited(tick()));

  /// Stops polling and leaves the window taking the mouse, as it was.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _set(false);
    _leave();
  }

  /// While held -- a drag, the right-click menu -- the whole window takes the
  /// mouse, wherever the pointer is: the menu is drawn inside the window, and
  /// a drag must not drop the pet when the cursor slips off an arm.
  void hold() {
    _holds++;
    _set(false);
  }

  void release() {
    if (_holds > 0) _holds--;
  }

  /// One poll; the timer calls it, tests call it directly.
  Future<void> tick() async {
    if (_busy || _holds > 0) return;
    if (!_active()) return _leave();
    final w = _window();
    if (w == null) return;
    _busy = true;
    try {
      final c = await w.cursor();
      if (c == null || _holds > 0) return;
      final u = c.cursor.dx / c.size.width, v = c.cursor.dy / c.size.height;
      final inside = u >= 0 && u < 1 && v >= 0 && v < 1;
      final onPet = inside && await _opaqueAt(_mirrored() ? 1 - u : u, v);
      if (_holds > 0 || !_active()) return; // a drag or the menu began meanwhile, or the pet went
      if (onPet) {
        if (!_over) {
          _over = true;
          onEnter();
        }
      } else {
        _leave();
      }
      _set(!onPet);
    } catch (e) {
      if (!_logged) {
        _logged = true; // once: this runs 20 times a second
        developer.log('click-through poll failed: $e', name: 'aipet.pet_window');
      }
    } finally {
      _busy = false;
    }
  }

  void _leave() {
    if (!_over) return;
    _over = false;
    onExit();
  }

  void _set(bool through) {
    if (_through == through) return;
    final w = _window();
    if (w == null) return;
    _through = through;
    w.setClickThrough(through);
  }
}

/// How far from the cursor still counts as on the pet, as a fraction of the
/// pet's width: about 4 px on a 360 px pet, so a thin strand of hair or a
/// tail tip is not a gap the mouse falls through.
const double kHitSlop = 0.012;
