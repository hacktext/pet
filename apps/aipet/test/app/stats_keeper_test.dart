import 'dart:io';

import 'package:aipet/app/pet_window/stats_keeper.dart';
import 'package:aipet/domain/pet_stats.dart';
import 'package:aipet/services/stats_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts the writes stats.json would take.
class CountingStore extends StatsStore {
  CountingStore(super.root);

  int saves = 0;

  @override
  void save(Map<String, PetStats> all) {
    saves++;
    super.save(all);
  }
}

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

  test('a tick that moves nothing on screen writes no file', () {
    final store = CountingStore(tmp);
    final k = StatsKeeper(store, now: () => now)..select('builtin-gold');
    expect(store.saves, 1); // a pet seen for the first time is written once
    now = now.add(const Duration(seconds: 10)); // satiety 50 -> 49.99, still 50 on screen
    k.tick();
    expect(store.saves, 1);
    expect(k.current!.satiety, lessThan(50)); // the drift is kept in memory
  });

  test('a tick that rolls a displayed number writes the file', () {
    final store = CountingStore(tmp);
    final k = StatsKeeper(store, now: () => now)..select('builtin-gold');
    now = now.add(const Duration(minutes: 30)); // satiety 50 -> 47.9, 48 on screen
    k.tick();
    expect(store.saves, 2);
    expect(k.current!.satiety.round(), 48);
  });

  test('a tick that crosses midnight writes the file even with nothing on screen to show for it', () {
    now = DateTime(2026, 9, 19, 23, 59, 30);
    final store = CountingStore(tmp);
    final k = StatsKeeper(store, now: () => now)..select('builtin-gold');
    expect(store.saves, 1);
    expect(k.current!.todayInteractions, 0); // fresh, so the counter has nowhere to move
    now = DateTime(2026, 9, 20, 0, 0, 10); // 40 s on: every displayed number is the one before
    k.tick();
    expect([k.current!.satiety.round(), k.current!.health.round(), k.current!.intimacy.round()], [50, 100, 50]);
    expect(k.current!.interactionDay, DateTime(2026, 9, 20));
    expect(store.saves, 2,
        reason: 'the day on disk is the only thing keeping the snapshot under a day stale, '
            'and the 30-day catch-up cap out of reach');
  });

  test('a tick that only moves health writes the file', () {
    final store = CountingStore(tmp);
    final k = StatsKeeper(store, now: () => now)..select('builtin-gold');
    now = now.add(const Duration(hours: 24)); // satiety bottoms out well before this and stays there
    k.tick();
    expect(k.current!.satiety, 0);
    final saves = store.saves;
    final health = k.current!.health.round();
    now = now.add(const Duration(minutes: 30)); // starving costs 2 health an hour, so 1 here; nothing else moves
    k.tick();
    expect(k.current!.satiety, 0);
    expect(k.current!.health.round(), health - 1);
    expect(store.saves, saves + 1);
  });

  test('numbers a skipped save left in memory survive a restart', () {
    final store = CountingStore(tmp);
    final k = StatsKeeper(store, now: () => now)..select('builtin-gold');
    for (var i = 0; i < 2; i++) {
      now = now.add(const Duration(minutes: 1));
      k.tick();
    }
    expect(store.saves, 1); // nothing on screen moved, so nothing was written
    final again = make()..select('builtin-gold'); // the older snapshot, caught up to now
    expect(again.current!.satiety, closeTo(k.current!.satiety, 1e-9));
    expect(again.current!.health, closeTo(k.current!.health, 1e-9));
  });

  test('select, interact and tick all tell their listeners', () {
    var fired = 0;
    final k = make()..addListener(() => fired++);
    k.select('builtin-gold');
    expect(fired, 1);
    k.interact('feed');
    expect(fired, 2);
    expect(k.current!.satiety, 80);
    now = now.add(const Duration(hours: 6)); // satiety 80 -> 55
    k.tick();
    expect(fired, 3);
    expect(k.current!.satiety, closeTo(55, 1e-6));
  });

  test('a tick that writes nothing still tells its listeners', () {
    var fired = 0;
    final store = CountingStore(tmp);
    final k = StatsKeeper(store, now: () => now)
      ..select('builtin-gold')
      ..addListener(() => fired++);
    now = now.add(const Duration(seconds: 10)); // satiety 50 -> 49.99: nothing to save
    k.tick();
    expect(store.saves, 1);
    expect(fired, 1, reason: 'the panel works its status text out from the unrounded satiety every time');
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
