import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:alpha_video/alpha_video.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('abiVersion returns 1 from native', (tester) async {
    expect(await AlphaVideo.abiVersion(), 1);
  });
}
