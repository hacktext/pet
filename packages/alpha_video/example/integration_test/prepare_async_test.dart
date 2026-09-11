import 'dart:async';
import 'dart:io';

import 'package:alpha_video/alpha_video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final src = '${Directory.current.path}\\..\\..\\..\\native\\testdata\\green_box_long.mp4';
  String tmp(String name) =>
      '${Directory.systemTemp.path}\\${name}_${DateTime.now().microsecondsSinceEpoch}.aipmat';

  // Flutter 3.47 on Windows runs the UI isolate on the platform thread, so a
  // blocking prepare freezes Dart itself: timers stop firing. Count timer
  // ticks while prepare runs -- a frozen Dart is what the user sees as a
  // frozen pet.
  testWidgets('Dart keeps running while prepare runs', (tester) async {
    var ticks = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 20), (_) => ticks++);
    final total = Stopwatch()..start();
    await AlphaVideo.prepare(source: src, destination: tmp('async'), targetEdge: 720);
    total.stop();
    timer.cancel();
    expect(total.elapsedMilliseconds, greaterThan(400),
        reason: 'fixture too fast to tell blocking from async (${total.elapsedMilliseconds} ms)');
    final expected = total.elapsedMilliseconds ~/ 20;
    expect(ticks, greaterThan(expected ~/ 4),
        reason: 'only $ticks of ~$expected timer ticks fired during a ${total.elapsedMilliseconds} ms prepare');
  });

  testWidgets('two prepares of one destination both succeed', (tester) async {
    final dst = tmp('merge');
    final r = await Future.wait([
      AlphaVideo.prepare(source: src, destination: dst, targetEdge: 320),
      AlphaVideo.prepare(source: src, destination: dst, targetEdge: 320),
    ]);
    expect(r, [0, 0]);
    expect(File(dst).existsSync(), isTrue);
  });

  testWidgets('a missing source still fails with prepare_failed', (tester) async {
    await expectLater(
      AlphaVideo.prepare(source: 'C:\\nope\\missing.mp4', destination: tmp('missing')),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'prepare_failed')),
    );
  });
}
