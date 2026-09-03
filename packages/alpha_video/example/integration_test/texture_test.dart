import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:alpha_video/alpha_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String aipmat;

  setUpAll(() async {
    aipmat = '${Directory.systemTemp.path}\\itest_clip.aipmat';
    final src = '${Directory.current.path}\\..\\..\\..\\native\\testdata\\green_box.mp4';
    expect(File(src).existsSync(), isTrue,
        reason: '先跑 native/testdata/make_fixtures.ps1');
    final code = await AlphaVideo.prepare(source: src, destination: aipmat, targetEdge: 320);
    expect(code, 0);
  });

  testWidgets('open registers a texture and reports media info', (tester) async {
    final c = await AlphaVideoController.open(aipmat);
    expect(c.textureId, greaterThanOrEqualTo(0));
    expect(c.width, 320);
    expect(c.height, 320);
    expect(c.frameCount, 24);
    await c.dispose();
  });

  testWidgets('opening a missing file throws', (tester) async {
    expect(() => AlphaVideoController.open('C:\\nope.aipmat'), throwsA(isA<PlatformException>()));
  });
}
