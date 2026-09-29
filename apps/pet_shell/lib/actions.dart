import 'dart:io';

/// One playable action: a green-screen clip plus how it should be played.
class PetAction {
  const PetAction({
    required this.key,
    required this.label,
    required this.loops,
    required this.source,
  });

  final String key;
  final String label;
  final bool loops;
  final File source;
}

// Spec 4.6: stand/walk/sleep loop; every other action plays once and then
// hands control back to the idle loop.
const Set<String> _looping = {'stand', 'walk', 'sleep'};

const Map<String, String> _labels = {
  'stand': '待机',
  'walk': '走路',
  'run': '跑步',
  'sleep': '睡觉',
  'feed': '吃饭',
  'play': '玩耍',
  'spin': '转圈',
  'lick_paw': '舔爪子',
  'act_cute': '卖萌',
  'pet_head': '摸摸头',
};

bool isLooping(String key) => _looping.contains(key);

String labelFor(String key) => _labels[key] ?? key;

/// The idle action: stand when available, otherwise the first key.
String? defaultActionKey(Iterable<String> keys) {
  if (keys.contains('stand')) return 'stand';
  return keys.isEmpty ? null : keys.first;
}

/// Maps `<key>.mp4` (the M2 delivery contract, spec 6) to an action. The
/// competitor's dev assets are named `<key>-<key>.mp4`; those collapse to
/// `<key>` so the same folder can be pointed at either.
PetAction? actionFromFile(File file) {
  final name = file.path.split(RegExp(r'[\\/]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || name.substring(dot).toLowerCase() != '.mp4') return null;
  var key = name.substring(0, dot).toLowerCase();
  final dash = key.indexOf('-');
  if (dash > 0 && key.substring(0, dash) == key.substring(dash + 1)) {
    key = key.substring(0, dash);
  }
  return PetAction(key: key, label: labelFor(key), loops: isLooping(key), source: file);
}

/// Every mp4 in [dir] as an action: the idle action first, the rest by key.
List<PetAction> discoverActions(Directory dir) {
  final found = <String, PetAction>{};
  for (final entry in dir.listSync()) {
    if (entry is! File) continue;
    final action = actionFromFile(entry);
    if (action != null) found.putIfAbsent(action.key, () => action);
  }
  final keys = found.keys.toList()..sort();
  final idle = defaultActionKey(keys);
  if (idle != null) {
    keys
      ..remove(idle)
      ..insert(0, idle);
  }
  return [for (final k in keys) found[k]!];
}

/// Whether [source] must be (re)matted: no cache yet, or the clip changed
/// after the cache was written.
bool needsPrepare(File source, File cache) =>
    !cache.existsSync() || cache.lastModifiedSync().isBefore(source.lastModifiedSync());

/// Cache file for [source]. The name carries an FNV-1a hash of the clip's
/// absolute path so same-named clips from different folders never collide;
/// String.hashCode is not guaranteed stable across runs, FNV is.
String cachePathFor(String cacheDir, File source, String key) {
  var h = 0x811c9dc5;
  for (final c in source.absolute.path.toLowerCase().codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return '$cacheDir${Platform.pathSeparator}${key}_${h.toRadixString(16).padLeft(8, '0')}.aipmat';
}
