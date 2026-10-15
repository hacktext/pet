import 'dart:io';

import 'package:aipet/domain/pet_size.dart';
import 'package:aipet/services/pet_size_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late PetSizeStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pet_size_');
    store = PetSizeStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('a first run is the fallback size', () => expect(store.load(), PetSize.fallback));

  test('round trip, leaving no temp file behind', () {
    store.save(PetSize.small);
    expect(store.load(), PetSize.small);
    store.save(PetSize.medium);
    expect(store.load(), PetSize.medium);
    expect(root.listSync().map((e) => e.uri.pathSegments.last), ['pet_size.json']);
  });

  test('creates the directory on first save', () {
    final nested = PetSizeStore(Directory('${root.path}${Platform.pathSeparator}a'));
    nested.save(PetSize.small);
    expect(nested.load(), PetSize.small);
  });

  for (final bad in ['{nope', '[]', '{"size":"huge"}', '{"size":2}']) {
    test('unreadable content is the fallback: $bad', () {
      store.file.writeAsStringSync(bad);
      expect(store.load(), PetSize.fallback);
    });
  }
}
