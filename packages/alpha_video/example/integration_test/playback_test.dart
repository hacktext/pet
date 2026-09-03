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
    // currentFrame 永远满足 f < frameCount（推帧逻辑本身保证：atEnd ? 0 : next），
    // 所以单次快照断言 "f < frameCount" 对任何取值都成立，包括线程从未跑过
    // （恒为 0）或在最后一帧卡死（loop 失效）的情况——测不出 Task 10 的
    // 循环功能本身。改为连续采样，直接观察绕回：夹具是 1 秒 24 帧，一圈约
    // 1 秒；每 50ms 采一次样，共采 2.5 秒，应该能跨过至少一次绕回点。
    final c = await AlphaVideoController.open(aipmat);
    await c.play(loop: true);
    final samples = <int>[];
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      samples.add(await c.currentFrame());
    }
    await c.dispose();

    // 序列不能是常数——否则推帧线程根本没在跑，测试不应该在这种情况下通过。
    expect(samples.toSet().length, greaterThan(1),
        reason: '推帧线程似乎没有在推进帧：$samples');

    // 只有绕回那一刻，相邻两次采样才会严格下降（否则单调不减）。
    var wrapped = false;
    for (var i = 1; i < samples.length; i++) {
      if (samples[i] < samples[i - 1]) {
        wrapped = true;
        break;
      }
    }
    expect(wrapped, isTrue, reason: '采样序列里没有出现绕回（严格下降）：$samples');
  });
}
