import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import '../../services/pet_library.dart';
import '../../services/settings_store.dart';
import '../../services/window_bridge.dart';

/// Playback as the controller sees it; AlphaClipPlayer (Task 15) is the real one.
abstract class ClipPlayer {
  /// Puts [aipmat] on screen and starts it. The previous clip stays visible
  /// until this returns. For a one-shot ([loop] false), [onFinished] runs once
  /// when its last frame is shown.
  Future<void> play(File aipmat, {required bool loop, VoidCallback? onFinished});

  Future<void> dispose();
}

/// The matted .aipmat for a clip: MatteCache.ensure in production.
typedef EnsureFn = Future<File> Function(File source);

/// How long a clip may take to be matted and put on screen (spec 3.2 / 7:
/// "上限 60 秒"). Just under the main window's 60 s adoptTimeout, so its
/// "preparing cleared" push arrives before the main window gives up.
const Duration kPrepareTimeout = Duration(seconds: 55);

/// Everything the pet window decides. The only writer of settings.json.
class PetWindowController extends ChangeNotifier {
  PetWindowController({
    required this._library,
    required this._settings,
    required this._ensure,
    required this._player,
    required this._push,
    this.prepareTimeout = kPrepareTimeout,
    this.onAdopted,
  });

  final Duration prepareTimeout;

  /// The user put [petId] on the desktop: [firstTime] when it was not adopted
  /// before (telemetry's pet_adopt / pet_switch). Not called for a switch that
  /// came in through sync.
  final void Function(String petId, bool firstTime)? onAdopted;

  final PetLibrary _library;
  final SettingsStore _settings;
  final EnsureFn _ensure;
  final ClipPlayer _player;
  final Future<void> Function(LibraryState) _push;

  List<Pet> _pets = const [];
  LibraryState _state = LibraryState.empty;
  String? _currentAction;
  String? _error;
  bool _switching = false;

  List<Pet> get pets => _pets;
  LibraryState get state => _state;
  String? get currentAction => _currentAction;
  String? get error => _error;
  Pet? get currentPet => _state.currentPetId == null ? null : PetLibrary.byId(_pets, _state.currentPetId!);

  /// Best-effort: a failed save (disk full, file locked) must not undo a switch
  /// that is already on screen. The next successful save rewrites the file.
  void _persist(LibraryState s) {
    try {
      _settings.save(s);
    } catch (e) {
      developer.log('settings save failed: $e', name: 'aipet.pet_window');
    }
  }

  /// Spec 3.3 / 7: the saved pet if its folder is still complete, otherwise
  /// another adopted one, otherwise nobody (first-run behaviour).
  Future<void> boot() async {
    _pets = _library.scan();
    final saved = _settings.load();
    bool usable(String id) => PetLibrary.byId(_pets, id)?.isComplete ?? false;
    var s = saved;
    if (saved.currentPetId != null && !usable(saved.currentPetId!)) {
      s = LibraryState(
          currentPetId: saved.adoptedPetIds.where(usable).firstOrNull, adoptedPetIds: saved.adoptedPetIds);
      _persist(s);
    }
    _state = s;
    notifyListeners();
    if (currentPet != null) await _show(kIdleAction);
    await _push(_state);
  }

  /// New pet folders arrived (a custom pet finished downloading): list them.
  /// Who is adopted or on the desktop does not change.
  void rescan() {
    _pets = _library.scan();
    notifyListeners();
  }

  /// Throws [AdoptError]. The old pet keeps playing until the new one's idle
  /// clip is matted and on screen (spec 6).
  Future<void> adopt(String petId) => _adopt(petId, byUser: true);

  Future<void> _adopt(String petId, {required bool byUser}) async {
    final pet = PetLibrary.byId(_pets, petId);
    if (pet == null) throw const AdoptError('unknown_pet');
    if (!pet.isComplete) throw const AdoptError('missing_assets');
    if (_state.currentPetId == petId && _state.preparingPetId == null) {
      await _push(_state); // the main window waits for a state naming this pet
      return;
    }
    if (_switching || _state.preparingPetId != null) throw const AdoptError('busy');

    _state = _state.preparing(petId);
    notifyListeners();
    await _push(_state);
    _switching = true;
    try {
      await _prepareAndPlay(pet, kIdleAction);
    } catch (e) {
      _state = _state.preparing(null);
      notifyListeners();
      await _push(_state);
      throw AdoptError('prepare_failed', '$e');
    } finally {
      _switching = false;
    }
    final firstTime = !_state.isAdopted(petId);
    _state = _state.adopted(petId);
    _currentAction = kIdleAction;
    _error = null;
    _persist(_state);
    notifyListeners();
    if (byUser) onAdopted?.call(petId, firstTime);
    await _push(_state);
  }

  /// The account's settings won a sync (web platform spec 4.2): its adopted
  /// list replaces ours, and its pet goes on the desktop when this computer
  /// has it complete and is not busy. Otherwise whoever is on the desktop
  /// stays -- and stays listed, so settings.json keeps its invariant.
  Future<void> applySynced(LibraryState s) async {
    final want = s.currentPetId;
    final usable = want != null && (PetLibrary.byId(_pets, want)?.isComplete ?? false);
    if (usable && want != _state.currentPetId && !_switching && _state.preparingPetId == null) {
      try {
        await _adopt(want, byUser: false);
      } on AdoptError catch (e) {
        developer.log('synced pet $want not shown: $e', name: 'aipet.pet_window');
      }
    }
    final current = _state.currentPetId;
    final ids = [...s.adoptedPetIds];
    for (final id in [want, current]) {
      if (id != null && !ids.contains(id)) ids.add(id);
    }
    final next = LibraryState(currentPetId: current, adoptedPetIds: ids, preparingPetId: _state.preparingPetId);
    if (next == _state) return;
    _state = next;
    _persist(_state);
    notifyListeners();
    await _push(_state);
  }

  Future<void> playAction(String key) async {
    final pet = currentPet;
    if (pet == null || !pet.actions.contains(key)) return;
    if (_switching || _state.preparingPetId != null) return;
    if (key == _currentAction && isLooping(key)) return;
    await _show(key);
  }

  Future<void> _show(String key) async {
    final pet = currentPet!;
    _switching = true;
    try {
      await _prepareAndPlay(pet, key);
      _currentAction = key;
      _error = null;
    } catch (e) {
      _error = '「${labelFor(key)}」准备失败';
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  /// Mats [key]'s clip and puts it on screen, giving up with a
  /// TimeoutException after [prepareTimeout] -- a hung prepare must not leave
  /// preparingPetId / _switching set forever. A clip that finishes matting
  /// after the deadline is not played: the caller has already moved on.
  Future<void> _prepareAndPlay(Pet pet, String key) async {
    var gaveUp = false;
    Future<void> run() async {
      final clip = await _ensure(pet.actionFile(key));
      if (gaveUp) return;
      final loop = isLooping(key);
      await _player.play(clip, loop: loop, onFinished: loop ? null : () => playAction(kIdleAction));
    }

    try {
      await run().timeout(prepareTimeout);
    } on TimeoutException {
      gaveUp = true;
      rethrow;
    }
  }
}
