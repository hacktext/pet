import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/library_state.dart';

/// settings.json (spec 4.3). Only the pet window (primary engine) may use
/// this: two engines writing one file would overwrite each other.
class SettingsStore {
  SettingsStore(this.root);

  final Directory root;

  File get file => File('${root.path}${Platform.pathSeparator}settings.json');

  /// Never throws. A missing file is a first run; an unreadable one is kept
  /// as settings.json.bad for diagnosis and also treated as a first run.
  LibraryState load() {
    if (!file.existsSync()) return LibraryState.empty;
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map<String, Object?> || j['schema'] != 1) throw const FormatException('bad schema');
      final current = j['currentPetId'];
      final adopted = j['adoptedPetIds'];
      if (current != null && current is! String) throw const FormatException('bad currentPetId');
      if (adopted is! List<Object?> || adopted.any((v) => v is! String)) throw const FormatException('bad adoptedPetIds');
      final ids = adopted.cast<String>().toList();
      if (current is String && !ids.contains(current)) ids.add(current);
      return LibraryState(currentPetId: current as String?, adoptedPetIds: ids);
    } catch (e) {
      developer.log('settings.json unreadable ($e); quarantined as .bad', name: 'aipet.settings');
      final bad = File('${file.path}.bad');
      if (bad.existsSync()) bad.deleteSync();
      file.renameSync(bad.path);
      return LibraryState.empty;
    }
  }

  void save(LibraryState s) {
    root.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      jsonEncode({'schema': 1, 'currentPetId': s.currentPetId, 'adoptedPetIds': s.adoptedPetIds}),
      flush: true,
    );
    tmp.renameSync(file.path); // replaces the old file; never a half-written settings.json
  }
}
