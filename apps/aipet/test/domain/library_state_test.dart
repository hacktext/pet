import 'dart:io';

import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/pet.dart';
import 'package:flutter_test/flutter_test.dart';

Pet pet(String id, Species s) => Pet(
      id: id,
      name: id,
      species: s,
      origin: PetOrigin.builtin,
      blurb: '',
      dir: Directory('C:\\pets\\$id'),
      cover: 'cover.png',
      actions: const ['stand'],
    );

void main() {
  const s = LibraryState(currentPetId: 'a', adoptedPetIds: ['a', 'b'], preparingPetId: 'c');

  group('cardStatusFor', () {
    CardStatus of(String id, {bool complete = true}) =>
        cardStatusFor(petId: id, complete: complete, state: s);
    test('incomplete folders are missing, whatever else is true', () => expect(of('a', complete: false), CardStatus.missing));
    test('preparing wins over adoption state', () => expect(of('c'), CardStatus.preparing));
    test('current pet is the companion', () => expect(of('a'), CardStatus.companion));
    test('adopted but not current can be switched to', () => expect(of('b'), CardStatus.switchable));
    test('never adopted can be adopted', () => expect(of('z'), CardStatus.adoptable));
    test('preparing also wins over an adopted, non-current pet', () {
      expect(cardStatusFor(petId: 'b', complete: true, state: s.preparing('b')), CardStatus.preparing);
    });
  });

  test('adopted() makes the pet current, records it once, clears preparing', () {
    final a = s.adopted('c');
    expect(a, const LibraryState(currentPetId: 'c', adoptedPetIds: ['a', 'b', 'c']));
    expect(a.adopted('b').adoptedPetIds, ['a', 'b', 'c']);
  });

  test('preparing() only touches preparingPetId', () {
    expect(LibraryState.empty.preparing('x'), const LibraryState(preparingPetId: 'x'));
    expect(s.preparing(null), const LibraryState(currentPetId: 'a', adoptedPetIds: ['a', 'b']));
  });

  test('json round trip, including the channel map type', () {
    final Map<Object?, Object?> wire = Map<Object?, Object?>.from(s.toJson());
    expect(LibraryState.fromJson(wire), s);
    expect(LibraryState.fromJson(const {}), LibraryState.empty);
  });

  test('categories filter by species within their group and carry their labels', () {
    final pets = [
      pet('d1', Species.dog), pet('c1', Species.cat), pet('g1', Species.girl),
      pet('d2', Species.dog), pet('a1', Species.anime), pet('o1', Species.other),
    ];
    expect(filterPets(pets, Category.allPets).map((p) => p.id), ['d1', 'c1', 'd2', 'o1']);
    expect(filterPets(pets, Category.dog).map((p) => p.id), ['d1', 'd2']);
    expect(filterPets(pets, Category.cat).map((p) => p.id), ['c1']);
    expect(filterPets(pets, Category.other).map((p) => p.id), ['o1']);
    expect(filterPets(pets, Category.allPeople).map((p) => p.id), ['g1', 'a1']);
    expect(filterPets(pets, Category.girl).map((p) => p.id), ['g1']);
    expect(filterPets(pets, Category.boy), isEmpty);
    expect(filterPets(pets, Category.anime).map((p) => p.id), ['a1']);
    expect(Group.values.map((g) => g.label), ['宠物', '人物']);
    expect(Group.pets.categories.map((c) => c.label), ['全部', '猫猫', '狗狗', '其他宠物']);
    expect(Group.people.categories.map((c) => c.label), ['全部', '女生', '男生', '动漫角色']);
  });

  test('every species belongs to exactly one category besides 全部', () {
    for (final s in Species.values) {
      expect(Category.values.where((c) => c.species == s), hasLength(1), reason: s.name);
    }
  });

  test('adoptedPets keeps adoption order and skips unknown ids', () {
    final pets = [pet('a', Species.dog), pet('b', Species.cat)];
    const st = LibraryState(adoptedPetIds: ['b', 'gone', 'a']);
    expect(adoptedPets(pets, st).map((p) => p.id), ['b', 'a']);
  });
}
