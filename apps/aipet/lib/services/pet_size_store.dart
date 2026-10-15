import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/pet_size.dart';

/// pet_size.json: how big the pet is on this computer. Its own file, not a
/// field of settings.json: settings sync to the account, and a size that
/// suits one screen does not follow the user to another. Only the pet window
/// (primary engine) uses it.
class PetSizeStore {
  PetSizeStore(this.root);

  final Directory root;

  File get file => File('${root.path}${Platform.pathSeparator}pet_size.json');

  /// Never throws; a missing or unreadable file is [PetSize.fallback].
  PetSize load() {
    if (!file.existsSync()) return PetSize.fallback;
    try {
      final j = jsonDecode(file.readAsStringSync());
      final s = j is Map<String, Object?> ? PetSize.byName(j['size']) : null;
      if (s == null) throw const FormatException('bad size');
      return s;
    } catch (e) {
      developer.log('pet_size.json unreadable ($e); using ${PetSize.fallback.name}', name: 'aipet.settings');
      return PetSize.fallback;
    }
  }

  /// Never throws: losing the size costs the user one more pick, not the app.
  void save(PetSize s) {
    try {
      root.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({'size': s.name}), flush: true);
      tmp.renameSync(file.path);
    } catch (e) {
      developer.log('saving pet_size.json failed: $e', name: 'aipet.settings');
    }
  }
}
