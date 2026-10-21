import 'pet.dart';

final _codePattern = RegExp(r'^[a-z0-9_]+$');

/// One character the shop sells (GET /api/aipet/characters). Not a [Pet]: it
/// becomes one only after it is bought and installed as `pets/paid-<code>/`.
class PaidCharacter {
  const PaidCharacter({
    required this.code,
    required this.name,
    required this.species,
    required this.priceCents,
    this.blurb = '',
    this.tags = const [],
    this.cardUrl,
    this.voices = const [],
    this.actions = const [],
  });

  final String code;
  final String name;
  final Species species;
  final String blurb;
  final List<String> tags;
  final int priceCents;

  /// The library card's photo; null when the shop has none.
  final String? cardUrl;
  final List<PetVoice> voices;
  final List<String> actions;

  /// The id of the installed pet.
  String get petId => 'paid-$code';

  /// The shape the backend sends, so a cached catalog re-parses with [fromJson].
  Map<String, Object?> toJson() => {
        'code': code,
        'name': name,
        'species': species.name,
        'blurb': blurb,
        'tags': tags,
        'voices': [
          for (final v in voices) {'id': v.id, 'name': v.name},
        ],
        'actions': actions,
        'price_cents': priceCents,
        'card_url': cardUrl,
      };

  /// Null for anything unusable: not an object, no code / name / price, a code
  /// that is not a safe folder name, or a species this app does not know.
  static PaidCharacter? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final code = raw['code'];
    final name = raw['name'];
    final price = raw['price_cents'];
    if (code is! String || !_codePattern.hasMatch(code)) return null;
    if (name is! String || name.trim().isEmpty) return null;
    if (price is! int) return null;
    final rawSpecies = raw['species'];
    final species = rawSpecies is String ? Species.values.asNameMap()[rawSpecies] : null;
    if (species == null) return null;
    final voices = <PetVoice>[];
    final rawVoices = raw['voices'];
    if (rawVoices is List<Object?>) {
      for (final v in rawVoices) {
        if (v is! Map<String, Object?>) continue;
        final id = v['id'];
        final vname = v['name'];
        if (id is String && vname is String) voices.add(PetVoice(id: id, name: vname));
      }
    }
    final card = raw['card_url'];
    return PaidCharacter(
      code: code,
      name: name,
      species: species,
      blurb: raw['blurb'] is String ? raw['blurb']! as String : '',
      tags: _strings(raw['tags']),
      priceCents: price,
      cardUrl: card is String && card.isNotEmpty ? card : null,
      voices: List.unmodifiable(voices),
      actions: List.unmodifiable(_strings(raw['actions'])),
    );
  }

  static List<String> _strings(Object? v) => v is List<Object?> ? [for (final s in v) if (s is String) s] : const [];
}

/// Every usable item of the catalog's `data`; bad items are skipped, and
/// anything that is not a list is an empty catalog.
List<PaidCharacter> paidCatalogFrom(Object? data) {
  if (data is! List<Object?>) return const [];
  return [
    for (final item in data)
      ?PaidCharacter.fromJson(item),
  ];
}
