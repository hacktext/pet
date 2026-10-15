import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Plays one spoken line at a time; a new line cuts off the last one.
abstract interface class VoicePlayer {
  void play(File wav);
  void stop();
}

/// winmm's PlaySound: WAV only, asynchronous, one sound per process -- which
/// is exactly one line at a time. No plugin, nothing to bundle.
class WinmmVoicePlayer implements VoicePlayer {
  static const _sndAsync = 0x0001;
  static const _sndNoDefault = 0x0002; // a missing file stays silent, no system beep
  static const _sndFilename = 0x00020000;

  static final _playSound = DynamicLibrary.open('winmm.dll')
      .lookupFunction<Int32 Function(Pointer<Utf16>, IntPtr, Uint32), int Function(Pointer<Utf16>, int, int)>(
          'PlaySoundW');

  // The docs do not promise SND_ASYNC copies the file name before returning,
  // so the path stays allocated until the sound is replaced or stopped.
  Pointer<Utf16>? _path;

  @override
  void play(File wav) {
    final path = wav.absolute.path.toNativeUtf16();
    _playSound(path, 0, _sndAsync | _sndNoDefault | _sndFilename);
    _release();
    _path = path;
  }

  @override
  void stop() {
    _playSound(nullptr, 0, 0);
    _release();
  }

  void _release() {
    final p = _path;
    _path = null;
    if (p != null) malloc.free(p);
  }
}

/// The platform's player: winmm on Windows, afplay on macOS.
VoicePlayer platformVoicePlayer() => Platform.isMacOS ? AfplayVoicePlayer() : WinmmVoicePlayer();

/// macOS: /usr/bin/afplay, one process per line; a new line or stop() kills
/// the one still speaking. Ships with every macOS, so nothing to bundle.
class AfplayVoicePlayer implements VoicePlayer {
  AfplayVoicePlayer({Future<Process> Function(String exe, List<String> args)? start})
      : _start = start ?? ((exe, args) => Process.start(exe, args));

  final Future<Process> Function(String exe, List<String> args) _start;
  Process? _current;
  int _gen = 0;

  @override
  void play(File wav) {
    stop();
    final gen = _gen;
    _start('/usr/bin/afplay', [wav.absolute.path]).then((p) {
      // stop() or another line came while afplay was starting.
      if (gen != _gen) {
        p.kill();
      } else {
        _current = p;
      }
    }, onError: (Object _) {}); // a missing afplay stays silent, like SND_NODEFAULT
  }

  @override
  void stop() {
    _gen++;
    _current?.kill();
    _current = null;
  }
}
