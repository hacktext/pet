import 'dart:async';

import 'package:flutter/foundation.dart' hide Category;

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import '../../services/pet_library.dart';
import '../../services/window_bridge.dart';

/// Main-window state. Reads pet folders itself (read-only); everything about
/// who is adopted or on the desktop comes from the pet window (spec 4.3).
class MainWindowModel extends ChangeNotifier {
  MainWindowModel({required this._library, required this._bridge});

  final PetLibrary _library;
  final MainWindowBridge _bridge;
  StreamSubscription<LibraryState>? _sub;

  List<Pet> _pets = const [];
  LibraryState _state = LibraryState.empty;
  Category _category = Category.all;
  int _tab = 0;
  String? _message;

  Category get category => _category;
  int get tab => _tab;
  List<Pet> get plazaPets => filterPets(_pets, _category);
  List<Pet> get minePets => adoptedPets(_pets, _state);

  CardStatus statusOf(Pet p) => cardStatusFor(petId: p.id, complete: p.isComplete, state: _state);

  Future<void> start() async {
    _pets = _library.scan();
    _bridge.start();
    _sub = _bridge.states.listen((s) {
      _state = s;
      notifyListeners();
    });
    try {
      _state = await _bridge.getState();
    } on BridgeTimeout {
      // The pet window pushes stateChanged whenever something happens; the
      // cards simply start from "nobody adopted" until it does.
    }
    notifyListeners();
  }

  void setCategory(Category c) {
    _category = c;
    notifyListeners();
  }

  void setTab(int i) {
    _tab = i;
    notifyListeners();
  }

  Future<void> adopt(String petId) async {
    try {
      await _bridge.adopt(petId);
    } on AdoptError catch (e) {
      _say(e.code == 'missing_assets' ? '素材缺失' : '切换失败，请重试');
    } on BridgeTimeout {
      _say('切换失败，请重试');
    }
  }

  /// A one-shot message for a SnackBar; reading it clears it.
  String? takeMessage() {
    final m = _message;
    _message = null;
    return m;
  }

  void quit() => _bridge.quit();

  Future<void> closing() => _bridge.notifyClosing();

  void _say(String m) {
    _message = m;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _bridge.dispose();
    super.dispose();
  }
}
