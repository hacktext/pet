import 'dart:async';
import 'dart:io';

import 'package:aipet/app/pet_window/pet_window_controller.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/settings_store.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_player.dart';
import '../support/pet_fixtures.dart';

void main() {
  late Directory tmp, builtin, appData;
  late SettingsStore settings;
  late FakePlayer player;
  late List<LibraryState> pushed;
  late Future<File> Function(File) ensure;
  late PetWindowController c;

  PetWindowController make({Duration prepareTimeout = kPrepareTimeout}) => PetWindowController(
        library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
        settings: settings,
        ensure: (f) => ensure(f),
        player: player,
        push: (s) async => pushed.add(s),
        prepareTimeout: prepareTimeout,
      );
  const short = Duration(milliseconds: 50);
  const failFast = Timeout(Duration(seconds: 5)); // a missing cap must fail, not hang for 30 s

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('petwin_');
    builtin = Directory('${tmp.path}\\builtin')..createSync();
    appData = Directory('${tmp.path}\\appdata');
    writePet(builtin, id: 'builtin-gold');
    writePet(builtin, id: 'builtin-ragdoll', species: 'cat');
    writePet(builtin, id: 'builtin-broken', complete: false);
    settings = SettingsStore(appData);
    player = FakePlayer();
    pushed = [];
    ensure = (f) async => f; // "matting" returns the clip itself, so plays name the action
    c = make();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('boot', () {
    test('first run: nobody on the desktop', () async {
      await c.boot();
      expect(c.currentPet, isNull);
      expect(player.plays, isEmpty);
      expect(pushed.single, LibraryState.empty);
      expect(c.pets.map((p) => p.id), ['builtin-broken', 'builtin-gold', 'builtin-ragdoll']);
    });

    test('shows the saved pet idling', () async {
      settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      await c.boot();
      expect(c.currentPet?.id, 'builtin-gold');
      expect(c.currentAction, 'stand');
      expect(player.plays, ['builtin-gold/stand.mp4|loop']);
    });

    test('a saved pet whose files went missing falls back to another adopted pet', () async {
      settings.save(const LibraryState(
          currentPetId: 'builtin-broken', adoptedPetIds: ['builtin-broken', 'builtin-ragdoll']));
      await c.boot();
      expect(c.currentPet?.id, 'builtin-ragdoll');
      expect(settings.load().currentPetId, 'builtin-ragdoll');
    });

    test('...and with nobody usable left it behaves like a first run', () async {
      settings.save(const LibraryState(currentPetId: 'builtin-broken', adoptedPetIds: ['builtin-broken']));
      await c.boot();
      expect(c.currentPet, isNull);
      expect(settings.load(), const LibraryState(adoptedPetIds: ['builtin-broken']));
    });
  });

  group('adopt', () {
    test('pushes preparing, shows the pet, saves, pushes the result', () async {
      await c.boot();
      pushed.clear();
      await c.adopt('builtin-gold');
      expect(pushed.map((s) => (s.preparingPetId, s.currentPetId)), [
        ('builtin-gold', null),
        (null, 'builtin-gold'),
      ]);
      expect(player.plays, ['builtin-gold/stand.mp4|loop']);
      expect(settings.load(), const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
    });

    test('adopting the current pet again just re-announces the state', () async {
      await c.boot();
      await c.adopt('builtin-gold');
      pushed.clear();
      await c.adopt('builtin-gold');
      expect(pushed.single.currentPetId, 'builtin-gold');
      expect(player.plays, hasLength(1));
    });

    test('unknown and incomplete pets are refused', () async {
      await c.boot();
      await expectLater(c.adopt('nope'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'unknown_pet')));
      await expectLater(
          c.adopt('builtin-broken'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'missing_assets')));
    });

    test('a second adopt while one is preparing is busy', () async {
      await c.boot();
      player.gate = Completer<void>();
      final first = c.adopt('builtin-gold');
      await Future<void>.delayed(Duration.zero);
      await expectLater(c.adopt('builtin-ragdoll'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'busy')));
      player.gate!.complete();
      await first;
    });

    test('a failed prepare keeps the old pet and clears preparing', () async {
      settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      await c.boot();
      pushed.clear();
      ensure = (f) async => throw Exception('decode failed');
      await expectLater(
          c.adopt('builtin-ragdoll'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'prepare_failed')));
      expect(c.state, const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      expect(pushed.map((s) => s.preparingPetId), ['builtin-ragdoll', null]);
      expect(player.plays, ['builtin-gold/stand.mp4|loop']);
    });

    test('a preparation that never finishes fails after prepareTimeout and frees the pet window', () async {
      c = make(prepareTimeout: short);
      await c.boot();
      pushed.clear();
      ensure = (f) => Completer<File>().future; // a hung native prepare
      await expectLater(
          c.adopt('builtin-gold'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'prepare_failed')));
      expect(c.state, LibraryState.empty);
      expect(pushed.map((s) => s.preparingPetId), ['builtin-gold', null]);
      ensure = (f) async => f;
      await c.adopt('builtin-ragdoll'); // not busy
      expect(c.currentPet?.id, 'builtin-ragdoll');
      expect(player.plays, ['builtin-ragdoll/stand.mp4|loop']);
    }, timeout: failFast);

    test('a clip matted after the deadline is not put on screen', () async {
      c = make(prepareTimeout: short);
      await c.boot();
      final matte = Completer<File>();
      ensure = (f) => matte.future;
      await expectLater(c.adopt('builtin-gold'), throwsA(isA<AdoptError>()));
      matte.complete(File('${builtin.path}\\builtin-gold\\stand.mp4'));
      await Future<void>.delayed(Duration.zero);
      expect(player.plays, isEmpty);
      expect(c.currentPet, isNull);
    }, timeout: failFast);

    test('a failed save still shows the pet and announces it', () async {
      // A FILE where the settings folder should be: save() throws, load() still returns empty.
      final blocked = File('${tmp.path}\\blocked')..writeAsStringSync('x');
      settings = SettingsStore(Directory(blocked.path));
      c = make();
      await c.boot();
      pushed.clear();
      await c.adopt('builtin-gold');
      expect(c.state.currentPetId, 'builtin-gold');
      expect(pushed.last.currentPetId, 'builtin-gold');
      expect(player.plays, ['builtin-gold/stand.mp4|loop']);
    });
  });

  group('actions', () {
    setUp(() => settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold'])));

    test('a one-shot plays once and hands back to stand', () async {
      await c.boot();
      await c.playAction('lick_paw');
      expect(player.plays.last, 'builtin-gold/lick_paw.mp4|once');
      expect(c.currentAction, 'lick_paw');
      player.lastOnFinished!();
      await Future<void>.delayed(Duration.zero);
      expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
      expect(c.currentAction, 'stand');
    });

    test('choosing the looping action already on screen does nothing', () async {
      await c.boot();
      await c.playAction('stand');
      expect(player.plays, hasLength(1));
    });

    test('a failed action keeps the current one and shows a short message', () async {
      await c.boot();
      ensure = (f) async => throw Exception('decode failed');
      await c.playAction('sleep');
      expect(c.currentAction, 'stand');
      expect(c.error, contains('睡觉'));
    });

    test('an action whose clip never gets ready gives up with the message, and the next action plays', () async {
      c = make(prepareTimeout: short);
      await c.boot();
      ensure = (f) => Completer<File>().future;
      await c.playAction('sleep');
      expect(c.currentAction, 'stand');
      expect(c.error, contains('睡觉'));
      ensure = (f) async => f;
      await c.playAction('lick_paw');
      expect(player.plays.last, 'builtin-gold/lick_paw.mp4|once');
      expect(c.currentAction, 'lick_paw');
      expect(c.error, isNull);
    }, timeout: failFast);

    test('actions the pet does not have are ignored', () async {
      await c.boot();
      await c.playAction('backflip');
      expect(player.plays, hasLength(1));
    });
  });
}
