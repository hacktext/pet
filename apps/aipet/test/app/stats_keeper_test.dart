import 'dart:io';

import 'package:aipet/app/pet_window/stats_keeper.dart';
import 'package:aipet/services/stats_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late DateTime now;
  StatsKeeper make() => StatsKeeper(StatsStore(tmp), now: () => now);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('keeper_');
    now = DateTime(2026, 9, 19, 9);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('nobody selected: no stats, and actions are ignored', () {
    final k = make()..interact('feed');
    expect(k.current, isNull);
  });

  test('a newly selected pet starts fresh and is saved', () {
    make().select('builtin-gold');
    final again = make()..select('builtin-gold');
    expect([again.current!.intimacy, again.current!.satiety, again.current!.health], [50, 50, 100]);
  });

  test('feeding and playing change the numbers and are saved', () {
    final k = make()..select('builtin-gold');
    k.interact('feed');
    k.interact('play');
    expect(k.current!.satiety, 80);
    expect(k.current!.intimacy, 52);
    expect(k.current!.todayInteractions, 2);
    expect((make()..select('builtin-gold')).current!.satiety, 80);
  });

  test('tick catches up the time that passed', () {
    final k = make()..select('builtin-gold');
    now = now.add(const Duration(hours: 6)); // satiety 50 -> 25
    k.tick();
    expect(k.current!.satiety, closeTo(25, 1e-6));
  });

  test('each pet keeps its own numbers', () {
    final k = make()..select('builtin-gold');
    k.interact('feed');
    k.select('builtin-corgi');
    expect(k.current!.satiety, 50);
    k.select('builtin-gold');
    expect(k.current!.satiety, 80);
  });

  test('a failed save does not throw', () {
    final blocker = File('${tmp.path}\\blocker')..writeAsStringSync('x'); // a file where the folder should be
    final k = StatsKeeper(StatsStore(Directory(blocker.path)), now: () => now);
    expect(() => k.select('builtin-gold'), returnsNormally);
    expect(k.current, isNotNull); // still on screen even though it was not saved
  });
}
