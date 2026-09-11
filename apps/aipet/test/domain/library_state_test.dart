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

  test('categories filter by species and carry their labels', () {
    final pets = [pet('d1', Species.dog), pet('c1', Species.cat), pet('d2', Species.dog)];
    expect(filterPets(pets, Category.all).map((p) => p.id), ['d1', 'c1', 'd2']);
    expect(filterPets(pets, Category.dog).map((p) => p.id), ['d1', 'd2']);
    expect(filterPets(pets, Category.cat).map((p) => p.id), ['c1']);
    expect(filterPets(pets, Category.other), isEmpty);
    expect(Category.values.map((c) => c.label), ['全部', '狗狗', '猫猫', '其他小宠']);
  });

  test('adoptedPets keeps adoption order and skips unknown ids', () {
    final pets = [pet('a', Species.dog), pet('b', Species.cat)];
    const st = LibraryState(adoptedPetIds: ['b', 'gone', 'a']);
    expect(adoptedPets(pets, st).map((p) => p.id), ['b', 'a']);
  });
}
