import 'package:aipet/domain/paid_character.dart';
import 'package:aipet/domain/pet.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> item({Object? code = 'suwan', Object? species = 'girl', Object? price = 1990, Object? name = '苏晚'}) => {
      'code': code,
      'name': name,
      'species': species,
      'blurb': '温柔',
      'tags': ['元气', '粘人'],
      'voices': [
        {'id': 'warm', 'name': '温柔'},
      ],
      'actions': ['stand', 'walk'],
      'price_cents': price,
      'sort': 1,
      'card_url': 'https://x/card.jpg',
    };

void main() {
  test('a full item parses', () {
    final c = PaidCharacter.fromJson(item())!;
    expect(c.code, 'suwan');
    expect(c.petId, 'paid-suwan');
    expect(c.species, Species.girl);
    expect(c.priceCents, 1990);
    expect(c.tags, ['元气', '粘人']);
    expect(c.voices.single.id, 'warm');
    expect(c.actions, ['stand', 'walk']);
    expect(c.cardUrl, 'https://x/card.jpg');
  });

  test('species maps by name', () {
    expect(PaidCharacter.fromJson(item(species: 'boy'))!.species, Species.boy);
    expect(PaidCharacter.fromJson(item(species: 'anime'))!.species, Species.anime);
  });

  test('a null card_url is no card', () {
    expect(PaidCharacter.fromJson(item()..['card_url'] = null)!.cardUrl, isNull);
  });

  test('bad items are null', () {
    expect(PaidCharacter.fromJson(item(species: 'dragon')), isNull);
    expect(PaidCharacter.fromJson(item(code: null)), isNull);
    expect(PaidCharacter.fromJson(item(name: null)), isNull);
    expect(PaidCharacter.fromJson(item(price: null)), isNull);
    expect(PaidCharacter.fromJson(item(code: 'Bad-Code')), isNull);
    expect(PaidCharacter.fromJson(item(code: '../x')), isNull);
    expect(PaidCharacter.fromJson('nope'), isNull);
  });

  test('paidCatalogFrom keeps the good items', () {
    final list = paidCatalogFrom([item(), item(species: 'x'), item(code: 'guchen', species: 'boy')]);
    expect(list.map((c) => c.code), ['suwan', 'guchen']);
    expect(paidCatalogFrom({'a': 1}), isEmpty);
  });

  test('toJson re-parses to the same item', () {
    final c = PaidCharacter.fromJson(item())!;
    expect(PaidCharacter.fromJson(c.toJson())!.toJson(), c.toJson());
  });
}
