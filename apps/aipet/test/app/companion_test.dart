import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

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
import 'package:aipet/services/voice_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_mover.dart';
import '../support/fake_player.dart';
import '../support/fake_transport.dart';
import '../support/fake_voice_player.dart';
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

/// A mover whose bounds() can be parked: on Windows it is a platform round
/// trip, so anything may happen while the panel waits for it.
class GatedMover extends FakeMover {
  Completer<Rect>? gate;

  @override
  Future<Rect> bounds() => gate?.future ?? super.bounds();
}

const kSeven = ['stand', 'walk', 'sleep', 'feed', 'play', 'lick_paw', 'act_cute'];

void main() {
  const frame = Duration(milliseconds: 33);
  late Directory tmp;
  late DateTime now;
  late FakePlayer player;
  late GatedMover mover;
  late PetWindowController pets;
  late StatsKeeper stats;
  late WalkDriver walker;
  late Companion c;
  late List<String> panel;
  late FakeVoicePlayer voice;
  late FakeTransport panelEnd;
  late List<String> events; // what the telemetry and sync hooks heard
  Offset? cursorAt; // where the pointer is on the screen; null: cannot be told
  Completer<void>? showGate; // when set, the panel takes its time coming up
  Completer<void>? hideGate; // when set, the panel takes its time going away

  /// What boot() has built so far, to be undone in reverse. Each step goes in
  /// the moment there is something to undo, so a boot() that throws half-way
  /// still takes down what it had already built.
  final teardown = <void Function()>[];

  Future<void> run(WidgetTester t, Duration span) async {
    final end = now.add(span);
    while (now.isBefore(end)) {
      now = now.add(frame);
      await t.pump(frame);
    }
  }

  Future<void> boot({Future<File> Function(File)? ensure, bool twoPets = false, bool character = false}) async {
    // Held in a local as well: the step must undo the folder this boot() just
    // made, not whichever one the shared variable points at when it runs.
    final dir = tmp = Directory.systemTemp.createTempSync('companion_');
    teardown.add(() => dir.deleteSync(recursive: true));
    final builtin = Directory('${tmp.path}\\builtin')..createSync();
    writePet(builtin, id: 'builtin-gold', name: '金毛', actions: kSeven);
    if (character) writeCharacter(builtin);
    if (twoPets) writePet(builtin, id: 'builtin-corgi', name: '柯基', actions: kSeven);
    final appData = Directory('${tmp.path}\\appdata');
    final first = character ? 'builtin-xiaoya' : 'builtin-gold';
    SettingsStore(appData).save(LibraryState(currentPetId: first, adoptedPetIds: [first]));
    now = DateTime(2026, 9, 19, 9);
    player = FakePlayer();
    mover = GatedMover();
    showGate = null;
    hideGate = null;
    cursorAt = null;
    pets = PetWindowController(
      library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
      settings: SettingsStore(appData),
      ensure: ensure ?? (f) async => f,
      player: player,
      push: (_) async {},
    );
    stats = StatsKeeper(StatsStore(appData), now: () => now);
    walker = WalkDriver(mover, facing: () => Facing.left, clock: () => now, frame: frame);
    teardown.add(walker.dispose);
    final (petEnd, pEnd) = FakeTransport.pair();
    panelEnd = pEnd;
    panel = [];
    HudWindowBridge(panelEnd,
        onShow: (r, v) async {
          // The real panel asks for the work area before it places itself, so
          // a hide sent meanwhile can be handled while a show is still in hand.
          final gate = showGate;
          if (gate != null) await gate.future;
          panel.add('show $r ${v.name} ${v.todayInteractions}');
        },
        onUpdate: (v) => panel.add('update ${v.todayInteractions}'),
        onHide: () async {
          final gate = hideGate;
          if (gate != null) await gate.future;
          panel.add('hide');
        }).start();
    voice = FakeVoicePlayer();
    c = Companion(
        pets: pets,
        stats: stats,
        walker: walker,
        mover: mover,
        hudTransport: petEnd,
        voices: VoiceStore(appData),
        voicePlayer: voice,
        random: LowRandom(),
        cursor: () async => cursorAt,
        onInteract: (pet, kind) => events.add('interact $pet $kind'),
        onVoiceChosen: (pet, v) => events.add('voice $pet $v'));
    events = [];
    teardown.add(c.dispose);
    await pets.boot();
  }

  void finish() {
    for (final step in teardown.reversed) {
      // Best effort: Windows refuses to remove a folder while a file in it is
      // still open, and a teardown that throws would replace the failure that
      // brought us here with its own.
      try {
        step();
      } catch (e) {
        printOnFailure('teardown failed: $e');
      }
    }
    teardown.clear();
  }

  /// Every test tears down the Companion, the WalkDriver and its temp folder
  /// even when an expect fails: testWidgets looks for pending timers when the
  /// body ends -- before any tearDown would run -- so a leaked walk or roam
  /// timer would fail the *next* test and hide the real failure.
  void petTest(String description, Future<void> Function(WidgetTester) body) =>
      testWidgets(description, (t) async {
        try {
          await body(t);
        } finally {
          finish();
        }
      });

  petTest('the panel shows the pet, its numbers and the buttons it has', (t) async {
    await boot();
    final v = c.view!;
    expect(v.name, '金毛');
    expect([v.intimacy, v.satiety, v.health, v.companionDays, v.todayInteractions], [50, 50, 100, 1, 0]);
    expect(v.status, '状态很好'); // satiety 50 is not below 50
    expect(v.buttons, ['stand', 'walk', 'feed', 'play', 'sleep', 'lick_paw', 'act_cute']);
    expect(v.enabled, kSeven.toSet());
  });

  petTest("a character's action says one of its lines in the chosen voice, the first voice by default", (t) async {
    await boot(character: true);
    expect([for (final v in c.availableVoices) v.id], ['xiaoya', 'vivi']);
    expect(c.currentVoice, 'xiaoya');
    await c.userAction('act_coy');
    expect(player.plays.last, 'builtin-xiaoya/act_coy.mp4|once');
    expect(voice.log.last, 'xiaoya/act_coy-1.wav'); // LowRandom picks the first line
    c.chooseVoice('vivi');
    expect(c.currentVoice, 'vivi');
    await c.userAction('talk');
    expect(voice.log.last, 'vivi/talk-1.wav');
  });

  petTest('an action without lines stops the voice; 静音 keeps her quiet', (t) async {
    await boot(character: true);
    await c.userAction('act_coy');
    await c.userAction('stand');
    expect(voice.log.last, 'stop');
    c.chooseVoice(null);
    expect(c.currentVoice, isNull);
    voice.log.clear();
    await c.userAction('act_coy');
    expect(voice.log, ['stop']);
  });

  petTest('an animal without voices never speaks', (t) async {
    await boot();
    await c.userAction('feed');
    expect(c.availableVoices, isEmpty);
    expect(voice.log.where((e) => e != 'stop'), isEmpty);
  });

  petTest('a button plays the action and counts an interaction; feeding fills the bowl', (t) async {
    await boot();
    await c.userAction('feed');
    expect(player.plays.last, 'builtin-gold/feed.mp4|once');
    expect(stats.current!.satiety, 80);
    expect(stats.current!.todayInteractions, 1);
  });

  petTest('walk moves the window for 20 s and ends on stand', (t) async {
    await boot();
    final done = c.userAction('walk');
    await run(t, const Duration(seconds: 21));
    await done;
    expect(mover.moves, isNotEmpty);
    expect(player.plays, containsAllInOrder(['builtin-gold/walk.mp4|loop', 'builtin-gold/stand.mp4|loop']));
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    expect(walker.walking, isFalse);
  });

  petTest('another action mid-walk stops the walk and does not snap back to stand', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 2));
    await c.userAction('lick_paw');
    await walking;
    await run(t, const Duration(seconds: 1));
    expect(player.plays.last, 'builtin-gold/lick_paw.mp4|once');
    expect(walker.walking, isFalse);
  });

  petTest('dragging stops a walk and returns to stand', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 1));
    c.dragStarted();
    await walking;
    await t.pump();
    expect(walker.walking, isFalse);
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    c.dragEnded();
  });

  petTest('a walk that replaces another leaves the panel down while it runs', (t) async {
    await boot();
    final first = c.userAction('walk');
    await run(t, const Duration(seconds: 1));
    unawaited(c.userAction('walk')); // 走路 again: the first walk is superseded
    await first; // it wakes up the moment the second one takes the driver
    c.petEnter();
    await t.pump(const Duration(milliseconds: 300));
    expect(walker.walking, isTrue);
    expect(panel, isEmpty, reason: 'the window is still sliding: the panel would sit where the pet no longer is');
    c.petExit();
  });

  petTest('adopting another pet mid-walk stops the walk', (t) async {
    await boot(twoPets: true);
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 1));
    expect(walker.walking, isTrue);
    await pets.adopt('builtin-corgi');
    await t.pump();
    expect(walker.walking, isFalse, reason: 'the new pet is standing, so the window must stop sliding');
    final moves = mover.moves.length;
    await run(t, const Duration(seconds: 1));
    expect(mover.moves, hasLength(moves));
    await walking;
  });

  petTest('hovering shows the panel over the pet window; a change updates it', (t) async {
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
  });

  petTest('macOS: the pointer on the panel keeps it up though the panel window reports nothing', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(milliseconds: 300));
    expect(panel, ['show ${mover.rect} 金毛 0']);
    // Off the pet and onto the panel above it, which sends no hover event.
    cursorAt = mover.rect.topCenter.translate(0, -100);
    c.petExit();
    await t.pump(const Duration(seconds: 3));
    expect(panel.last, startsWith('show'));
    cursorAt = mover.rect.bottomRight.translate(200, 200); // away from both
    await t.pump(const Duration(milliseconds: 600));
    expect(panel.last, 'hide');
  });

  petTest('a drag while the panel is being placed does not strand it on screen', (t) async {
    await boot();
    c.petEnter();
    final gate = mover.gate = Completer<Rect>();
    await t.pump(const Duration(milliseconds: 300)); // the show fires and parks on bounds()
    expect(panel, isEmpty);
    c.dragStarted(); // the presenter takes the panel away and believes it gone
    await t.pump();
    expect(panel, ['hide']);
    mover.gate = null;
    gate.complete(mover.rect); // the bounds finally come back
    await t.pump();
    expect(panel.where((p) => p.startsWith('show')), isEmpty,
        reason: 'a panel the presenter thinks is hidden is never updated or taken away again');
    c.dragEnded();
  });

  petTest('a panel that came up after the hide is taken away again', (t) async {
    await boot();
    c.petEnter();
    showGate = Completer<void>();
    await t.pump(const Duration(milliseconds: 300)); // the show is sent, and the panel sits on it
    expect(panel, isEmpty);
    c.dragStarted(); // the hide overtakes the show ...
    await t.pump();
    expect(panel, ['hide']);
    showGate!.complete(); // ... and the panel then puts itself back on screen
    await t.pump();
    expect(panel, ['hide', 'show ${mover.rect} 金毛 0', 'hide'],
        reason: 'the show landed last, so the panel is on the desktop and nothing else will take it off');
    c.petExit();
    c.dragEnded();
  });

  petTest('a panel placed while a newer one is being placed does not land with the old rectangle', (t) async {
    await boot();
    c.petEnter();
    final stale = mover.rect;
    final gate = mover.gate = Completer<Rect>();
    await t.pump(const Duration(milliseconds: 300)); // show #1 fires and parks on bounds()
    expect(panel, isEmpty);
    c.dragStarted(); // the panel goes down ...
    await t.pump();
    c.dragEnded(); // ... and the pointer never left the pet, so it is asked for again
    mover.gate = null;
    mover.rect = const Rect.fromLTWH(900, 200, 360, 360); // the drag put the pet somewhere else
    await t.pump(const Duration(milliseconds: 300)); // show #2 asks and hears back at once
    expect(panel, ['hide', 'show ${mover.rect} 金毛 0']);
    gate.complete(stale); // show #1 finally hears back, with the rectangle from before the drag
    await t.pump();
    expect(panel.last, 'show ${mover.rect} 金毛 0',
        reason: 'the older show would drop the panel where the pet no longer is, and leave it there');
  });

  petTest('after 3 idle minutes it roams by itself for 8 s, without counting an interaction', (t) async {
    await boot();
    await t.pump(const Duration(minutes: 3)); // the walk clock (now) is left alone: the roam starts from here
    expect(player.plays.last, 'builtin-gold/walk.mp4|loop');
    await run(t, const Duration(seconds: 9));
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    expect(stats.current!.todayInteractions, 0);
  });

  petTest('no roaming while the pointer is on the pet', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(minutes: 3));
    expect(player.plays.where((p) => p.contains('walk')), isEmpty);
    c.petExit();
  });

  petTest('an action arriving while the walk clip is still being matted leaves the pet off walk', (t) async {
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
  });

  petTest('dispose() during a live walk stops it', (t) async {
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
  });

  petTest('quitting waits for the panel to come off the screen', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(milliseconds: 300));
    expect(panel, ['show ${mover.rect} 金毛 0']);
    hideGate = Completer<void>();
    var quit = false;
    unawaited(c.shutdown().then((_) => quit = true));
    await t.pump();
    expect(quit, isFalse, reason: 'the panel is still on screen, and the native teardown takes seconds');
    hideGate!.complete();
    await t.pump();
    expect(quit, isTrue);
    expect(panel.last, 'hide');
  });

  petTest('quitting with the pointer on the pet does not bring the panel back', (t) async {
    await boot();
    c.petEnter();
    final walking = c.userAction('walk'); // the walk keeps the panel down while the pointer sits on the pet
    await run(t, const Duration(seconds: 1));
    expect(panel, isEmpty);
    await c.shutdown();
    await t.pump(const Duration(milliseconds: 400)); // longer than the 300 ms the panel waits to come up
    expect(panel.last, 'hide');
    expect(panel.where((p) => p.startsWith('show')), isEmpty,
        reason: 'the stopped walk frees the panel one microtask after the hide, '
            'and the panel would sit on the desktop for the seconds the teardown takes');
    expect(c.presenter.shown, isFalse, reason: 'nothing may put the panel back once quitting has begun');
    await walking;
  });

  petTest('quitting drops the panel that was on its way up', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(milliseconds: 100)); // the 300 ms wait before the panel appears is running
    await c.shutdown();
    await t.pump(const Duration(milliseconds: 400));
    expect(panel, ['hide']);
    expect(c.presenter.shown, isFalse,
        reason: 'nothing may still be counting down to a panel while the engine is torn down');
  });

  petTest('shutdown gives a wedged panel the bridge 500 ms and no longer', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 1));
    panelEnd.silent = true; // the panel stops answering
    var quit = false;
    unawaited(c.shutdown().then((_) => quit = true));
    await t.pump(const Duration(milliseconds: 500)); // the bridge's own timeout and not a tick more
    expect(quit, isTrue);
    expect(walker.walking, isFalse);
    await walking;
  });

  petTest('quitting with the panel really on screen leaves it off for good', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(milliseconds: 300));
    expect(panel, ['show ${mover.rect} 金毛 0'], reason: 'the panel is up on the desktop when the quit arrives');
    await c.shutdown();
    expect(panel, ['show ${mover.rect} 金毛 0', 'hide']);
    // Quitting from the pet's right-click menu happens with the pointer on
    // the pet, and the pointer goes on crossing the window for the seconds
    // the native teardown takes -- hiding the window itself fires an exit.
    c.petExit();
    await t.pump(const Duration(milliseconds: 600));
    c.petEnter();
    await t.pump(const Duration(milliseconds: 400)); // longer than the 300 ms the panel waits to come up
    expect(panel, ['show ${mover.rect} 金毛 0', 'hide'],
        reason: 'the panel is down for the quit: nothing shows it again, and nothing hides it twice');
    expect(c.presenter.shown, isFalse, reason: 'nothing may put the panel back once quitting has begun');
  });

  petTest('a panel click that lands after quitting began does nothing', (t) async {
    await boot();
    await c.shutdown();
    final plays = player.plays.length;
    // The panel is hidden, not stopped: a click already on its way still
    // arrives over the bridge while the engine is being torn down.
    final action = c.userAction('walk');
    await run(t, const Duration(seconds: 21)); // longer than a user walk
    await action;
    expect(stats.current!.todayInteractions, 0, reason: 'stats.json must not be rewritten during the teardown');
    expect(player.plays, hasLength(plays), reason: 'the pet window is on its way off the screen');
    expect(mover.moves, isEmpty, reason: 'a hidden window must not be walked across the desktop');
    expect(walker.walking, isFalse);
    expect(panel.where((p) => p.startsWith('show')), isEmpty);
  });

  petTest('hooks: each action and drag is an interaction; a voice change is reported once', (t) async {
    await boot(character: true);
    await c.userAction('act_coy');
    await c.userAction('nope'); // not one of its actions: nothing happened
    c.dragStarted();
    c.dragEnded();
    c.chooseVoice('vivi');
    c.chooseVoice('vivi'); // the same again is no change
    c.chooseVoice(null);
    expect(events, [
      'interact builtin-xiaoya act_coy',
      'interact builtin-xiaoya drag',
      'voice builtin-xiaoya vivi',
      'voice builtin-xiaoya off',
    ]);
    await run(t, const Duration(seconds: 1));
  });
}

/// 小雅 with two voices; xiaoya has act_coy and talk lines, vivi has talk.
void writeCharacter(Directory builtin) {
  final dir = writePet(builtin, id: 'builtin-xiaoya', name: '小雅', species: 'girl',
      actions: const ['stand', 'act_coy', 'talk']);
  final meta = File('${dir.path}\\pet.json');
  final j = jsonDecode(meta.readAsStringSync()) as Map<String, Object?>;
  j['voices'] = [
    {'id': 'xiaoya', 'name': '温柔小雅'},
    {'id': 'vivi', 'name': '元气 Vivi'},
  ];
  meta.writeAsStringSync(jsonEncode(j));
  for (final f in ['xiaoya\\act_coy-1.wav', 'xiaoya\\act_coy-2.wav', 'xiaoya\\talk-1.wav', 'vivi\\talk-1.wav']) {
    File('${dir.path}\\voices\\$f')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([0]);
  }
}
