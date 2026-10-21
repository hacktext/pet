import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aipet/app/pet_window/paid_keeper.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/catalog_store.dart';
import 'package:aipet/services/character_service.dart';
import 'package:aipet/services/pet_installer.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_downloads.dart';
import '../support/fake_http.dart';
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

void main() {
  late Directory tmp, appData, pets;
  late FakeHttp http;
  late FakeDownloads files;
  late CatalogStore store;
  late bool signedIn;
  late Map<String, List<int>> pkg;
  late List<String> progress, installed;

  PaidKeeper make() => PaidKeeper(
        CharacterService(ApiClient(http, baseUrl: 'https://x.test', token: () => 't')),
        PetInstaller(petsRoot: pets, transport: files),
        store,
        signedIn: () => signedIn,
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
    progress = [];
    installed = [];
    pkg = _package('paid-suwan');
    files.serve = (u) => pkg[u.pathSegments.last];
    http.reply = (r) => switch (r.url.path) {
          '/api/aipet/characters/owned' => FakeHttp.ok(['suwan']),
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
    slow.complete(FakeHttp.ok(['suwan']));
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
  });

  test('download of a character not owned is false and asks nothing', () async {
    final k = make();
    expect(await k.download('suwan'), isFalse);
    expect(http.sent, isEmpty);
    expect(files.requested, isEmpty);
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
    http.reply = (r) => r.url.path.endsWith('/owned') ? FakeHttp.ok(['suwan']) : const HttpReply(403, 'Forbidden');
    expect(await k.download('suwan'), isFalse);
    expect(installed, isEmpty);
    expect(Directory('${pets.path}/paid-suwan').existsSync(), isFalse);
  });

  test('assets for some other pet are refused', () async {
    final k = make();
    await k.refresh();
    pkg = _package('paid-other');
    http.reply = (r) => r.url.path.endsWith('/owned')
        ? FakeHttp.ok(['suwan'])
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
