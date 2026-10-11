import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// The voice a pet was set to that means "say nothing".
const kVoiceOff = 'off';

/// voice.json: which voice each pet speaks in, {petId: voiceId | "off"}. Kept
/// out of settings.json so that file's format stays as it is. Only the pet
/// window writes it.
class VoiceStore {
  VoiceStore(this.root) : _choices = _load(root);

  final Directory root;
  final Map<String, String> _choices;

  static File _file(Directory root) => File('${root.path}${Platform.pathSeparator}voice.json');

  /// Never throws: a missing or unreadable file is no choice made yet.
  static Map<String, String> _load(Directory root) {
    final f = _file(root);
    if (!f.existsSync()) return {};
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map<String, Object?>) throw const FormatException('not an object');
      return {for (final e in j.entries) if (e.value is String) e.key: e.value! as String};
    } catch (e) {
      developer.log('voice.json unreadable ($e); starting over', name: 'aipet.voice');
      return {};
    }
  }

  /// The voice id, [kVoiceOff], or null when nothing was chosen for [petId].
  String? choice(String petId) => _choices[petId];

  /// Every choice, as a copy (what sync uploads).
  Map<String, String> get all => Map.of(_choices);

  void choose(String petId, String voice) {
    _choices[petId] = voice;
    _save();
  }

  /// The account's choices won a sync.
  void replaceAll(Map<String, String> choices) {
    _choices
      ..clear()
      ..addAll(choices);
    _save();
  }

  void _save() {
    root.createSync(recursive: true);
    final f = _file(root);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(_choices), flush: true);
    tmp.renameSync(f.path);
  }
}
