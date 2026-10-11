import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_downloader.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_downloads.dart';
import '../support/fake_http.dart';

/// A delivered pet as OSS holds it: path -> bytes.
Map<String, List<int>> _package(String petId, String name) => {
      'pet.json': utf8.encode(jsonEncode({
        'schema': 1,
        'id': petId,
        'name': name,
        'species': 'cat',
        'origin': 'custom',
        'cover': 'cover.png',
        'actions': ['stand', 'walk'],
      })),
      'cover.png': utf8.encode('png $petId'),
      'stand.mp4': utf8.encode('stand clip of $petId'),
      'walk.mp4': utf8.encode('walk clip of $petId'),
    };

void main() {
  late Directory tmp, pets;
  late FakeHttp http;
  late FakeDownloads files;
  late List<int>? Function(Uri) serveOk;
  late bool signedIn;
  late List<List<String>> installed;
  late CustomDownloader dl;
  late Map<String, Map<String, List<int>>> server; // petId -> package
  late List<Map<String, Object?>> deliveries;
  late int assetVersion; // the signed URLs the assets endpoint hands out
  late int liveVersion; // the signed URLs OSS still accepts

  void deliver(int id, String petId, {String name = '豆豆'}) {
    server[petId] = _package(petId, name);
    deliveries.add({'id': id, 'pet_id': petId, 'name': name, 'delivered_at': '2026-10-10 12:00:00'});
  }

  File staged(String petId, String path) => File('${pets.path}\\.downloading\\$petId\\$path');
  File installedFile(String petId, String path) => File('${pets.path}\\$petId\\$path');
  List<String> downloaded() => [for (final u in files.requested) Uri.parse(u).pathSegments.last];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('custom_dl_');
    pets = Directory('${tmp.path}\\pets');
    http = FakeHttp();
    files = FakeDownloads();
    signedIn = true;
    installed = [];
    server = {};
    deliveries = [];
    assetVersion = 1;
    liveVersion = 1;
    final assetsPath = RegExp(r'^/api/aipet/custom/requests/(\d+)/assets$');
    http.reply = (r) {
      if (r.url.path == '/api/aipet/custom/deliveries') return FakeHttp.ok(deliveries);
      final m = assetsPath.firstMatch(r.url.path);
      if (m == null) return FakeHttp.fail(404, 'not found', null, 404);
      final d = deliveries.firstWhere((d) => '${d['id']}' == m.group(1));
      final petId = d['pet_id']! as String;
      return FakeHttp.ok({
        'pet_id': petId,
        'files': [
          for (final MapEntry(key: path, value: bytes) in server[petId]!.entries)
            {
              'path': path,
              'bytes': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
              'url': 'https://oss.test/v$assetVersion/$petId/$path?sig=x',
            },
        ],
      });
    };
    serveOk = (u) {
      final s = u.pathSegments; // [v1, custom-7, stand.mp4]
      if (s.first != 'v$liveVersion') return null;
      return server[s[1]]?[s.sublist(2).join('/')];
    };
    files.serve = serveOk;
    dl = CustomDownloader(
      api: ApiClient(http, baseUrl: 'https://x.test', token: () => 't'),
      transport: files,
      petsRoot: pets,
      signedIn: () => signedIn,
      onInstalled: (ds) async => installed.add([for (final d in ds) d.petId]),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a delivered pet is downloaded, verified, installed and announced', () async {
    deliver(7, 'custom-7');
    await dl.run();
    expect([for (final r in http.sent) '${r.method} ${r.url.path}'],
        ['GET /api/aipet/custom/deliveries', 'GET /api/aipet/custom/requests/7/assets']);
    expect(http.sent.first.headers['Authorization'], 'Bearer t');
    expect(installed, [['custom-7']]);
    final pet = PetLibrary(builtinRoot: Directory('${tmp.path}\\none'), customRoot: pets).scan().single;
    expect((pet.id, pet.name, pet.isComplete), ('custom-7', '豆豆', true));
    expect(Directory('${pets.path}\\.downloading\\custom-7').existsSync(), isFalse);
  });

  test('a delivered pet already here and complete is not asked about again', () async {
    deliver(7, 'custom-7');
    await dl.run();
    http.sent.clear();
    files.requested.clear();
    await dl.run();
    expect([for (final r in http.sent) r.url.path], ['/api/aipet/custom/deliveries']);
    expect(files.requested, isEmpty);
    expect(installed, hasLength(1));
  });

  test('quit mid-download: the next run fetches only what is missing or half-written', () async {
    deliver(7, 'custom-7');
    final pkg = server['custom-7']!;
    staged('custom-7', 'pet.json')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(pkg['pet.json']!);
    staged('custom-7', 'cover.png').writeAsBytesSync(pkg['cover.png']!);
    File('${staged('custom-7', 'stand.mp4').path}.part').writeAsBytesSync(pkg['stand.mp4']!.sublist(0, 3));
    staged('custom-7', 'walk.mp4').writeAsBytesSync([1, 2, 3]); // wrong bytes from an older attempt
    await dl.run();
    expect(downloaded()..sort(), ['stand.mp4', 'walk.mp4']);
    expect(installed, [['custom-7']]);
    expect(installedFile('custom-7', 'walk.mp4').readAsBytesSync(), pkg['walk.mp4']);
    expect(File('${installedFile('custom-7', 'stand.mp4').path}.part').existsSync(), isFalse);
  });

  test('staged files the current manifest does not list are not installed', () async {
    deliver(7, 'custom-7');
    final pkg = server['custom-7']!;
    staged('custom-7', 'pet.json')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(pkg['pet.json']!);
    staged('custom-7', 'run.mp4').writeAsStringSync('an action an older manifest had');
    File('${staged('custom-7', 'jump.mp4').path}.part').writeAsStringSync('half of another old one');
    File('${pets.path}\\.downloading\\custom-7\\old\\x.wav')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('old voice');
    await dl.run();
    expect(installed, [['custom-7']]);
    final names = [
      for (final e in Directory('${pets.path}\\custom-7').listSync(recursive: true))
        e.path.substring(pets.path.length + 'custom-7'.length + 2).replaceAll('\\', '/'),
    ]..sort();
    expect(names, ['cover.png', 'pet.json', 'stand.mp4', 'walk.mp4']);
  });

  test('one file failing its sha256: nothing installed, the good files kept, the next run fetches only that one',
      () async {
    deliver(7, 'custom-7');
    files.serve = (u) => u.path.endsWith('/walk.mp4') ? utf8.encode('corrupted') : serveOk(u);
    await dl.run();
    expect(installed, isEmpty);
    expect(installedFile('custom-7', 'pet.json').existsSync(), isFalse);
    expect(staged('custom-7', 'stand.mp4').existsSync(), isTrue);
    expect(staged('custom-7', 'walk.mp4').existsSync(), isFalse);
    expect(File('${staged('custom-7', 'walk.mp4').path}.part').existsSync(), isFalse);
    files
      ..serve = serveOk
      ..requested.clear();
    await dl.run();
    expect(downloaded(), ['walk.mp4']);
    expect(installed, [['custom-7']]);
  });

  test('an incomplete folder already there is replaced whole; the user deleting it brings it back', () async {
    deliver(7, 'custom-7');
    final half = Directory('${pets.path}\\custom-7')..createSync(recursive: true);
    File('${half.path}\\pet.json').writeAsBytesSync(server['custom-7']!['pet.json']!);
    File('${half.path}\\stale.txt').writeAsStringSync('from an old, broken copy');
    await dl.run();
    expect(installed, [['custom-7']]);
    expect(File('${half.path}\\stale.txt').existsSync(), isFalse);
    expect(installedFile('custom-7', 'walk.mp4').existsSync(), isTrue);
    expect(Directory('${pets.path}\\.old-custom-7').existsSync(), isFalse);

    half.deleteSync(recursive: true);
    await dl.run();
    expect(installed, [['custom-7'], ['custom-7']]);
    expect(installedFile('custom-7', 'walk.mp4').existsSync(), isTrue);
  });

  test('a signed URL that expired: quiet now, and the next run asks for fresh URLs', () async {
    deliver(7, 'custom-7');
    liveVersion = 2; // what the assets endpoint hands out (v1) no longer works
    await dl.run();
    expect(installed, isEmpty);
    assetVersion = 2;
    await dl.run();
    expect(http.to('/api/aipet/custom/requests/7/assets'), hasLength(2));
    expect(installed, [['custom-7']]);
  });

  test('two triggers at once share one pass; those arriving mid-pass make one more pass after it', () async {
    deliver(7, 'custom-7');
    files.gate = Completer<void>();
    final a = dl.run();
    while (files.requested.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(dl.running, isTrue);
    final b = dl.run(); // login ...
    final c = dl.run(); // ... and its sync
    expect(identical(a, b) && identical(a, c), isTrue);
    files.gate!.complete();
    await a;
    expect(dl.running, isFalse);
    expect(http.to('/api/aipet/custom/deliveries'), hasLength(2));
    expect(downloaded()..sort(), ['cover.png', 'pet.json', 'stand.mp4', 'walk.mp4']);
    expect(installed, [['custom-7']]);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('a trigger at any moment as a pass winds down is never lost', () async {
    // The trigger lands n microtasks after the last await of the pass -- for
    // some n that is between the loop deciding to stop and the run being
    // marked finished. Every n must still produce exactly one more pass.
    for (var n = 0; n < 80; n++) {
      http.sent.clear();
      deliveries.clear();
      Future<void>? trailing;
      var fired = false;
      final d = CustomDownloader(
        api: ApiClient(http, baseUrl: 'https://x.test', token: () => 't'),
        transport: files,
        petsRoot: pets,
        signedIn: () => true,
        onInstalled: (_) async {},
      );
      // The pass's last await is the deliveries call; trigger from its reply.
      http.reply = (r) {
        if (!fired) {
          fired = true;
          void hop(int left) {
            if (left == 0) {
              trailing = d.run();
            } else {
              scheduleMicrotask(() => hop(left - 1));
            }
          }

          scheduleMicrotask(() => hop(n));
        }
        return FakeHttp.ok(deliveries);
      };
      await d.run();
      for (var i = 0; i < 100 && trailing == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(trailing, isNotNull, reason: 'n=$n');
      await trailing;
      expect(http.to('/api/aipet/custom/deliveries'), hasLength(2), reason: 'n=$n');
      expect(d.running, isFalse, reason: 'n=$n');
    }
  });

  test('signed out: not a single request', () async {
    signedIn = false;
    deliver(7, 'custom-7');
    await dl.run();
    expect(http.sent, isEmpty);
    expect(files.requested, isEmpty);
  });

  test('files that do not add up to a whole pet are not installed', () async {
    deliver(7, 'custom-7');
    server['custom-7']!.remove('walk.mp4'); // pet.json still lists walk
    await dl.run();
    expect(installed, isEmpty);
    expect(Directory('${pets.path}\\custom-7').existsSync(), isFalse);
  });

  test('a bad manifest or a server error skips that pet quietly; the others still come', () async {
    deliver(7, 'custom-7');
    deliver(8, 'custom-8', name: '旺财');
    final normal = http.reply;
    http.reply = (r) => r.url.path.endsWith('/7/assets')
        ? FakeHttp.ok({
            'pet_id': 'custom-7',
            'files': [
              {'path': '../evil.exe', 'bytes': 1, 'sha256': 'a' * 64, 'url': 'https://oss.test/v1/evil'},
            ],
          })
        : normal(r);
    await dl.run();
    expect(installed, [['custom-8']]);
    expect(File('${tmp.path}\\evil.exe').existsSync(), isFalse);
    expect(File('${pets.path}\\.downloading\\evil.exe').existsSync(), isFalse);
    expect(Directory('${pets.path}\\custom-7').existsSync(), isFalse);
    expect(Directory('${pets.path}\\.downloading\\custom-7').existsSync(), isFalse);
    expect(files.requested.where((u) => u.contains('custom-7')), isEmpty);

    // custom-7 still missing, so each run below asks again -- and fails.
    final before = pets.listSync().map((e) => e.path).toSet();
    files.requested.clear();
    http.reply = (_) => throw Exception('offline');
    await expectLater(dl.run(), completes);
    http.reply = (_) => FakeHttp.fail(1003, 'x', null, 401);
    await expectLater(dl.run(), completes);
    http.reply = (r) => r.url.path.endsWith('/assets') ? FakeHttp.fail(404, 'x', null, 404) : normal(r);
    await expectLater(dl.run(), completes);
    expect(installed, [['custom-8']]);
    expect(files.requested, isEmpty);
    expect(pets.listSync().map((e) => e.path).toSet(), before);
    expect(dl.running, isFalse);
  });
}
