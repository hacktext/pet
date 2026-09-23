import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:aipet/app/pet_window/companion.dart';
import 'package:aipet/app/pet_window/pet_window_controller.dart';
import 'package:aipet/app/pet_window/stats_keeper.dart';
import 'package:aipet/app/pet_window/walk_driver.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/walker.dart';
import 'package:aipet/services/hud_bridge.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/settings_store.dart';
import 'package:aipet/services/stats_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_mover.dart';
import '../support/fake_player.dart';
import '../support/fake_transport.dart';
import '../support/pet_fixtures.dart';

/// Always the shortest idle (3 min) and the shortest roam (8 s).
class LowRandom implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

const kSeven = ['stand', 'walk', 'sleep', 'feed', 'play', 'lick_paw', 'act_cute'];

void main() {
  const frame = Duration(milliseconds: 33);
  late Directory tmp;
  late DateTime now;
  late FakePlayer player;
  late FakeMover mover;
  late PetWindowController pets;
  late StatsKeeper stats;
  late WalkDriver walker;
  late Companion c;
  late List<String> panel;
  late FakeTransport panelEnd;

  Future<void> run(WidgetTester t, Duration span) async {
    final end = now.add(span);
    while (now.isBefore(end)) {
      now = now.add(frame);
      await t.pump(frame);
    }
  }

  Future<void> boot({Future<File> Function(File)? ensure}) async {
    tmp = Directory.systemTemp.createTempSync('companion_');
    final builtin = Directory('${tmp.path}\\builtin')..createSync();
    writePet(builtin, id: 'builtin-gold', name: '金毛', actions: kSeven);
    final appData = Directory('${tmp.path}\\appdata');
    SettingsStore(appData).save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
    now = DateTime(2026, 9, 19, 9);
    player = FakePlayer();
    mover = FakeMover();
    pets = PetWindowController(
      library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
      settings: SettingsStore(appData),
      ensure: ensure ?? (f) async => f,
      player: player,
      push: (_) async {},
    );
    stats = StatsKeeper(StatsStore(appData), now: () => now);
    walker = WalkDriver(mover, facing: () => Facing.left, clock: () => now, frame: frame);
    final (petEnd, pEnd) = FakeTransport.pair();
    panelEnd = pEnd;
    panel = [];
    HudWindowBridge(panelEnd,
        onShow: (r, v) async => panel.add('show $r ${v.name} ${v.todayInteractions}'),
        onUpdate: (v) => panel.add('update ${v.todayInteractions}'),
        onHide: () async => panel.add('hide')).start();
    c = Companion(pets: pets, stats: stats, walker: walker, mover: mover, hudTransport: petEnd, random: LowRandom());
    await pets.boot();
  }

  void finish() {
    c.dispose();
    walker.dispose();
    tmp.deleteSync(recursive: true);
  }

  testWidgets('the panel shows the pet, its numbers and the buttons it has', (t) async {
    await boot();
    final v = c.view!;
    expect(v.name, '金毛');
    expect([v.intimacy, v.satiety, v.health, v.companionDays, v.todayInteractions], [50, 50, 100, 1, 0]);
    expect(v.status, '状态很好'); // satiety 50 is not below 50
    expect(v.enabled, {'stand', 'walk', 'feed', 'play'});
    finish();
  });

  testWidgets('a button plays the action and counts an interaction; feeding fills the bowl', (t) async {
    await boot();
    await c.userAction('feed');
    expect(player.plays.last, 'builtin-gold/feed.mp4|once');
    expect(stats.current!.satiety, 80);
    expect(stats.current!.todayInteractions, 1);
    finish();
  });

  testWidgets('walk moves the window for 20 s and ends on stand', (t) async {
    await boot();
    final done = c.userAction('walk');
    await run(t, const Duration(seconds: 21));
    await done;
    expect(mover.moves, isNotEmpty);
    expect(player.plays, containsAllInOrder(['builtin-gold/walk.mp4|loop', 'builtin-gold/stand.mp4|loop']));
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    expect(walker.walking, isFalse);
    finish();
  });

  testWidgets('another action mid-walk stops the walk and does not snap back to stand', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 2));
    await c.userAction('lick_paw');
    await walking;
    await run(t, const Duration(seconds: 1));
    expect(player.plays.last, 'builtin-gold/lick_paw.mp4|once');
    expect(walker.walking, isFalse);
    finish();
  });

  testWidgets('dragging stops a walk and returns to stand', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 1));
    c.dragStarted();
    await walking;
    await t.pump();
    expect(walker.walking, isFalse);
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    c.dragEnded();
    finish();
  });

  testWidgets('hovering shows the panel over the pet window; a change updates it', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(milliseconds: 300));
    expect(panel, ['show ${mover.rect} 金毛 0']);
    await c.userAction('play');
    await t.pump();
    expect(panel.last, 'update 1');
    c.petExit();
    await t.pump(const Duration(milliseconds: 600));
    expect(panel.last, 'hide');
    finish();
  });

  testWidgets('after 3 idle minutes it roams by itself for 8 s, without counting an interaction', (t) async {
    await boot();
    await t.pump(const Duration(minutes: 3)); // the walk clock (now) is left alone: the roam starts from here
    expect(player.plays.last, 'builtin-gold/walk.mp4|loop');
    await run(t, const Duration(seconds: 9));
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    expect(stats.current!.todayInteractions, 0);
    finish();
  });

  testWidgets('no roaming while the pointer is on the pet', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(minutes: 3));
    expect(player.plays.where((p) => p.contains('walk')), isEmpty);
    c.petExit();
    finish();
  });

  testWidgets('an action arriving while the walk clip is still being matted leaves the pet off walk', (t) async {
    final gate = Completer<File>();
    await boot(ensure: (f) => f.path.endsWith('walk.mp4') ? gate.future : Future.value(f));
    final walking = c.userAction('walk');
    await t.pump();
    await c.userAction('lick_paw'); // dropped by the controller's own _switching guard, but bumps the generation
    gate.complete(File('${tmp.path}\\builtin\\builtin-gold\\walk.mp4'));
    await walking;
    await t.pump();
    expect(pets.currentAction, isNot('walk'));
    expect(player.plays.last, isNot('builtin-gold/walk.mp4|loop'));
    finish();
  });

  testWidgets('dispose() during a live walk stops it', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 1));
    c.dispose();
    final movesAtDispose = mover.moves.length;
    expect(walker.walking, isFalse);
    await run(t, const Duration(seconds: 1));
    expect(mover.moves.length, movesAtDispose);
    expect(walker.walking, isFalse);
    await walking;
    walker.dispose();
    tmp.deleteSync(recursive: true);
  });

  testWidgets('shutdown does not wait for a wedged panel', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 1));
    panelEnd.silent = true; // the panel stops answering
    await c.shutdown(); // must return promptly, not after a 2 s timeout
    expect(walker.walking, isFalse);
    await walking;
    await t.pump(const Duration(milliseconds: 500)); // let the fired-and-forgotten hide's own timeout land
    finish();
  });
}
