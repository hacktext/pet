import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/pet_stats.dart';
import 'package:aipet/services/sync_service.dart';

/// The pet window's settings, stats and voices as plain fields; [applied]
/// lists what sync wrote back, in order.
class FakeLocal implements SyncLocal {
  @override
  LibraryState settings = LibraryState.empty;
  @override
  Map<String, PetStats> stats = {};
  @override
  Map<String, String> voices = {};
  final applied = <String>[];
  void Function()? duringApply;

  @override
  Future<void> applySettings(LibraryState s) async {
    applied.add('settings');
    duringApply?.call();
    settings = LibraryState(currentPetId: s.currentPetId, adoptedPetIds: s.adoptedPetIds);
  }

  @override
  void applyStats(Map<String, PetStats> newer) {
    applied.add('stats ${newer.keys.join(',')}');
    stats = {...stats, ...newer};
  }

  @override
  void applyVoices(Map<String, String> choices) {
    applied.add('voice');
    voices = Map.of(choices);
  }
}
