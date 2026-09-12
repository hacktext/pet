import 'package:aipet/app/pet_window/close_policy.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late ValueNotifier<LibraryState> state;
  late int quits, reopens;
  late ClosePolicy policy;

  setUp(() {
    state = ValueNotifier(LibraryState.empty);
    quits = 0;
    reopens = 0;
    policy = ClosePolicy(
      state: () => state.value,
      hasPet: () => state.value.currentPetId != null,
      changes: state,
      quit: () async => quits++,
      reopenLibrary: () async => reopens++,
    );
  });

  test('nobody on the desktop and nothing preparing: closing the library quits', () async {
    await policy.libraryClosing();
    expect((quits, reopens), (1, 0));
  });

  test('a pet on the desktop: closing the library just closes it', () async {
    state.value = const LibraryState(currentPetId: 'gold', adoptedPetIds: ['gold']);
    await policy.libraryClosing();
    expect((quits, reopens), (0, 0));
  });

  test('the first pet is preparing: no quit; if it then fails, the library comes back', () async {
    state.value = const LibraryState(preparingPetId: 'gold');
    await policy.libraryClosing();
    expect((quits, reopens), (0, 0));
    state.value = LibraryState.empty; // prepare_failed: preparing cleared, still nobody
    expect((quits, reopens), (0, 1));
    state.value = const LibraryState(preparingPetId: 'ragdoll'); // later changes do not reopen again
    state.value = LibraryState.empty;
    expect((quits, reopens), (0, 1));
  });

  test('the first pet is preparing: if it succeeds the library stays closed', () async {
    state.value = const LibraryState(preparingPetId: 'gold');
    await policy.libraryClosing();
    state.value = const LibraryState(currentPetId: 'gold', adoptedPetIds: ['gold']);
    state.value = const LibraryState(adoptedPetIds: ['gold']); // a later change alone does not reopen
    expect((quits, reopens), (0, 0));
  });

  test('closing twice during one preparation still reopens only once', () async {
    state.value = const LibraryState(preparingPetId: 'gold');
    await policy.libraryClosing();
    await policy.libraryClosing();
    state.value = LibraryState.empty;
    expect((quits, reopens), (0, 1));
  });
}
