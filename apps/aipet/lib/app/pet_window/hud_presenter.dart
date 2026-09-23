import 'dart:async';

/// When the panel is up (spec 2026-09-19 E 3.2): 300 ms over the pet shows
/// it, 600 ms off both the pet and the panel hides it. x hides the panel; if
/// the pointer was on the pet when x was pressed it stays hidden until the
/// pointer leaves the pet, otherwise the next time the pointer enters the pet
/// it shows again. Walking or dragging (busy) hides it at once.
class HudPresenter {
  HudPresenter({
    required this.show,
    required this.hide,
    this.showDelay = const Duration(milliseconds: 300),
    this.hideDelay = const Duration(milliseconds: 600),
  });

  final void Function() show;
  final void Function() hide;
  final Duration showDelay;
  final Duration hideDelay;

  bool _inPet = false;
  bool _inHud = false;
  bool _dismissed = false;
  bool _dismissedOnPet = false;
  bool _busy = false;
  bool _shown = false;

  /// Disposed -- the panel is off the screen for good and nothing here may
  /// ask for it again.
  bool _done = false;
  Timer? _pending;

  bool get shown => _shown;
  bool get pointerOnPet => _inPet;

  void petEnter() {
    _inPet = true;
    if (!_dismissedOnPet) _dismissed = false;
    _reconsider();
  }

  void petExit() {
    _inPet = false;
    _dismissed = false;
    _dismissedOnPet = false;
    _reconsider();
  }

  void hudEnter() {
    _inHud = true;
    _reconsider();
  }

  void hudExit() {
    _inHud = false;
    if (!_inPet) {
      _dismissed = false;
      _dismissedOnPet = false;
    }
    _reconsider();
  }

  void close() {
    _dismissed = true;
    _dismissedOnPet = _inPet;
    _reconsider();
  }

  set busy(bool v) {
    if (v == _busy) return;
    _busy = v;
    _reconsider();
  }

  void _reconsider() {
    // Pointer events go on arriving after dispose(): quitting hides the pet
    // window, which fires a leave, and the pointer keeps crossing it for the
    // seconds the native teardown takes. None of that may bring the panel
    // back, and this must not depend on the owner guarding its own callbacks.
    if (_done) return;
    _pending?.cancel();
    _pending = null;
    final want = !_busy && !_dismissed && (_inPet || (_shown && _inHud));
    if (want && !_shown) {
      _pending = Timer(showDelay, () {
        _pending = null;
        _shown = true;
        show();
      });
    } else if (!want && _shown) {
      if (_busy || _dismissed) {
        _shown = false;
        // A hidden panel cannot hold the pointer: the window may never
        // deliver a mouse-leave once it is gone, so the flag would otherwise
        // stay stuck true and block a later hide.
        _inHud = false;
        hide();
      } else {
        _pending = Timer(hideDelay, () {
          _pending = null;
          _shown = false;
          _inHud = false;
          hide();
        });
      }
    }
  }

  /// For good: after this the panel counts as down and every event is
  /// ignored. Taking it off the screen is the owner's business -- it has a
  /// hide of its own to await -- so this only drops the pending timer and
  /// records that nothing is up.
  void dispose() {
    _done = true;
    _pending?.cancel();
    _pending = null;
    _shown = false;
  }
}
