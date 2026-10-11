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

/// The plaza's top level: animals or characters.
enum Group {
  pets('宠物'),
  people('人物');

  const Group(this.label);
  final String label;

  static Group of(Species s) => s.isCharacter ? people : pets;

  /// Its sub-categories, 全部 first.
  List<Category> get categories => [for (final c in Category.values) if (c.group == this) c];
}

/// A plaza sub-category; a null [species] is its group's 全部.
enum Category {
  allPets(Group.pets, '全部'),
  cat(Group.pets, '猫猫', Species.cat),
  dog(Group.pets, '狗狗', Species.dog),
  other(Group.pets, '其他宠物', Species.other),
  allPeople(Group.people, '全部'),
  girl(Group.people, '女生', Species.girl),
  boy(Group.people, '男生', Species.boy),
  anime(Group.people, '动漫角色', Species.anime);

  const Category(this.group, this.label, [this.species]);
  final Group group;
  final String label;
  final Species? species;
}

List<Pet> filterPets(Iterable<Pet> pets, Category c) => [
      for (final p in pets)
        if (c.species == null ? Group.of(p.species) == c.group : p.species == c.species) p,
    ];

List<Pet> adoptedPets(Iterable<Pet> pets, LibraryState s) => [
      for (final id in s.adoptedPetIds) ...pets.where((p) => p.id == id),
    ];
