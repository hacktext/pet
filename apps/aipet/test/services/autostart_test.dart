import 'dart:io';

import 'package:aipet/services/autostart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('autostart_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('on by default: a first run wants it', () {
    expect(Autostart(root).wanted, isTrue);
  });

  test('an unreadable choice counts as never made', () {
    Autostart(root).file.writeAsStringSync('{nope');
    expect(Autostart(root).wanted, isTrue);
  });

  test('turned off, it stays off', () {
    Autostart(root).file.writeAsStringSync('{"enabled":false}');
    expect(Autostart(root).wanted, isFalse);
  });
}
