import 'dart:async';
import 'dart:developer' as developer;

/// The quit sequence (退出, spec 3.3).
///
/// window_manager's destroy() only posts WM_QUIT; the engines and plugins are
/// then torn down natively over seconds, with both windows still on screen
/// (and taking clicks) unless they were hidden first. So: hide the windows,
/// then release what must go before the engine does (clips, tray icon), then
/// destroy. Everything before destroy shares one short [timeout], and a step
/// that fails only logs -- nothing may keep destroy from running.
class AppExit {
  AppExit({
    required this._hide,
    required this._release,
    required this._destroy,
    this.timeout = const Duration(seconds: 2),
  });

  /// Run together, first.
  final List<Future<void> Function()> _hide;

  /// Run together, once every [_hide] step is done.
  final List<Future<void> Function()> _release;

  /// Ends the process.
  final Future<void> Function() _destroy;
  final Duration timeout;
  bool _quitting = false;

  /// A second call while quitting does nothing.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await _beforeDestroy().timeout(timeout);
    } on TimeoutException {
      developer.log('quit: steps still running after $timeout, destroying anyway', name: 'aipet.pet_window');
    } finally {
      await _destroy();
    }
  }

  Future<void> _beforeDestroy() async {
    await Future.wait(_hide.map(_guarded));
    await Future.wait(_release.map(_guarded));
  }

  static Future<void> _guarded(Future<void> Function() step) async {
    try {
      await step();
    } catch (e) {
      developer.log('quit step failed: $e', name: 'aipet.pet_window');
    }
  }
}
