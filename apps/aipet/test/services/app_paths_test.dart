import 'package:aipet/services/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app data lives under %APPDATA%\\com.aipet\\aipet', () {
    final root = appDataRoot({'APPDATA': 'C:\\Users\\u\\AppData\\Roaming'});
    expect(root.path, 'C:\\Users\\u\\AppData\\Roaming\\com.aipet\\aipet');
    expect(customPetsRoot(root).path, '${root.path}\\pets');
    expect(matteCacheRoot(root).path, '${root.path}\\matte-cache\\v1');
  });

  test('missing APPDATA is an error, not a relative path', () {
    expect(() => appDataRoot(const {}), throwsStateError);
  });

  test('built-in pets sit in the Flutter asset folder next to the exe', () {
    expect(builtinPetsRoot('C:\\Program Files\\aipet\\aipet.exe').path,
        'C:\\Program Files\\aipet\\data\\flutter_assets\\assets\\pets');
  });
}
