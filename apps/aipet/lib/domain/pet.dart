import 'dart:convert';
import 'dart:io';

import 'walker.dart';

/// Parent spec 4.6: these loop; every other action plays once and then
/// hands back to [kIdleAction].
const Set<String> kLoopingActions = {'stand', 'walk', 'sleep'};
const String kIdleAction = 'stand';

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
  // A character (Species.isCharacter) rather than an animal.
  'act_coy': '撒娇',
  'dance': '跳舞',
  'talk': '说话',
};

bool isLooping(String key) => kLoopingActions.contains(key);

String labelFor(String key) => _labels[key] ?? key;

/// `other` is any animal that is not a cat or a dog; the last three are
/// characters, which drive their own HUD buttons.
enum Species {
  dog,
  cat,
  other,
  girl,
  boy,
  anime;

  bool get isCharacter => this == girl || this == boy || this == anime;
}

enum PetOrigin { builtin, custom }

/// One voice a character can speak in: `voices/<id>/<action>-<n>.wav` in the
/// pet's folder.
class PetVoice {
  const PetVoice({required this.id, required this.name});

  final String id;
  final String name;
}

/// One pet folder (spec 4.1): pet.json + one `<actionKey>.mp4` per action + cover.
class Pet {
  const Pet({
    required this.id,
    required this.name,
    required this.species,
    required this.origin,
    required this.blurb,
    required this.dir,
    required this.cover,
    required this.actions,
    this.walkFacing = Facing.right,
    this.voices = const [],
    this.card,
    this.tags = const [],
  });

  final String id;
  final String name;
  final Species species;
  final PetOrigin origin;
  final String blurb;
  final Directory dir;
  final String cover;
  final List<String> actions;

  /// Which way the walk clip faces; the pet window mirrors it when walking
  /// the other way (spec 2026-09-19 E 3.4).
  final Facing walkFacing;

  /// Empty for a pet that does not speak; otherwise the first is the default.
  final List<PetVoice> voices;

  /// The library card's photo (a close-up with its own background); null
  /// shows [cover] instead.
  final String? card;

  /// The card's personality tags (元气, 粘人, ...); at most [kMaxTags].
  final List<String> tags;

  File get coverFile => File('${dir.path}${Platform.pathSeparator}$cover');

  File? get cardFile => card == null ? null : File('${dir.path}${Platform.pathSeparator}$card');

  File actionFile(String key) => File('${dir.path}${Platform.pathSeparator}$key.mp4');

  /// What [voice] can say over [action]: its `<action>-<n>.wav` files, sorted.
  List<File> voiceLines(String voice, String action) {
    final d = Directory('${dir.path}${Platform.pathSeparator}voices${Platform.pathSeparator}$voice');
    if (!d.existsSync()) return const [];
    final line = RegExp('^${RegExp.escape(action)}-\\d+\\.wav\$');
    return [
      for (final f in d.listSync().whereType<File>())
        if (line.hasMatch(f.uri.pathSegments.last)) f,
    ]..sort((a, b) => a.path.compareTo(b.path));
  }

  /// A half-installed or half-downloaded folder shows as 素材缺失 (spec 7).
  bool get isComplete => coverFile.existsSync() && actions.every((k) => actionFile(k).existsSync());
}

const int kMaxTags = 3;

final _idPattern = RegExp(r'^[a-z0-9-]+$');

bool _bareFileName(String f) => f.isNotEmpty && !f.contains('/') && !f.contains(r'\') && !f.contains('..');
final _actionPattern = RegExp(r'^[a-z_]+$');

Pet parsePet(String jsonText, Directory dir) {
  final Object? raw;
  try {
    raw = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw FormatException('pet.json is not JSON: ${e.message}');
  }
  if (raw is! Map<String, Object?>) throw const FormatException('pet.json must be an object');

  T field<T>(String key) {
    final v = (raw as Map<String, Object?>)[key];
    if (v is! T) throw FormatException('pet.json "$key" is missing or has the wrong type');
    return v;
  }

  if (field<int>('schema') != 1) throw const FormatException('pet.json schema must be 1');
  final id = field<String>('id');
  if (!_idPattern.hasMatch(id)) throw FormatException('bad pet id "$id"');
  final name = field<String>('name');
  if (name.trim().isEmpty) throw const FormatException('pet name is empty');
  final species = Species.values.asNameMap()[field<String>('species')] ??
      (throw const FormatException('unknown species'));
  final origin = PetOrigin.values.asNameMap()[field<String>('origin')] ??
      (throw const FormatException('unknown origin'));
  final blurb = raw['blurb'] is String ? raw['blurb']! as String : '';
  final cover = field<String>('cover');
  if (!_bareFileName(cover)) throw FormatException('cover must be a bare file name, got "$cover"');
  final card = raw['card'];
  if (card != null && (card is! String || !_bareFileName(card))) {
    throw FormatException('card must be a bare file name, got "$card"');
  }
  final rawTags = raw['tags'] ?? const <Object?>[];
  if (rawTags is! List<Object?> || rawTags.any((t) => t is! String || t.trim().isEmpty)) {
    throw const FormatException('tags must be a list of words');
  }
  final actions = <String>[];
  for (final a in field<List<Object?>>('actions')) {
    if (a is! String || !_actionPattern.hasMatch(a)) throw FormatException('bad action key $a');
    if (actions.contains(a)) throw FormatException('duplicate action $a');
    actions.add(a);
  }
  if (!actions.contains(kIdleAction)) throw const FormatException('actions must include stand');
  final facing = raw['walkFacing'];
  final walkFacing = switch (facing) {
    null || 'right' => Facing.right,
    'left' => Facing.left,
    _ => throw FormatException('walkFacing must be left or right, got $facing'),
  };
  final voices = <PetVoice>[];
  final rawVoices = raw['voices'];
  if (rawVoices != null) {
    if (rawVoices is! List<Object?>) throw const FormatException('voices must be a list');
    for (final v in rawVoices) {
      final vid = v is Map<String, Object?> ? v['id'] : null;
      final vname = v is Map<String, Object?> ? v['name'] : null;
      if (vid is! String || !_idPattern.hasMatch(vid)) throw FormatException('bad voice id in $v');
      if (vname is! String || vname.trim().isEmpty) throw FormatException('voice $vid has no name');
      if (voices.any((x) => x.id == vid)) throw FormatException('duplicate voice $vid');
      voices.add(PetVoice(id: vid, name: vname));
    }
  }
  return Pet(
    id: id,
    name: name,
    species: species,
    origin: origin,
    blurb: blurb,
    dir: dir,
    cover: cover,
    actions: List.unmodifiable(actions),
    walkFacing: walkFacing,
    voices: List.unmodifiable(voices),
    card: card as String?,
    tags: List.unmodifiable(rawTags.cast<String>().take(kMaxTags)),
  );
}
