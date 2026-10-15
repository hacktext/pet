import 'dart:ui';

import 'package:aipet/domain/pet_size.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const work = Rect.fromLTWH(0, 0, 1707, 1027);

  test('大 is the size the pet always had, and the fallback', () {
    expect(PetSize.fallback, PetSize.large);
    expect(PetSize.large.edge, kPetMenuRoom);
    expect(PetSize.small.edge, lessThan(PetSize.medium.edge));
    expect(PetSize.medium.edge, lessThan(PetSize.large.edge));
  });

  test('byName knows the three sizes and nothing else', () {
    for (final s in PetSize.values) {
      expect(PetSize.byName(s.name), s);
    }
    expect(PetSize.byName('huge'), isNull);
    expect(PetSize.byName(3), isNull);
    expect(PetSize.byName(null), isNull);
  });

  test('resizing keeps the feet where they were', () {
    const pet = Rect.fromLTWH(1000, 600, 360, 360);
    final r = resizedPet(pet, PetSize.small);
    expect(r.size, const Size(200, 200));
    expect(r.bottom, pet.bottom);
    expect(r.center.dx, pet.center.dx);
    expect(resizedPet(r, PetSize.large), pet);
  });

  test('a 大 pet already has the menu room', () {
    const pet = Rect.fromLTWH(1000, 600, 360, 360);
    expect(menuRoomFor(pet, work), pet);
  });

  test('a smaller pet gets a 360 window centred on it', () {
    const pet = Rect.fromLTWH(1000, 400, 200, 200);
    final room = menuRoomFor(pet, work);
    expect(room.size, const Size(kPetMenuRoom, kPetMenuRoom));
    expect(room.center, pet.center);
  });

  test('the room stays inside the work area, still holding the pet', () {
    // On the taskbar in the bottom-right corner.
    const pet = Rect.fromLTWH(1507, 827, 200, 200);
    final room = menuRoomFor(pet, work);
    expect(room, const Rect.fromLTWH(1707 - 360, 1027 - 360, 360, 360));
    expect(room.contains(pet.topLeft) && room.bottomRight >= pet.bottomRight, isTrue);
    // And the top-left one.
    expect(menuRoomFor(const Rect.fromLTWH(0, 0, 200, 200), work).topLeft, Offset.zero);
  });

  test('with no work area the room is simply centred', () {
    const pet = Rect.fromLTWH(-50, 900, 200, 200);
    expect(menuRoomFor(pet, null).center, pet.center);
  });
}
