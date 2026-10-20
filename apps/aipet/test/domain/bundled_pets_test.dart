import 'dart:io';

import 'package:aipet/domain/pet.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pets shipped in assets/pets: a folder pubspec.yaml does not list (each
/// `voices/<id>/` needs its own line -- Flutter does not recurse) is left out of
/// the build without a word, and the pet shows as 素材缺失.
void main() {
  final root = Directory('assets/pets');
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final folders = root.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
  String name(FileSystemEntity e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last;

  test('four built-in characters: girls, a boy and an anime girl', () {
    final pets = [for (final d in folders) parsePet(File('${d.path}/pet.json').readAsStringSync(), d)];
    expect(pets.where((p) => p.species.isCharacter).map((p) => p.id),
        unorderedEquals(['builtin-xiaoya', 'builtin-lingyin', 'builtin-linyang', 'builtin-xiaoyou']));
    expect({for (final p in pets.where((p) => p.species.isCharacter)) p.species},
        {Species.girl, Species.boy, Species.anime});
  });

  for (final d in folders) {
    test('${name(d)} is complete and listed in pubspec.yaml', () {
      final pet = parsePet(File('${d.path}/pet.json').readAsStringSync(), d);
      expect(pet.id, name(d));
      expect(pet.origin, PetOrigin.builtin);
      expect(pet.isComplete, isTrue);
      expect(pet.actions.first, kIdleAction);
      expect(pet.cardFile?.existsSync(), isTrue, reason: 'the library card shows its close-up');
      expect(pet.tags, isNotEmpty);
      expect(pubspec, contains('- assets/pets/${name(d)}/\n'));
      for (final v in pet.voices) {
        expect(pubspec, contains('- assets/pets/${name(d)}/voices/${v.id}/\n'));
        for (final a in pet.actions.where((a) => !isLooping(a))) {
          expect(pet.voiceLines(v.id, a), isNotEmpty, reason: '${v.id} says nothing over $a');
        }
      }
    });
  }
}
