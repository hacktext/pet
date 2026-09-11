import 'dart:developer' as developer;
import 'dart:io';

import '../domain/pet.dart';

/// Every pet folder the app can see: read-only built-ins shipped with the app,
/// then custom pets downloaded into %APPDATA% (sub-project C). Both engines may
/// scan; neither writes here.
class PetLibrary {
  PetLibrary({required this.builtinRoot, required this.customRoot});

  final Directory builtinRoot;
  final Directory customRoot;

  List<Pet> scan() {
    final pets = <Pet>[];
    final seen = <String>{};
    for (final (root, origin) in [(builtinRoot, PetOrigin.builtin), (customRoot, PetOrigin.custom)]) {
      for (final pet in _scanRoot(root, origin)) {
        if (seen.add(pet.id)) pets.add(pet);
      }
    }
    return pets;
  }

  static Pet? byId(Iterable<Pet> pets, String id) {
    for (final p in pets) {
      if (p.id == id) return p;
    }
    return null;
  }

  // One bad folder (a broken download, a hand-edited pet.json) must not hide
  // every other pet, so failures are logged and skipped.
  List<Pet> _scanRoot(Directory root, PetOrigin origin) {
    if (!root.existsSync()) return const [];
    final dirs = root.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path));
    final out = <Pet>[];
    for (final dir in dirs) {
      final json = File('${dir.path}${Platform.pathSeparator}pet.json');
      if (!json.existsSync()) continue;
      try {
        final pet = parsePet(json.readAsStringSync(), dir);
        if (pet.origin != origin) throw FormatException('origin ${pet.origin.name} under the ${origin.name} root');
        out.add(pet);
      } catch (e) {
        developer.log('skipping ${dir.path}: $e', name: 'aipet.library');
      }
    }
    return out;
  }
}
