import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/pet_stats.dart';
import '../../services/stats_store.dart';

/// The current pet's stats, kept up to date and saved (spec 2026-09-19 E 3.3).
class StatsKeeper extends ChangeNotifier {
  StatsKeeper(this._store, {DateTime Function()? now, this.onSaved}) : _now = now ?? DateTime.now {
    _all = _store.load();
  }

  final StatsStore _store;
  final DateTime Function() _now;

  /// After each write of stats.json: a change worth syncing.
  final void Function()? onSaved;
  late final Map<String, PetStats> _all;
  String? _petId;
  bool _hungers = true;

  /// Whether the current pet gets hungry; a character does not.
  bool get hungers => _hungers;

  PetStats? get current => _petId == null ? null : _all[_petId];

  /// Every pet's stats, as a copy (what sync uploads).
  Map<String, PetStats> get all => Map.of(_all);

  DateTime get now => _now();

  /// Switches to [petId] -- a pet seen for the first time starts fresh -- and
  /// catches up the time since its stats were last saved; [hungers] false for
  /// a character, whose satiety then stands still.
  void select(String? petId, {bool hungers = true}) {
    _petId = petId;
    _hungers = hungers;
    if (petId != null) _put(petId, advanceStats(_all[petId] ?? PetStats.fresh(_now()), _now(), hungers: hungers));
    notifyListeners();
  }

  /// Called once a minute by the pet window; saves only when a minute of
  /// drift actually shows.
  void tick() {
    final id = _petId;
    if (id == null) return;
    _put(id, advanceStats(_all[id]!, _now(), hungers: _hungers), saveUnchanged: false);
    notifyListeners();
  }

  /// The user picked [action] from the panel or the menu.
  void interact(String action) {
    final id = _petId;
    if (id == null) return;
    _put(id, recordInteraction(_all[id]!, _now(), fed: action == 'feed', hungers: _hungers));
    notifyListeners();
  }

  /// Newer stats from another computer, via sync. The current pet's are
  /// caught up to now right away, as on select().
  void applySynced(Map<String, PetStats> newer) {
    if (newer.isEmpty) return;
    _all.addAll(newer);
    final id = _petId;
    if (id != null && newer.containsKey(id)) _all[id] = advanceStats(_all[id]!, _now(), hungers: _hungers);
    _save();
    notifyListeners();
  }

  /// Best effort, like settings.json: a failed save must not undo what is on screen.
  void _put(String id, PetStats s, {bool saveUnchanged = true}) {
    final before = _all[id];
    _all[id] = s;
    // Every minute moves updatedAt and a fraction of satiety, so a whole-object
    // comparison would still rewrite stats.json 1440 times a day. Only a
    // change that shows is worth the temp file, flush and rename: the snapshot
    // carries its own updatedAt, so the next launch reloads an older one and
    // advances it to then, landing on the same numbers (spec 3.3).
    if (!saveUnchanged && before != null && _sameOnScreen(before, s)) return;
    _save();
  }

  void _save() {
    try {
      _store.save(_all);
    } catch (e) {
      developer.log('stats save failed: $e', name: 'aipet.stats');
      return;
    }
    onSaved?.call();
  }

  /// Everything the panel shows (numbers as rounded there) plus the dates a
  /// restart would restore differently.
  static bool _sameOnScreen(PetStats a, PetStats b) =>
      a.satiety.round() == b.satiety.round() &&
      a.health.round() == b.health.round() &&
      a.intimacy.round() == b.intimacy.round() &&
      a.todayInteractions == b.todayInteractions &&
      a.interactionDay == b.interactionDay &&
      a.companionStartedAt == b.companionStartedAt;
}
