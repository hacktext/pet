import 'pet.dart';

/// Who is on the desktop, who has been adopted, who is being prepared.
/// Travels over the window channel as [toJson]; settings.json stores the
/// first two fields only.
class LibraryState {
  const LibraryState({this.currentPetId, this.adoptedPetIds = const [], this.preparingPetId});

  static const empty = LibraryState();

  final String? currentPetId;
  final List<String> adoptedPetIds;
  final String? preparingPetId;

  bool isAdopted(String id) => adoptedPetIds.contains(id);

  LibraryState preparing(String? petId) =>
      LibraryState(currentPetId: currentPetId, adoptedPetIds: adoptedPetIds, preparingPetId: petId);

  LibraryState adopted(String petId) => LibraryState(
        currentPetId: petId,
        adoptedPetIds: isAdopted(petId) ? adoptedPetIds : [...adoptedPetIds, petId],
      );

  Map<String, Object?> toJson() =>
      {'currentPetId': currentPetId, 'adoptedPetIds': adoptedPetIds, 'preparingPetId': preparingPetId};

  factory LibraryState.fromJson(Map<Object?, Object?> j) => LibraryState(
        currentPetId: j['currentPetId'] as String?,
        adoptedPetIds: [for (final v in (j['adoptedPetIds'] as List<Object?>?) ?? const <Object?>[]) v! as String],
        preparingPetId: j['preparingPetId'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is LibraryState &&
      other.currentPetId == currentPetId &&
      other.preparingPetId == preparingPetId &&
      other.adoptedPetIds.length == adoptedPetIds.length &&
      Iterable<int>.generate(adoptedPetIds.length).every((i) => other.adoptedPetIds[i] == adoptedPetIds[i]);

  @override
  int get hashCode => Object.hash(currentPetId, preparingPetId, Object.hashAll(adoptedPetIds));

  @override
  String toString() => 'LibraryState(${toJson()})';
}

/// Spec 5: the five card states.
enum CardStatus { adoptable, switchable, companion, preparing, missing }

CardStatus cardStatusFor({required String petId, required bool complete, required LibraryState state}) {
  if (!complete) return CardStatus.missing;
  if (state.preparingPetId == petId) return CardStatus.preparing;
  if (state.currentPetId == petId) return CardStatus.companion;
  if (state.isAdopted(petId)) return CardStatus.switchable;
  return CardStatus.adoptable;
}

enum Category {
  all('全部'),
  dog('狗狗'),
  cat('猫猫'),
  other('其他小宠');

  const Category(this.label);
  final String label;
}

List<Pet> filterPets(Iterable<Pet> pets, Category c) => switch (c) {
      Category.all => pets.toList(),
      Category.dog => pets.where((p) => p.species == Species.dog).toList(),
      Category.cat => pets.where((p) => p.species == Species.cat).toList(),
      Category.other => pets.where((p) => p.species == Species.other).toList(),
    };

List<Pet> adoptedPets(Iterable<Pet> pets, LibraryState s) => [
      for (final id in s.adoptedPetIds) ...pets.where((p) => p.id == id),
    ];
