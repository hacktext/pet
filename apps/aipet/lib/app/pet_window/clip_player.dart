import 'dart:async';
import 'dart:io';

import 'package:alpha_video/alpha_video.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'pet_window_controller.dart';

/// ClipPlayer on alpha_video. Ported from pet_shell's switching code.
class AlphaClipPlayer implements ClipPlayer {
  final ValueNotifier<AlphaVideoController?> controller = ValueNotifier(null);
  Timer? _watch;

  @override
  Future<void> play(File aipmat, {required bool loop, VoidCallback? onFinished}) async {
    _watch?.cancel();
    final next = await AlphaVideoController.open(aipmat.path);
    final prev = controller.value;
    // Hold the new controller before play(): teardown must always be able to
    // find whatever open() created, even if play() throws.
    controller.value = next;
    // Let the frame that swaps the Texture land before the old texture is
    // unregistered. Bounded: a hidden window may not produce frames.
    await SchedulerBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 500), onTimeout: () {});
    await prev?.dispose();
    await next.play(loop: loop);
    if (!loop && onFinished != null) _watchEnd(next, onFinished);
  }

  // The plugin has no finished event and cannot replay (HANDOFF item 3): poll
  // the frame counter; a replay reopens the cache, which starts at frame 0.
  void _watchEnd(AlphaVideoController c, VoidCallback onFinished) {
    _watch = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      if (!identical(controller.value, c)) {
        t.cancel();
        return;
      }
      final int frame;
      try {
        frame = await c.currentFrame();
      } catch (_) {
        t.cancel();
        return;
      }
      if (t.isActive && frame >= c.frameCount - 1 && identical(controller.value, c)) {
        t.cancel();
        onFinished();
      }
    });
  }

  @override
  Future<void> dispose() async {
    _watch?.cancel();
    final c = controller.value;
    controller.value = null;
    await c?.dispose();
  }
}
