import 'dart:developer' as developer;
import 'dart:ui';

import 'package:window_manager/window_manager.dart';

import '../../services/displays.dart';
import '../../services/native_window.dart';

/// Where the pet window is and how to move it; faked in tests.
abstract class WindowMover {
  /// The window, logical pixels.
  Future<Rect> bounds();

  /// Work area of the display holding [window], logical pixels; null if unknown.
  Future<Rect?> workArea(Rect window);

  /// Moves the window's top-left to [topLeft] (logical) without taking focus.
  void moveTo(Offset topLeft);
}

/// Moves the window titled [_title]. The lookup happens on the first move
/// that needs it and is retried on every move until it finds something: one
/// lookup at startup that came back null would leave walking silently moving
/// nothing for the rest of the run.
class DesktopWindowMover implements WindowMover {
  DesktopWindowMover(this._title);

  final String _title;
  NativeWindow? _native;
  bool _logged = false;

  @override
  Future<Rect> bounds() => windowManager.getBounds();

  @override
  Future<Rect?> workArea(Rect window) => displayWorkArea(window);

  @override
  void moveTo(Offset topLeft) {
    final w = _native ??= NativeWindow.find(_title);
    if (w == null) {
      if (!_logged) {
        _logged = true; // once: a walk asks ~30 times a second
        developer.log('no window titled "$_title"; not moving', name: 'aipet.pet_window');
      }
      return;
    }
    final s = physicalScale();
    w.moveTo((topLeft.dx * s).round(), (topLeft.dy * s).round());
  }
}
