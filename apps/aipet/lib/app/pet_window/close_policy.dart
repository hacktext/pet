import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/library_state.dart';

/// What closing the library window means (spec 3.3): with nobody on the
/// desktop the app ends -- unless the first pet is still being prepared. Then
/// the library just closes; should that preparation fail with the desktop
/// still empty, the library comes back instead of leaving only a tray icon.
class ClosePolicy {
  ClosePolicy({
    required this._state,
    required this._hasPet,
    required this._changes,
    required this._quit,
    required this._reopenLibrary,
  });

  final LibraryState Function() _state;
  final bool Function() _hasPet;

  /// Notifies whenever [_state] / [_hasPet] may have changed.
  final Listenable _changes;
  final Future<void> Function() _quit;
  final Future<void> Function() _reopenLibrary;
  bool _waiting = false;

  Future<void> libraryClosing() async {
    if (_hasPet()) return;
    if (_state().preparingPetId == null) return _quit();
    if (_waiting) return;
    _waiting = true;
    _changes.addListener(_onChange);
  }

  void _onChange() {
    if (_state().preparingPetId != null) return;
    _changes.removeListener(_onChange);
    _waiting = false;
    if (_hasPet()) return;
    _reopenLibrary().catchError((Object e) {
      developer.log('reopening the library failed: $e', name: 'aipet.pet_window');
    });
  }
}
