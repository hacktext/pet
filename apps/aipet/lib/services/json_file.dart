import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// Writes [value] as JSON through a temp file and a rename, so the file is
/// never half-written. Throws on I/O failure; callers decide how much it matters.
void writeJsonAtomic(File file, Object? value) {
  file.parent.createSync(recursive: true);
  final tmp = File('${file.path}.tmp');
  tmp.writeAsStringSync(jsonEncode(value), flush: true);
  tmp.renameSync(file.path);
}

/// Keeps an unreadable [file] as `<name>.bad` for diagnosis. Never throws.
void quarantine(File file, String log, Object why) {
  developer.log('${file.uri.pathSegments.last} unreadable ($why); quarantined as .bad', name: log);
  try {
    final bad = File('${file.path}.bad');
    if (bad.existsSync()) bad.deleteSync();
    file.renameSync(bad.path);
  } catch (e) {
    developer.log('quarantine failed ($e)', name: log);
  }
}
