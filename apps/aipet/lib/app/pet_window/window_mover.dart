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

class DesktopWindowMover implements WindowMover {
  DesktopWindowMover(this._native);

  final NativeWindow? _native;

  @override
  Future<Rect> bounds() => windowManager.getBounds();

  @override
  Future<Rect?> workArea(Rect window) => displayWorkArea(window);

  @override
  void moveTo(Offset topLeft) {
    final s = physicalScale();
    _native?.moveTo((topLeft.dx * s).round(), (topLeft.dy * s).round());
  }
}
