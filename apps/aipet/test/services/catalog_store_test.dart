import 'dart:io';

import 'package:aipet/domain/paid_character.dart';
import 'package:aipet/services/catalog_store.dart';
import 'package:aipet/services/file_download.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTransport implements DownloadTransport {
  int calls = 0;
  bool fail = false;

  @override
  Future<void> download(Uri url, File into) async {
    calls++;
    if (fail) {
      into.writeAsStringSync('half');
      throw const DownloadFailed('boom');
    }
    into.writeAsStringSync('jpg');
  }
}

PaidCharacter char({String code = 'suwan', String? card = 'https://x/c.jpg'}) => PaidCharacter.fromJson({
      'code': code,
      'name': '苏晚',
      'species': 'girl',
      'price_cents': 1990,
      'card_url': card,
    })!;

void main() {
  late Directory tmp;
  late CatalogStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('catalog_');
    store = CatalogStore(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File f(String n) => File('${tmp.path}${Platform.pathSeparator}catalog${Platform.pathSeparator}$n');

  test('nothing cached loads null', () => expect(store.load(), isNull));

  test('save and saveOwned round-trip', () {
    store.save([char(), char(code: 'guchen')]);
    store.saveOwned({'guchen'});
    final r = CatalogStore(tmp).load()!;
    expect(r.items.map((c) => c.code), ['suwan', 'guchen']);
    expect(r.owned, {'guchen'});
  });

  test('a catalog without owned.json means nothing owned', () {
    store.save([char()]);
    expect(store.load()!.owned, isEmpty);
  });

  test('unreadable files', () {
    store.save([char()]);
    f('owned.json').writeAsStringSync('{nope');
    expect(store.load()!.owned, isEmpty);
    f('catalog.json').writeAsStringSync('{nope');
    expect(store.load(), isNull);
  });

  test('loadOwned reads owned.json without catalog.json; missing or unreadable is empty', () {
    expect(store.loadOwned(), isEmpty);
    store.saveOwned({'suwan', 'guchen'});
    expect(f('catalog.json').existsSync(), isFalse);
    expect(store.loadOwned(), {'suwan', 'guchen'});
    f('catalog.json').writeAsStringSync('{nope');
    expect(store.loadOwned(), {'suwan', 'guchen'});
    f('owned.json').writeAsStringSync('{"a": 1}');
    expect(store.loadOwned(), isEmpty);
  });

  test('cardFile path', () {
    expect(store.cardFile('suwan').path, endsWith('catalog${Platform.pathSeparator}cards${Platform.pathSeparator}suwan.jpg'));
  });

  test('cacheCard downloads once', () async {
    final t = _FakeTransport();
    await store.cacheCard(char(), t);
    expect(store.cardFile('suwan').readAsStringSync(), 'jpg');
    await store.cacheCard(char(), t);
    expect(t.calls, 1);
  });

  test('cacheCard without a url or on failure leaves no card and does not throw', () async {
    final t = _FakeTransport();
    await store.cacheCard(char(card: null), t);
    expect(t.calls, 0);
    t.fail = true;
    await store.cacheCard(char(), t);
    expect(store.cardFile('suwan').existsSync(), isFalse);
  });

  test('an empty card file is downloaded again', () async {
    final t = _FakeTransport();
    store.cardFile('suwan').createSync(recursive: true);
    await store.cacheCard(char(), t);
    expect(t.calls, 1);
    expect(store.cardFile('suwan').readAsStringSync(), 'jpg');
  });
}
