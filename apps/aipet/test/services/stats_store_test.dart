import 'dart:io';

import 'package:aipet/domain/pet_stats.dart';
import 'package:aipet/services/stats_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late StatsStore store;
  final t0 = DateTime(2026, 9, 19, 9);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('stats_');
    store = StatsStore(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a first run has no stats', () => expect(store.load(), isEmpty));

  test('round trip', () {
    final all = {'builtin-gold': PetStats.fresh(t0), 'builtin-corgi': recordInteraction(PetStats.fresh(t0), t0, fed: true)};
    store.save(all);
    expect(store.load(), all);
  });

  test('an unreadable file is kept as .bad and treated as empty', () {
    store.file.writeAsStringSync('{nope');
    expect(store.load(), isEmpty);
    expect(File('${store.file.path}.bad').existsSync(), isTrue);
    expect(store.file.existsSync(), isFalse);
  });

  test('one bad entry is dropped, the others kept', () {
    store.file.writeAsStringSync('{"schema":1,"pets":{"a":{"intimacy":"x"},'
        '"b":${_json(PetStats.fresh(t0))}}}');
    expect(store.load().keys, ['b']);
  });
}

String _json(PetStats s) => '{${s.toJson().entries.map((e) => '"${e.key}":${e.value}').join(',')}}';
