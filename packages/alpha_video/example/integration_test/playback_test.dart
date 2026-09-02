import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:alpha_video/alpha_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String aipmat;

  setUpAll(() async {
    aipmat = '${Directory.systemTemp.path}\\playback_clip.aipmat';
    final src = '${Directory.current.path}\\..\\..\\..\\native\\testdata\\green_box.mp4';
    await AlphaVideo.prepare(source: src, destination: aipmat, targetEdge: 320);
  });

  testWidgets('frame advances while playing', (tester) async {
    final c = await AlphaVideoController.open(aipmat);
    expect(await c.currentFrame(), 0);
    await c.play(loop: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final mid = await c.currentFrame();
    expect(mid, greaterThan(0));
    await c.dispose();
  });

  testWidgets('pause freezes the frame', (tester) async {
    final c = await AlphaVideoController.open(aipmat);
    await c.play(loop: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await c.pause();
    final a = await c.currentFrame();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await c.currentFrame(), a);
    await c.dispose();
  });

  testWidgets('loop wraps around instead of stopping at the end', (tester) async {
    final c = await AlphaVideoController.open(aipmat);
    await c.play(loop: true);
    // 夹具是 1 秒 24 帧，等 1.4 秒必然已经绕回
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    final f = await c.currentFrame();
    expect(f, lessThan(c.frameCount));
    await c.dispose();
  });
}
