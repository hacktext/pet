import 'dart:async';
import 'dart:io';

import 'package:aipet/app/pet_window/pet_window_controller.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/pet.dart';
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
  late List<String> adoptions;

  PetWindowController make({Duration prepareTimeout = kPrepareTimeout, bool Function(Pet)? allows}) =>
      PetWindowController(
        library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
        settings: settings,
        ensure: (f) => ensure(f),
        player: player,
        push: (s) async => pushed.add(s),
        prepareTimeout: prepareTimeout,
        onAdopted: (id, firstTime) => adoptions.add('$id ${firstTime ? 'adopt' : 'switch'}'),
        allows: allows,
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
    adoptions = [];
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

  group('telemetry and sync', () {
    test('onAdopted: a first adoption, then a switch; not for the pet already there or a failure', () async {
      await c.boot();
      await c.adopt('builtin-gold');
      await c.adopt('builtin-ragdoll');
      await c.adopt('builtin-gold');
      await c.adopt('builtin-gold');
      ensure = (f) async => throw Exception('decode failed');
      await expectLater(c.adopt('builtin-ragdoll'), throwsA(isA<AdoptError>()));
      expect(adoptions, ['builtin-gold adopt', 'builtin-ragdoll adopt', 'builtin-gold switch']);
    });

    test("applySynced takes the account's list and puts its pet on the desktop", () async {
      settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      await c.boot();
      pushed.clear();
      await c.applySynced(const LibraryState(currentPetId: 'builtin-ragdoll', adoptedPetIds: ['builtin-ragdoll']));
      expect(c.state, const LibraryState(currentPetId: 'builtin-ragdoll', adoptedPetIds: ['builtin-ragdoll']));
      expect(settings.load(), c.state);
      expect(player.plays.last, 'builtin-ragdoll/stand.mp4|loop');
      expect(pushed.last, c.state);
      expect(adoptions, isEmpty, reason: 'a synced switch is not the user adopting');
    });

    test('applySynced: a pet this computer cannot show stays listed, the current one stays on', () async {
      settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      await c.boot();
      await c.applySynced(const LibraryState(currentPetId: 'custom-x', adoptedPetIds: ['custom-x']));
      expect(c.state, const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['custom-x', 'builtin-gold']));
      expect(player.plays, hasLength(1));
    });

    test('applySynced with nobody on the desktop on either side only changes the list', () async {
      await c.boot();
      await c.applySynced(const LibraryState(adoptedPetIds: ['builtin-gold']));
      expect(c.state, const LibraryState(adoptedPetIds: ['builtin-gold']));
      expect(player.plays, isEmpty);
    });
  });

  test('rescan picks up a pet folder that arrived after boot', () async {
    await c.boot();
    expect(c.pets.map((p) => p.id), isNot(contains('custom-7')));
    writePet(Directory('${tmp.path}\\custom'), id: 'custom-7', origin: 'custom', species: 'cat');
    var notified = 0;
    c.addListener(() => notified++);
    c.rescan();
    expect(c.pets.map((p) => p.id), contains('custom-7'));
    expect(notified, 1);
  });

  group('paid pets', () {
    late Set<String> owned;
    bool allows(Pet p) => p.origin != PetOrigin.paid || owned.contains(p.id.substring(5));

    setUp(() {
      owned = {'a'};
      writePet(Directory('${tmp.path}\\custom'), id: 'paid-a', origin: 'paid', species: 'girl');
      c = make(allows: allows);
    });

    test('a paid pet that is no longer owned leaves the desktop', () async {
      settings.save(const LibraryState(currentPetId: 'paid-a', adoptedPetIds: ['builtin-broken', 'builtin-gold', 'paid-a']));
      await c.boot();
      expect(c.currentPet?.id, 'paid-a');
      pushed.clear();
      owned = {};
      await c.evictLocked();
      expect(c.currentPet?.id, 'builtin-gold');
      expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
      expect(pushed.last, const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-broken', 'builtin-gold', 'paid-a']));
      expect(settings.load(), pushed.last, reason: 'the adopted list stays; owning it again makes it usable');
      expect(adoptions, isEmpty, reason: 'not the user adopting');
      await expectLater(
          c.adopt('paid-a'),
          throwsA(isA<AdoptError>()
              .having((e) => e.code, 'code', 'locked')
              .having((e) => e.message, 'message', '请先解锁')));
      expect(c.currentPet?.id, 'builtin-gold');

      owned = {'a'};
      await c.adopt('paid-a');
      expect(c.currentPet?.id, 'paid-a');
    });

    test('with no other pet allowed, nobody is on the desktop', () async {
      settings.save(const LibraryState(currentPetId: 'paid-a', adoptedPetIds: ['paid-a']));
      await c.boot();
      owned = {};
      await c.evictLocked();
      expect(c.currentPet, isNull);
      expect(c.state, const LibraryState(adoptedPetIds: ['paid-a']));
      expect(settings.load(), c.state);
      expect(pushed.last, c.state);
    });

    test('evictLocked leaves an allowed pet alone', () async {
      settings.save(const LibraryState(currentPetId: 'paid-a', adoptedPetIds: ['builtin-gold', 'paid-a']));
      await c.boot();
      pushed.clear();
      await c.evictLocked();
      expect(c.currentPet?.id, 'paid-a');
      expect(pushed, isEmpty);
      expect(player.plays, hasLength(1));
    });

    test('boot passes over a saved paid pet that is not owned, without playing it', () async {
      owned = {};
      settings.save(const LibraryState(currentPetId: 'paid-a', adoptedPetIds: ['paid-a', 'builtin-ragdoll']));
      await c.boot();
      expect(c.currentPet?.id, 'builtin-ragdoll');
      expect(player.plays, ['builtin-ragdoll/stand.mp4|loop']);
    });

    test('a sync naming a locked pet does not put it on', () async {
      owned = {};
      settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      await c.boot();
      await c.applySynced(const LibraryState(currentPetId: 'paid-a', adoptedPetIds: ['paid-a']));
      expect(c.currentPet?.id, 'builtin-gold');
      expect(player.plays, hasLength(1));
    });

    test('owned lost while it was being prepared: refused, and it leaves again', () async {
      settings.save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
      await c.boot();
      player.gate = Completer<void>();
      final adopting = c.adopt('paid-a');
      await Future<void>.delayed(Duration.zero);
      owned = {};
      await c.evictLocked(); // the owned change: the pet on the desktop is still allowed
      player.gate!.complete();
      await expectLater(adopting, throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'locked')));
      await c.evictLocked(); // queued behind the one the adopt started
      expect(c.currentPet?.id, 'builtin-gold');
      expect(c.state.preparingPetId, isNull);
    });
  });
}
