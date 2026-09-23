import 'dart:async';
import 'dart:io';

import 'package:aipet/app/pet_window/pet_window_controller.dart';
import 'package:flutter/foundation.dart';

class FakePlayer implements ClipPlayer {
  final plays = <String>[]; // "<petId>/<clip file name>|loop" or "|once"
  VoidCallback? lastOnFinished;
  Completer<void>? gate;

  @override
  Future<void> play(File aipmat, {required bool loop, VoidCallback? onFinished}) async {
    if (gate != null) await gate!.future;
    final parts = aipmat.path.split('\\');
    plays.add('${parts[parts.length - 2]}/${parts.last}|${loop ? 'loop' : 'once'}');
    lastOnFinished = onFinished;
  }

  @override
  Future<void> dispose() async {}
}
