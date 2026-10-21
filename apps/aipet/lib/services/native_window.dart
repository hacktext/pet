import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'displays.dart';

/// A top-level window of this process, moved and shown WITHOUT taking focus.
/// window_manager on Windows cannot: show() always calls SetForegroundWindow
/// and setPosition() is SetWindowPos(HWND_TOP) without SWP_NOACTIVATE, which
/// would steal the user's focus on every walking frame and every hover
/// (spec 2026-09-19 E 3.1). Coordinates are logical pixels, origin top-left
/// of the primary display, on every platform.
abstract class NativeWindow {
  /// This process's top-level window titled [title], or null. Titles must be
  /// unique within the process -- this returns whichever window the OS
  /// enumerates first -- so the three engines use '桌遇' (the library), 'aipet pet' and
  /// 'aipet hud'.
  static NativeWindow? find(String title) {
    if (Platform.isWindows) return Win32Window.find(title);
    if (Platform.isMacOS) return MacWindow(title);
    return null;
  }

  /// Moves the window; no activation, no z-order change.
  void moveTo(Offset topLeft);

  /// Moves and resizes the window; no activation, no z-order change.
  void setRect(Rect rect);

  /// Shows the window at [topLeft], topmost, without activating it.
  void showAt(Offset topLeft);

  /// Where the cursor is relative to the window's top-left, and the window's
  /// size, both logical pixels (the cursor may lie outside); null if unknown.
  Future<WindowCursor?> cursor();

  /// With [on], clicks and hovers pass through the window to whatever is
  /// behind it, as if it were not there.
  void setClickThrough(bool on);
}

/// [NativeWindow.cursor]'s answer.
typedef WindowCursor = ({Offset cursor, Size size});

/// user32's SetWindowPos with SWP_NOACTIVATE, in physical pixels.
class Win32Window implements NativeWindow {
  Win32Window._(this._hwnd);

  final int _hwnd;

  static Win32Window? find(String title) {
    final text = title.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      var h = _findWindowEx(0, 0, nullptr, text);
      while (h != 0) {
        _getWindowThreadProcessId(h, pid);
        if (pid.value == _getCurrentProcessId()) return Win32Window._(h);
        h = _findWindowEx(0, h, nullptr, text);
      }
      return null;
    } finally {
      calloc.free(text);
      calloc.free(pid);
    }
  }

  // The BOOL results are dropped: a walk calls moveTo about 30 times a
  // second, and a handle that went stale would only fail the same way every
  // time.
  @override
  void moveTo(Offset topLeft) {
    final s = physicalScale();
    _setWindowPos(_hwnd, 0, (topLeft.dx * s).round(), (topLeft.dy * s).round(), 0, 0,
        _swpNoSize | _swpNoZOrder | _swpNoActivate);
  }

  @override
  void setRect(Rect rect) {
    final s = physicalScale();
    _setWindowPos(_hwnd, 0, (rect.left * s).round(), (rect.top * s).round(), (rect.width * s).round(),
        (rect.height * s).round(), _swpNoZOrder | _swpNoActivate);
  }

  @override
  void showAt(Offset topLeft) {
    final s = physicalScale();
    _setWindowPos(_hwnd, _hwndTopmost, (topLeft.dx * s).round(), (topLeft.dy * s).round(), 0, 0,
        _swpNoSize | _swpNoActivate | _swpShowWindow);
  }

  @override
  Future<WindowCursor?> cursor() async {
    final p = calloc<_Point>();
    final r = calloc<_Rect>();
    try {
      if (_getCursorPos(p) == 0 || _getWindowRect(_hwnd, r) == 0) return null;
      final s = physicalScale();
      return (
        cursor: Offset((p.ref.x - r.ref.left) / s, (p.ref.y - r.ref.top) / s),
        size: Size((r.ref.right - r.ref.left) / s, (r.ref.bottom - r.ref.top) / s),
      );
    } finally {
      calloc.free(p);
      calloc.free(r);
    }
  }

  /// WS_EX_TRANSPARENT only lets the mouse through a layered window, so both
  /// go on and off together -- what window_manager's setIgnoreMouseEvents
  /// does, which Flutter's transparent windows are known to survive.
  @override
  void setClickThrough(bool on) {
    final ex = _getWindowLongPtr(_hwnd, _gwlExStyle);
    final want = on ? ex | _wsExTransparent | _wsExLayered : ex & ~(_wsExTransparent | _wsExLayered);
    if (want != ex) _setWindowLongPtr(_hwnd, _gwlExStyle, want);
  }
}

/// The macOS runner's channel (MainFlutterWindow.swift registers it on every
/// engine): it finds the NSWindow by title, flips the y axis (AppKit's origin
/// is the bottom-left of the primary screen) and moves / orders it front
/// without activating the app.
const kNativeWindowChannel = 'aipet/native_window';

class MacWindow implements NativeWindow {
  MacWindow(this.title, {MethodChannel? channel}) : _channel = channel ?? const MethodChannel(kNativeWindowChannel);

  final String title;
  final MethodChannel _channel;
  bool _logged = false;

  @override
  void moveTo(Offset topLeft) => _send('moveTo', {'x': topLeft.dx, 'y': topLeft.dy});

  @override
  void setRect(Rect rect) =>
      _send('setRect', {'x': rect.left, 'y': rect.top, 'width': rect.width, 'height': rect.height});

  @override
  void showAt(Offset topLeft) => _send('showAt', {'x': topLeft.dx, 'y': topLeft.dy});

  @override
  Future<WindowCursor?> cursor() async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('cursor', {'title': title});
      if (m == null) return null;
      double n(String k) => (m[k]! as num).toDouble();
      return (cursor: Offset(n('x'), n('y')), size: Size(n('width'), n('height')));
    } catch (e) {
      _logOnce('cursor', e);
      return null;
    }
  }

  @override
  void setClickThrough(bool on) => _send('setIgnoresMouse', {'ignore': on});

  // Fire and forget, like SetWindowPos: a walk sends ~30 a second and must
  // not wait on each. A failure is logged once, not 30 times a second.
  void _send(String method, Map<String, Object> args) {
    unawaited(_channel.invokeMethod<void>(method, {'title': title, ...args}).catchError((Object e) {
      _logOnce(method, e);
    }));
  }

  void _logOnce(String method, Object e) {
    if (_logged) return;
    _logged = true;
    developer.log('$method "$title" failed: $e', name: 'aipet.native_window');
  }
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

final _getCursorPos =
    _user32.lookupFunction<Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>('GetCursorPos');
final _getWindowRect = _user32
    .lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>), int Function(int, Pointer<_Rect>)>('GetWindowRect');
final _getWindowLongPtr =
    _user32.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW');
final _setWindowLongPtr = _user32
    .lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr), int Function(int, int, int)>('SetWindowLongPtrW');

final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

final class _Rect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

const _gwlExStyle = -20;
const _wsExTransparent = 0x00000020;
const _wsExLayered = 0x00080000;
const _hwndTopmost = -1;
const _swpNoSize = 0x0001;
const _swpNoZOrder = 0x0004;
const _swpNoActivate = 0x0010;
const _swpShowWindow = 0x0040;
