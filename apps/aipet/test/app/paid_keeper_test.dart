import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aipet/app/pet_window/paid_keeper.dart';
import 'package:aipet/app/pet_window/pet_window_controller.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/catalog_store.dart';
import 'package:aipet/services/character_service.dart';
import 'package:aipet/services/pet_installer.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/settings_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_downloads.dart';
import '../support/fake_http.dart';
import '../support/fake_player.dart';
import '../support/pet_fixtures.dart';

Map<String, List<int>> _package(String petId) => {
      'pet.json': utf8.encode(jsonEncode({
        'schema': 1,
        'id': petId,
        'name': '苏晚',
        'species': 'girl',
        'origin': 'paid',
        'cover': 'cover.png',
        'actions': ['stand'],
      })),
      'cover.png': kTinyPng,
      'stand.mp4': utf8.encode('stand clip of $petId'),
    };

/// One owned character as GET /api/aipet/characters/owned sends it.
Map<String, Object?> _item(String code) =>
    {'code': code, 'name': code, 'species': 'girl', 'price_cents': 1990, 'card_url': null};

void main() {
  late Directory tmp, appData, pets;
  late FakeHttp http;
  late FakeDownloads files;
  late CatalogStore store;
  late bool signedIn;
  late int? userId;
  late Map<String, List<int>> pkg;
  late List<String> progress, installed;

  PaidKeeper make() => PaidKeeper(
        CharacterService(ApiClient(http, baseUrl: 'https://x.test', token: () => 't')),
        PetInstaller(petsRoot: pets, transport: files),
        store,
        signedIn: () => signedIn,
        userId: () => userId,
        onProgress: (code, done, total) => progress.add('$code $done/$total'),
        onInstalled: (code) async => installed.add(code),
      );

  Map<String, Object?> assetsJson() => {
        'pet_id': 'paid-suwan',
        'files': [
          for (final e in pkg.entries)
            {
              'path': e.key,
              'bytes': e.value.length,
              'sha256': sha256.convert(e.value).toString(),
              'url': 'https://oss.test/paid-suwan/${e.key}',
            },
        ],
      };

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('paid_keeper_');
    appData = Directory('${tmp.path}/appdata');
    pets = Directory('${tmp.path}/pets');
    store = CatalogStore(appData)..save(const []);
    http = FakeHttp();
    files = FakeDownloads();
    signedIn = true;
    userId = 7;
    progress = [];
    installed = [];
    pkg = _package('paid-suwan');
    files.serve = (u) => pkg[u.pathSegments.last];
    http.reply = (r) => switch (r.url.path) {
          '/api/aipet/characters/owned' => FakeHttp.ok([_item('suwan')]),
          '/api/aipet/characters/suwan/assets' => FakeHttp.ok(assetsJson()),
          _ => const HttpReply(403, 'Forbidden'),
        };
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('starts from owned.json, and a refresh replaces it, saves it and notifies', () async {
    store.saveOwned({'guchen'});
    final k = make();
    expect(k.owned, {'guchen'});
    var notified = 0;
    k.addListener(() => notified++);
    await k.refresh();
    expect(k.owned, {'suwan'});
    expect(store.load()!.owned, {'suwan'});
    expect(notified, 1);
    await k.refresh(); // the same answer is no change
    expect(notified, 1);
  });

  test('owned.json alone is enough: with catalog.json gone, boot keeps the paid pet', () async {
    store.saveOwned({'suwan'});
    File('${appData.path}/catalog/catalog.json').deleteSync();
    final k = make();
    expect(k.owned, {'suwan'});

    writePet(pets, id: 'paid-suwan', origin: 'paid', species: 'girl');
    final settings = SettingsStore(appData)
      ..save(const LibraryState(currentPetId: 'paid-suwan', adoptedPetIds: ['builtin-gold', 'paid-suwan']));
    final builtin = Directory('${tmp.path}/builtin')..createSync();
    writePet(builtin, id: 'builtin-gold');
    final c = PetWindowController(
      library: PetLibrary(builtinRoot: builtin, customRoot: pets),
      settings: settings,
      ensure: (f) async => f,
      player: FakePlayer(),
      push: (_) async {},
      allows: k.allows,
    );
    await c.boot();
    expect(c.currentPet?.id, 'paid-suwan');
    expect(settings.load().currentPetId, 'paid-suwan');
  });

  test('offline, or with the login expired, a refresh keeps the cached owned', () async {
    store.saveOwned({'suwan'});
    final k = make();
    http.reply = (_) => throw Exception('down');
    await k.refresh();
    expect(k.owned, {'suwan'});
    http.reply = (_) => FakeHttp.fail(1003, '请登录');
    await k.refresh();
    expect(k.owned, {'suwan'});
    expect(store.load()!.owned, {'suwan'});
  });

  test('signed out, a refresh does not ask', () async {
    signedIn = false;
    await make().refresh();
    expect(http.sent, isEmpty);
  });

  test('signedOut clears owned, here and in owned.json, and an answer still on its way is dropped', () async {
    final k = make();
    await k.refresh();
    final slow = Completer<HttpReply>();
    http.reply = (_) => slow.future;
    final pending = k.refresh();
    var notified = 0;
    k.addListener(() => notified++);
    k.signedOut();
    expect(k.owned, isEmpty);
    expect(store.load()!.owned, isEmpty);
    slow.complete(FakeHttp.ok([_item('suwan')]));
    await pending;
    expect(k.owned, isEmpty);
    expect(notified, 1);
  });

  test('a failed save keeps the owned set for this run', () async {
    final k = make();
    Directory('${appData.path}/catalog').deleteSync(recursive: true);
    File('${appData.path}/catalog').writeAsStringSync('in the way'); // catalog/ cannot be created
    await k.refresh();
    expect(k.owned, {'suwan'});
  });

  test('allows: free pets always, a paid pet only while owned', () async {
    writePet(pets, id: 'paid-suwan', origin: 'paid', species: 'girl');
    writePet(pets, id: 'paid-guchen', origin: 'paid', species: 'boy');
    writePet(pets, id: 'custom-1', origin: 'custom');
    final found = PetLibrary(builtinRoot: Directory('${tmp.path}/none'), customRoot: pets).scan();
    Pet pet(String id) => found.firstWhere((p) => p.id == id);
    final k = make();
    expect(k.allows(pet('paid-suwan')), isFalse);
    await k.refresh();
    expect(k.allows(pet('paid-suwan')), isTrue);
    expect(k.allows(pet('paid-guchen')), isFalse);
    expect(k.allows(pet('custom-1')), isTrue);
    writePet(pets, id: 'x', origin: 'paid'); // a hand-made folder not named paid-<code>
    final odd = PetLibrary(builtinRoot: Directory('${tmp.path}/none'), customRoot: pets).scan();
    expect(k.allows(odd.firstWhere((p) => p.id == 'x')), isFalse); // no RangeError
  });

  test('download of a character not owned asks the server once, and is false when it is not', () async {
    final k = make();
    http.reply = (r) => r.url.path.endsWith('/owned') ? FakeHttp.ok([_item('guchen')]) : const HttpReply(403, 'Forbidden');
    expect(await k.download('suwan'), isFalse);
    expect([for (final r in http.sent) r.url.path], ['/api/aipet/characters/owned']);
    expect(files.requested, isEmpty);
    expect(k.owned, {'guchen'});
  });

  test('download of a code bought a moment ago (owned not refreshed yet) refreshes, then downloads', () async {
    final k = make();
    expect(k.owned, isEmpty);
    expect(await k.download('suwan'), isTrue);
    expect([for (final r in http.sent) r.url.path],
        ['/api/aipet/characters/owned', '/api/aipet/characters/suwan/assets']);
    expect(installed, ['suwan']);
  });

  test('signed out, download of a code not owned is false and asks nothing', () async {
    signedIn = false;
    expect(await make().download('suwan'), isFalse);
    expect(http.sent, isEmpty);
  });

  test('owned.json records whose it is; the older bare list reads as an unknown owner', () async {
    final k = make();
    await k.refresh();
    expect(store.loadOwnedBy().userId, 7);
    expect(store.loadOwnedBy().owned, {'suwan'});
    File('${appData.path}/catalog/owned.json').writeAsStringSync('["guchen"]');
    expect(store.loadOwnedBy().userId, null);
    expect(store.loadOwnedBy().owned, {'guchen'});
    expect(make().owned, {'guchen'});
  });

  test('another user signing in: the cached owned goes before the server is asked', () async {
    store.saveOwned({'guchen'}, userId: 7);
    final k = make();
    expect(k.owned, {'guchen'});
    final slow = Completer<HttpReply>();
    http.reply = (_) => slow.future;
    userId = 8;
    final pending = k.signedIn(8);
    expect(k.owned, isEmpty); // not the previous account's, even offline
    expect(store.loadOwnedBy().owned, isEmpty);
    slow.complete(FakeHttp.ok([_item('suwan')]));
    await pending;
    expect(k.owned, {'suwan'});
    expect(store.loadOwnedBy().userId, 8);
    expect(store.loadOwnedBy().owned, {'suwan'});
  });

  test('the same user, or an unknown owner, signing in keeps the cached owned while asking', () async {
    store.saveOwned({'guchen'}, userId: 7);
    final k = make();
    http.reply = (_) => throw Exception('down');
    await k.signedIn(7);
    expect(k.owned, {'guchen'});
    File('${appData.path}/catalog/owned.json').writeAsStringSync('["guchen"]');
    final old = make();
    await old.signedIn(8);
    expect(old.owned, {'guchen'});
  });

  test('download installs paid-<code> with progress per file, then onInstalled, then true', () async {
    final k = make();
    await k.refresh();
    expect(await k.download('suwan'), isTrue);
    expect(progress, ['suwan 1/3', 'suwan 2/3', 'suwan 3/3']);
    expect(installed, ['suwan']);
    expect(await PetInstaller.isInstalled(pets, 'paid-suwan', PetOrigin.paid), isTrue);
  });

  test('a second download while one runs shares it; a later one runs again', () async {
    final k = make();
    await k.refresh();
    files.gate = Completer<void>();
    final a = k.download('suwan');
    final b = k.download('suwan');
    expect(identical(a, b), isTrue);
    files.gate!.complete();
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(http.to('/api/aipet/characters/suwan/assets'), hasLength(1));
    expect(installed, ['suwan']);
    expect(await k.download('suwan'), isTrue);
    expect(http.to('/api/aipet/characters/suwan/assets'), hasLength(2));
  });

  test('a failed download is false and installs nothing', () async {
    final k = make();
    await k.refresh();
    files.serve = (_) => null;
    expect(await k.download('suwan'), isFalse);
    http.reply = (r) => r.url.path.endsWith('/owned') ? FakeHttp.ok([_item('suwan')]) : const HttpReply(403, 'Forbidden');
    expect(await k.download('suwan'), isFalse);
    expect(installed, isEmpty);
    expect(Directory('${pets.path}/paid-suwan').existsSync(), isFalse);
  });

  test('assets for some other pet are refused', () async {
    final k = make();
    await k.refresh();
    pkg = _package('paid-other');
    http.reply = (r) => r.url.path.endsWith('/owned')
        ? FakeHttp.ok([_item('suwan')])
        : FakeHttp.ok({...assetsJson(), 'pet_id': 'paid-other'});
    expect(await k.download('suwan'), isFalse);
    expect(files.requested, isEmpty);
  });

  test('signing out mid-download stops it', () async {
    final k = make();
    await k.refresh();
    files.gate = Completer<void>();
    final d = k.download('suwan');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    k.signedOut();
    files.gate!.complete();
    expect(await d, isFalse);
    expect(Directory('${pets.path}/paid-suwan').existsSync(), isFalse);
  });
}
