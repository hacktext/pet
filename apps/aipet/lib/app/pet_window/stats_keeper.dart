import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/pet_stats.dart';
import '../../services/stats_store.dart';

/// The current pet's stats, kept up to date and saved (spec 2026-09-19 E 3.3).
class StatsKeeper extends ChangeNotifier {
  StatsKeeper(this._store, {DateTime Function()? now}) : _now = now ?? DateTime.now {
    _all = _store.load();
  }

  final StatsStore _store;
  final DateTime Function() _now;
  late final Map<String, PetStats> _all;
  String? _petId;

  PetStats? get current => _petId == null ? null : _all[_petId];

  DateTime get now => _now();

  /// Switches to [petId] -- a pet seen for the first time starts fresh -- and
  /// catches up the time since its stats were last saved.
  void select(String? petId) {
    _petId = petId;
    if (petId != null) _put(petId, advanceStats(_all[petId] ?? PetStats.fresh(_now()), _now()));
    notifyListeners();
  }

  /// Called once a minute by the pet window.
  void tick() {
    final id = _petId;
    if (id == null) return;
    _put(id, advanceStats(_all[id]!, _now()));
    notifyListeners();
  }

  /// The user picked [action] from the panel or the menu.
  void interact(String action) {
    final id = _petId;
    if (id == null) return;
    _put(id, recordInteraction(_all[id]!, _now(), fed: action == 'feed'));
    notifyListeners();
  }

  /// Best effort, like settings.json: a failed save must not undo what is on screen.
  void _put(String id, PetStats s) {
    _all[id] = s;
    try {
      _store.save(_all);
    } catch (e) {
      developer.log('stats save failed: $e', name: 'aipet.stats');
    }
  }
}
