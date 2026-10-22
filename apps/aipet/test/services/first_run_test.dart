import 'dart:io';

import 'package:aipet/services/first_run.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('first_run_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('the installer\'s mark is seen once and then gone', () {
    File('${dir.path}${Platform.pathSeparator}$kFirstRunMark').writeAsStringSync('');
    expect(takeFirstRunMark(dir), isTrue);
    expect(File('${dir.path}${Platform.pathSeparator}$kFirstRunMark').existsSync(), isFalse);
    expect(takeFirstRunMark(dir), isFalse);
  });

  test('no mark: an ordinary launch', () {
    expect(takeFirstRunMark(dir), isFalse);
    expect(takeFirstRunMark(Directory('${dir.path}${Platform.pathSeparator}missing')), isFalse);
  });
}
