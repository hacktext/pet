import 'dart:io';

import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late SettingsStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('settings_');
    store = SettingsStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('missing file means first run', () => expect(store.load(), LibraryState.empty));

  test('round trip without the transient preparing field', () {
    store.save(const LibraryState(currentPetId: 'a', adoptedPetIds: ['a', 'b'], preparingPetId: 'b'));
    expect(store.load(), const LibraryState(currentPetId: 'a', adoptedPetIds: ['a', 'b']));
    expect(store.file.readAsStringSync(), isNot(contains('preparing')));
  });

  test('saving again replaces the file and leaves no temp file behind', () {
    store.save(const LibraryState(currentPetId: 'a', adoptedPetIds: ['a']));
    store.save(const LibraryState(currentPetId: 'b', adoptedPetIds: ['a', 'b']));
    expect(store.load().currentPetId, 'b');
    expect(root.listSync().map((e) => e.uri.pathSegments.last), ['settings.json']);
  });

  test('creates the directory on first save', () {
    final nested = SettingsStore(Directory('${root.path}\\a\\b'));
    nested.save(const LibraryState(currentPetId: 'x', adoptedPetIds: ['x']));
    expect(nested.load().currentPetId, 'x');
  });

  for (final bad in ['{nope', '[]', '{"schema":2,"currentPetId":"a","adoptedPetIds":["a"]}',
                     '{"schema":1,"currentPetId":3,"adoptedPetIds":[]}']) {
    test('corrupt content is quarantined as .bad: $bad', () {
      store.file.writeAsStringSync(bad);
      expect(store.load(), LibraryState.empty);
      expect(store.file.existsSync(), isFalse);
      expect(File('${store.file.path}.bad').readAsStringSync(), bad);
    });
  }

  test('a current pet missing from the adopted list is added back', () {
    store.file.writeAsStringSync('{"schema":1,"currentPetId":"a","adoptedPetIds":["b"]}');
    expect(store.load(), const LibraryState(currentPetId: 'a', adoptedPetIds: ['b', 'a']));
  });
}
