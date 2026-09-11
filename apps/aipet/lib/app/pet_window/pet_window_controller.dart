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

/// Everything the pet window decides. The only writer of settings.json.
class PetWindowController extends ChangeNotifier {
  PetWindowController({
    required PetLibrary library,
    required SettingsStore settings,
    required EnsureFn ensure,
    required ClipPlayer player,
    required Future<void> Function(LibraryState state) push,
  })  : _library = library,
        _settings = settings,
        _ensure = ensure,
        _player = player,
        _push = push;

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

  /// Throws [AdoptError]. The old pet keeps playing until the new one's idle
  /// clip is matted and on screen (spec 6).
  Future<void> adopt(String petId) async {
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
      final clip = await _ensure(pet.actionFile(kIdleAction));
      await _player.play(clip, loop: true);
    } catch (e) {
      _state = _state.preparing(null);
      notifyListeners();
      await _push(_state);
      throw AdoptError('prepare_failed', '$e');
    } finally {
      _switching = false;
    }
    _state = _state.adopted(petId);
    _currentAction = kIdleAction;
    _error = null;
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
      final clip = await _ensure(pet.actionFile(key));
      final loop = isLooping(key);
      await _player.play(clip, loop: loop, onFinished: loop ? null : () => playAction(kIdleAction));
      _currentAction = key;
      _error = null;
    } catch (e) {
      _error = '「${labelFor(key)}」准备失败';
    } finally {
      _switching = false;
      notifyListeners();
    }
  }
}
