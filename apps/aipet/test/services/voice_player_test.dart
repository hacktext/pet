import 'dart:async';
import 'dart:io';

import 'package:aipet/services/voice_player.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProcess implements Process {
  _FakeProcess(this.args);

  final List<String> args;
  bool killed = false;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => killed = true;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  late List<_FakeProcess> started;
  late List<Completer<Process>> pending;
  late AfplayVoicePlayer player;

  setUp(() {
    started = [];
    pending = [];
    player = AfplayVoicePlayer(start: (exe, args) {
      expect(exe, '/usr/bin/afplay');
      final p = _FakeProcess(args);
      started.add(p);
      final c = Completer<Process>();
      pending.add(c);
      return c.future;
    });
  });

  Future<void> startAll() async {
    for (var i = 0; i < pending.length; i++) {
      if (!pending[i].isCompleted) pending[i].complete(started[i]);
    }
    await Future<void>.delayed(Duration.zero);
  }

  test('macOS: a line plays through afplay', () async {
    player.play(File('/v/xiaoya/hi.wav'));
    await startAll();
    expect(started.single.args, [File('/v/xiaoya/hi.wav').absolute.path]);
    expect(started.single.killed, isFalse);
  });

  test('macOS: a new line cuts off the one still speaking', () async {
    player.play(File('/v/a.wav'));
    await startAll();
    player.play(File('/v/b.wav'));
    await startAll();
    expect(started[0].killed, isTrue);
    expect(started[1].killed, isFalse);
  });

  test('macOS: stop() also silences a line whose afplay is still starting', () async {
    player.play(File('/v/a.wav'));
    player.stop();
    await startAll();
    expect(started.single.killed, isTrue);
  });
}
