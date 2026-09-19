import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/pet_stats.dart';

/// stats.json (spec 2026-09-19 E 3.3): every adopted pet's stats. Only the
/// pet window writes it, like settings.json.
class StatsStore {
  StatsStore(this.root);

  final Directory root;

  File get file => File('${root.path}${Platform.pathSeparator}stats.json');

  /// Never throws. An unreadable file is kept as stats.json.bad and treated
  /// as empty; a single bad entry is dropped.
  Map<String, PetStats> load() {
    if (!file.existsSync()) return {};
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map<String, Object?> || j['schema'] != 1 || j['pets'] is! Map<String, Object?>) {
        throw const FormatException('bad schema');
      }
      final out = <String, PetStats>{};
      for (final e in (j['pets']! as Map<String, Object?>).entries) {
        try {
          out[e.key] = PetStats.fromJson(e.value! as Map<Object?, Object?>);
        } catch (err) {
          developer.log('stats for ${e.key} dropped ($err)', name: 'aipet.stats');
        }
      }
      return out;
    } catch (e) {
      developer.log('stats.json unreadable ($e); quarantined as .bad', name: 'aipet.stats');
      try {
        final bad = File('${file.path}.bad');
        if (bad.existsSync()) bad.deleteSync();
        file.renameSync(bad.path);
      } catch (quarantineError) {
        developer.log('quarantine failed ($quarantineError)', name: 'aipet.stats');
      }
      return {};
    }
  }

  void save(Map<String, PetStats> all) {
    root.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      jsonEncode({'schema': 1, 'pets': {for (final e in all.entries) e.key: e.value.toJson()}}),
      flush: true,
    );
    tmp.renameSync(file.path); // never a half-written stats.json
  }
}
