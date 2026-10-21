import 'dart:convert';
import 'dart:io';

import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/pet_installer.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_downloads.dart';

Map<String, List<int>> _package(String petId, String origin) => {
      'pet.json': utf8.encode(jsonEncode({
        'schema': 1,
        'id': petId,
        'name': 'x',
        'species': 'cat',
        'origin': origin,
        'cover': 'cover.png',
        'actions': ['stand', 'walk'],
      })),
      'cover.png': utf8.encode('png $petId'),
      'stand.mp4': utf8.encode('stand clip of $petId'),
      'walk.mp4': utf8.encode('walk clip of $petId'),
    };

CustomAssets _assets(String petId, Map<String, List<int>> pkg) => CustomAssets(petId: petId, files: [
      for (final e in pkg.entries)
        CustomAsset(
          path: e.key,
          bytes: e.value.length,
          sha256: sha256.convert(e.value).toString(),
          url: 'https://oss.test/$petId/${e.key}?sig=x',
        ),
    ]);

void main() {
  late Directory tmp, pets;
  late FakeDownloads files;
  late PetInstaller installer;
  late Map<String, List<int>> pkg;
  const id = 'paid-suwan';

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('pet_installer_');
    pets = Directory('${tmp.path}/pets');
    files = FakeDownloads();
    installer = PetInstaller(petsRoot: pets, transport: files);
    pkg = _package(id, 'paid');
    files.serve = (u) => pkg[u.pathSegments.last];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> downloaded() => [for (final u in files.requested) Uri.parse(u).pathSegments.last];

  test('installs a complete pet and reports progress per verified file', () async {
    final seen = <String>[];
    final ok = await installer.install(_assets(id, pkg),
        origin: PetOrigin.paid, keepGoing: () => true, onProgress: (d, t) => seen.add('$d/$t'));
    expect(ok, isTrue);
    expect(seen, ['1/4', '2/4', '3/4', '4/4']);
    expect(await PetInstaller.isInstalled(pets, id, PetOrigin.paid), isTrue);
    expect(await PetInstaller.isInstalled(pets, id, PetOrigin.custom), isFalse);
  });

  test('resumes from the files already verified', () async {
    final names = pkg.keys.toList();
    final failing = names[1];
    var broken = true;
    files.serve = (u) => u.pathSegments.last == failing && broken ? null : pkg[u.pathSegments.last];
    final seen = <int>[];
    expect(await installer.install(_assets(id, pkg), origin: PetOrigin.paid, keepGoing: () => true, onProgress: (d, t) => seen.add(d)), isFalse);
    expect(seen, [1, 2, 3]); // the failed file is not counted
    expect(Directory('${pets.path}/$id').existsSync(), isFalse);

    broken = false;
    files.requested.clear();
    expect(await installer.install(_assets(id, pkg), origin: PetOrigin.paid, keepGoing: () => true), isTrue);
    expect(downloaded(), [failing]);
    expect(await PetInstaller.isInstalled(pets, id, PetOrigin.paid), isTrue);
  });

  test('a file already staged and matching still counts toward progress', () async {
    var calls = 0;
    await installer.install(_assets(id, pkg), origin: PetOrigin.paid, keepGoing: () => ++calls <= 2);
    files.requested.clear();
    final seen = <int>[];
    await installer.install(_assets(id, pkg), origin: PetOrigin.paid, keepGoing: () => true, onProgress: (d, t) => seen.add(d));
    expect(seen, [1, 2, 3, 4]);
    expect(downloaded().length, 2);
  });

  test('refuses a manifest whose pet.json origin does not match', () async {
    pkg = _package(id, 'custom');
    expect(await installer.install(_assets(id, pkg), origin: PetOrigin.paid, keepGoing: () => true), isFalse);
    expect(Directory('${pets.path}/$id').existsSync(), isFalse);
  });

  test('stops when keepGoing turns false, keeping what was verified', () async {
    var n = 0;
    expect(await installer.install(_assets(id, pkg), origin: PetOrigin.paid, keepGoing: () => n++ < 2), isFalse);
    expect(Directory('${pets.path}/$id').existsSync(), isFalse);
    expect(File('${pets.path}/.downloading/$id/${pkg.keys.first}').existsSync(), isTrue);
  });
}
