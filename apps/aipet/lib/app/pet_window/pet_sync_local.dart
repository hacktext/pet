import '../../domain/library_state.dart';
import '../../domain/pet_stats.dart';
import '../../services/sync_service.dart';
import '../../services/voice_store.dart';
import 'pet_window_controller.dart';
import 'stats_keeper.dart';

/// What sync reads and writes in the pet window: the controller's settings,
/// the stats keeper and the voice choices.
class PetSyncLocal implements SyncLocal {
  PetSyncLocal({required this._pets, required this._stats, required this._voices, this.onVoices});

  final PetWindowController _pets;
  final StatsKeeper _stats;
  final VoiceStore _voices;

  /// After sync replaced the voice choices (the library's cards follow).
  final void Function(Map<String, String> choices)? onVoices;

  @override
  LibraryState get settings =>
      LibraryState(currentPetId: _pets.state.currentPetId, adoptedPetIds: _pets.state.adoptedPetIds);

  @override
  Map<String, PetStats> get stats => _stats.all;

  @override
  Map<String, String> get voices => _voices.all;

  @override
  Future<void> applySettings(LibraryState s) => _pets.applySynced(s);

  @override
  void applyStats(Map<String, PetStats> newer) => _stats.applySynced(newer);

  @override
  void applyVoices(Map<String, String> choices) {
    _voices.replaceAll(choices);
    onVoices?.call(_voices.all);
  }

  /// Calls [changed] whenever who is adopted or on the desktop changes from
  /// what it is now -- not for actions, errors or a pet being prepared, which
  /// also notify. Start it after boot(), or loading settings.json would look
  /// like the user changing them.
  void watchSettings(void Function() changed) {
    var last = settings;
    _pets.addListener(() {
      final now = settings;
      if (now == last) return;
      last = now;
      changed();
    });
  }
}
