import 'dart:io';

import 'package:aipet/services/voice_player.dart';

class FakeVoicePlayer implements VoicePlayer {
  final log = <String>[]; // "<voice folder>/<file name>" per play, "stop" per stop

  @override
  void play(File wav) {
    final parts = wav.path.split('\\');
    log.add('${parts[parts.length - 2]}/${parts.last}');
  }

  @override
  void stop() => log.add('stop');
}
