import 'dart:async';

/// When the panel is up (spec 2026-09-19 E 3.2): 300 ms over the pet shows
/// it, 600 ms off both the pet and the panel hides it, x hides it until the
/// pointer has left the pet, and walking or dragging (busy) hides it at once.
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
  bool _busy = false;
  bool _shown = false;
  Timer? _pending;

  bool get shown => _shown;
  bool get pointerOnPet => _inPet;

  void petEnter() {
    _inPet = true;
    _reconsider();
  }

  void petExit() {
    _inPet = false;
    _dismissed = false;
    _reconsider();
  }

  void hudEnter() {
    _inHud = true;
    _reconsider();
  }

  void hudExit() {
    _inHud = false;
    if (!_inPet) _dismissed = false;
    _reconsider();
  }

  void close() {
    _dismissed = true;
    _reconsider();
  }

  set busy(bool v) {
    if (v == _busy) return;
    _busy = v;
    _reconsider();
  }

  void _reconsider() {
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
        hide();
      } else {
        _pending = Timer(hideDelay, () {
          _pending = null;
          _shown = false;
          hide();
        });
      }
    }
  }

  void dispose() {
    _pending?.cancel();
    _pending = null;
  }
}
