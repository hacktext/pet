import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/displays.dart';
import 'window_mover.dart';

/// The system cursor and the primary mouse button; faked in tests.
abstract class DragPointer {
  /// Cursor position on the screen, logical pixels.
  Offset position();

  /// Whether the primary button is held right now (asked of the OS, so it is
  /// right even after the pointer has left the window).
  bool primaryDown();
}

/// Drags the pet window until the primary button is released; the future
/// completes when the drag ends.
abstract interface class WindowDragger {
  Future<void> drag();
}

/// The platform's dragger: macOS hands the drag to AppKit, which moves the
/// window itself, live; Windows follows the cursor (see PetDragger).
WindowDragger platformDragger(WindowMover mover) =>
    Platform.isMacOS ? AppKitDragger() : PetDragger(mover, SystemDragPointer());

/// window_manager's startDragging(): on macOS that is NSWindow.performDrag,
/// which tracks the mouse itself and returns once the button is up.
class AppKitDragger implements WindowDragger {
  @override
  Future<void> drag() => windowManager.startDragging();
}

/// Drags the pet window by following the system cursor.
///
/// Not window_manager's startDragging(): that hands the move to Windows'
/// SC_MOVE loop, which only moves the window live when "show window contents
/// while dragging" is on. With it off -- the default in Remote Desktop
/// sessions -- Windows draws a black outline rectangle the size of the window
/// and moves the pet only on release (user report 2026-10-09). Following the
/// cursor ourselves moves the pet itself under every setting.
///
/// The cursor is polled from the OS rather than read from pointer events: a
/// quick flick leaves the window before the next move, and the window would
/// stop receiving the events that should bring it along.
class PetDragger implements WindowDragger {
  PetDragger(this._mover, this._pointer, {this.tick = const Duration(milliseconds: 16)});

  final WindowMover _mover;
  final DragPointer _pointer;
  final Duration tick;

  Timer? _timer;
  Completer<void>? _done;

  bool get dragging => _done != null;

  /// Follows the cursor until the primary button is released. A call while a
  /// drag is running returns that drag's future.
  @override
  Future<void> drag() async {
    final running = _done;
    if (running != null) return running.future;
    final done = _done = Completer<void>();

    final window = await _mover.bounds();
    final grab = _pointer.position() - window.topLeft;
    var last = _pointer.position();

    void finish() {
      _timer?.cancel();
      _timer = null;
      _done = null;
      if (!done.isCompleted) done.complete();
    }

    if (!_pointer.primaryDown()) {
      finish();
      return done.future;
    }

    _timer = Timer.periodic(tick, (_) {
      if (!_pointer.primaryDown()) {
        finish();
        return;
      }
      final at = _pointer.position();
      if (at == last) return;
      last = at;
      _mover.moveTo(at - grab);
    });
    return done.future;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    final done = _done;
    _done = null;
    if (done != null && !done.isCompleted) done.complete();
  }
}

/// The real cursor: GetCursorPos (physical pixels) and GetAsyncKeyState on
/// whichever physical button is primary (SM_SWAPBUTTON for left-handed setups).
class SystemDragPointer implements DragPointer {
  @override
  Offset position() {
    if (!Platform.isWindows) return Offset.zero;
    final p = calloc<_Point>();
    try {
      _getCursorPos(p);
      final s = physicalScale();
      return Offset(p.ref.x / s, p.ref.y / s);
    } finally {
      calloc.free(p);
    }
  }

  @override
  bool primaryDown() {
    if (!Platform.isWindows) return false;
    final key = _getSystemMetrics(_smSwapButton) != 0 ? _vkRButton : _vkLButton;
    return _getAsyncKeyState(key) & 0x8000 != 0;
  }
}

final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

final _user32 = DynamicLibrary.open('user32.dll');
final _getCursorPos = _user32.lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>('GetCursorPos');
final _getAsyncKeyState = _user32.lookupFunction<Int16 Function(Int32), int Function(int)>('GetAsyncKeyState');
final _getSystemMetrics = _user32.lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');

const _vkLButton = 0x01;
const _vkRButton = 0x02;
const _smSwapButton = 23;
