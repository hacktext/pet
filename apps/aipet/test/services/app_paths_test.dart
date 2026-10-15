import 'dart:io';

import 'package:aipet/services/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Windows paths: separators and exe parsing only hold on a Windows host.
  final notWindows = !Platform.isWindows;

  test('app data lives under %APPDATA%\\com.aipet\\aipet', () {
    final root = appDataRoot({'APPDATA': 'C:\\Users\\u\\AppData\\Roaming'});
    expect(root.path, 'C:\\Users\\u\\AppData\\Roaming\\com.aipet\\aipet');
    expect(customPetsRoot(root).path, '${root.path}\\pets');
    expect(matteCacheRoot(root).path, '${root.path}\\matte-cache\\v1');
  }, skip: notWindows);

  test('missing APPDATA is an error, not a relative path', () {
    expect(() => appDataRoot(const {}, false), throwsStateError);
  }, skip: notWindows);

  test('built-in pets sit in the Flutter asset folder next to the exe', () {
    expect(builtinPetsRoot('C:\\Program Files\\aipet\\aipet.exe').path,
        'C:\\Program Files\\aipet\\data\\flutter_assets\\assets\\pets');
  }, skip: notWindows);

  test('macOS: app data under ~/Library/Application Support/com.aipet/aipet', () {
    expect(appDataRoot({'HOME': '/Users/u'}, true).path, '/Users/u/Library/Application Support/com.aipet/aipet');
    expect(() => appDataRoot(const {}, true), throwsStateError);
  });

  test('macOS: built-in pets sit in the Flutter assets inside the bundle', () {
    expect(builtinPetsRoot('/Applications/aipet.app/Contents/MacOS/aipet', true).path,
        '/Applications/aipet.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/pets');
  });
}
