import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// needs.json: when the pet was last fed, so a meal served before a restart
/// is not asked for again after it. Local only; only the pet window uses it.
class NeedsStore {
  NeedsStore(this.root);

  final Directory root;

  File get file => File('${root.path}${Platform.pathSeparator}needs.json');

  /// Never throws; missing or unreadable is "never fed".
  DateTime? lastServed() {
    try {
      if (!file.existsSync()) return null;
      final j = jsonDecode(file.readAsStringSync());
      final ms = j is Map<String, Object?> ? j['lastServedAt'] : null;
      return ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
    } catch (e) {
      developer.log('needs.json unreadable: $e', name: 'aipet.needs');
      return null;
    }
  }

  /// Never throws: losing it only means one more request for food.
  void served(DateTime at) {
    try {
      root.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({'lastServedAt': at.millisecondsSinceEpoch}), flush: true);
      tmp.renameSync(file.path);
    } catch (e) {
      developer.log('saving needs.json failed: $e', name: 'aipet.needs');
    }
  }
}
