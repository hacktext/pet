import 'dart:io';

import 'package:aipet/services/autostart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('autostart_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('off by default: a first run does not want it', () {
    expect(Autostart(root).wanted, isFalse);
  });

  test('an unreadable choice counts as never made', () {
    Autostart(root).file.writeAsStringSync('{nope');
    expect(Autostart(root).wanted, isFalse);
  });

  test('turned on, it stays on', () {
    Autostart(root).file.writeAsStringSync('{"enabled":true}');
    expect(Autostart(root).wanted, isTrue);
  });
}
