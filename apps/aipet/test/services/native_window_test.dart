import 'package:aipet/services/native_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kNativeWindowChannel);
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return null;
    });
  });
  tearDown(() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('macOS: every call names the window and passes logical, top-left coordinates', () async {
    final w = MacWindow('aipet pet');
    w.moveTo(const Offset(100, 200.5));
    w.setRect(const Rect.fromLTWH(10, 20, 270, 270));
    w.showAt(const Offset(-30, 40));
    await Future<void>.delayed(Duration.zero);
    expect([for (final c in calls) c.method], ['moveTo', 'setRect', 'showAt']);
    expect(calls[0].arguments, {'title': 'aipet pet', 'x': 100.0, 'y': 200.5});
    expect(calls[1].arguments, {'title': 'aipet pet', 'x': 10.0, 'y': 20.0, 'width': 270.0, 'height': 270.0});
    expect(calls[2].arguments, {'title': 'aipet pet', 'x': -30.0, 'y': 40.0});
  });

  test('macOS: a failing runner is logged, never thrown into a walk', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async => throw PlatformException(code: 'no_window'));
    final w = MacWindow('aipet hud');
    w.moveTo(Offset.zero);
    w.moveTo(Offset.zero);
    await Future<void>.delayed(Duration.zero);
  });
}
