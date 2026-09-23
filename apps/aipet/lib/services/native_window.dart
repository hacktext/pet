import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// A top-level window of this process, moved and shown WITHOUT taking focus.
/// window_manager on Windows cannot: show() always calls SetForegroundWindow
/// and setPosition() is SetWindowPos(HWND_TOP) without SWP_NOACTIVATE, which
/// would steal the user's focus on every walking frame and every hover
/// (spec 2026-09-19 E 3.1). Coordinates are physical pixels.
class NativeWindow {
  NativeWindow._(this._hwnd);

  final int _hwnd;

  /// This process's top-level window titled [title], or null.
  static NativeWindow? find(String title) {
    if (!Platform.isWindows) return null;
    final text = title.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      var h = _findWindowEx(0, 0, nullptr, text);
      while (h != 0) {
        _getWindowThreadProcessId(h, pid);
        if (pid.value == _getCurrentProcessId()) return NativeWindow._(h);
        h = _findWindowEx(0, h, nullptr, text);
      }
      return null;
    } finally {
      calloc.free(text);
      calloc.free(pid);
    }
  }

  /// Moves the window; no activation, no z-order change.
  void moveTo(int x, int y) => _setWindowPos(_hwnd, 0, x, y, 0, 0, _swpNoSize | _swpNoZOrder | _swpNoActivate);

  /// Shows the window at (x, y), topmost, without activating it.
  void showAt(int x, int y) =>
      _setWindowPos(_hwnd, _hwndTopmost, x, y, 0, 0, _swpNoSize | _swpNoActivate | _swpShowWindow);
}

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _findWindowEx = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _getWindowThreadProcessId = _user32
    .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _getCurrentProcessId = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
final _setWindowPos = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int)>('SetWindowPos');

const _hwndTopmost = -1;
const _swpNoSize = 0x0001;
const _swpNoZOrder = 0x0004;
const _swpNoActivate = 0x0010;
const _swpShowWindow = 0x0040;
