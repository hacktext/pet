import 'dart:async';
import 'dart:math';

import '../../domain/pet_stats.dart';
import '../../services/hud_bridge.dart';
import '../../services/window_bridge.dart';
import 'hud_presenter.dart';
import 'pet_window_controller.dart';
import 'stats_keeper.dart';
import 'walk_driver.dart';
import 'window_mover.dart';

/// Everything the user does with the pet on the desktop (spec 2026-09-19 E):
/// actions from the panel or the menu, walking across the screen, roaming
/// when idle, and what the panel shows.
class Companion {
  Companion({
    required this.pets,
    required this.stats,
    required this.walker,
    required this.mover,
    required BridgeTransport hudTransport,
    Random? random,
    this.userWalk = const Duration(seconds: 20),
  }) : _random = random ?? Random() {
    presenter = HudPresenter(show: () => unawaited(_showHud()), hide: () => unawaited(hud.hide()));
    hud = PetHudBridge(
      hudTransport,
      onAction: (k) => unawaited(userAction(k)),
      onClose: presenter.close,
      onHover: (inside) => inside ? presenter.hudEnter() : presenter.hudExit(),
    )..start();
    pets.addListener(_petsChanged);
    stats.addListener(_pushView);
  }

  final PetWindowController pets;
  final StatsKeeper stats;
  final WalkDriver walker;
  final WindowMover mover;
  final Duration userWalk;
  final Random _random;
  late final HudPresenter presenter;
  late final PetHudBridge hud;

  Timer? _roam;
  int _walkGen = 0;
  bool _dragging = false;
  String? _petId;

  /// The panel's content; null with nobody on the desktop.
  HudView? get view {
    final pet = pets.currentPet;
    final s = stats.current;
    if (pet == null || s == null) return null;
    return HudView(
      name: pet.name,
      cover: pet.coverFile.path,
      status: statusText(s),
      companionDays: companionDays(s, stats.now),
      todayInteractions: s.todayInteractions,
      intimacy: s.intimacy.round(),
      satiety: s.satiety.round(),
      health: s.health.round(),
      enabled: {for (final b in kHudButtons) if (pet.actions.contains(b)) b},
    );
  }

  /// A button in the panel or an item in the right-click menu: counts as an
  /// interaction; 'walk' walks across the screen, anything else plays.
  Future<void> userAction(String key) async {
    final pet = pets.currentPet;
    if (pet == null || !pet.actions.contains(key)) return;
    stats.interact(key);
    if (key == 'walk') return _walk(userWalk);
    _walkGen++;
    walker.stop();
    await pets.playAction(key);
  }

  Future<void> _walk(Duration length) async {
    final gen = ++_walkGen;
    presenter.busy = true;
    await pets.playAction('walk');
    if (gen == _walkGen && pets.currentAction == 'walk') await walker.walk(length);
    presenter.busy = _dragging;
    if (gen == _walkGen && pets.currentAction == 'walk') await pets.playAction('stand');
  }

  void petEnter() => presenter.petEnter();

  void petExit() => presenter.petExit();

  void dragStarted() {
    _dragging = true;
    _walkGen++;
    walker.stop();
    presenter.busy = true;
    if (pets.currentAction == 'walk') unawaited(pets.playAction('stand'));
  }

  void dragEnded() {
    _dragging = false;
    presenter.busy = walker.walking;
  }

  /// Quitting: stop walking and take the panel off the screen.
  Future<void> shutdown() async {
    _walkGen++;
    walker.stop();
    _roam?.cancel();
    await hud.hide();
  }

  void _petsChanged() {
    final id = pets.currentPet?.id;
    if (id != _petId) {
      _petId = id;
      stats.select(id);
    }
    if (pets.currentAction == 'stand' && !walker.walking) {
      _roam ??= _scheduleRoam();
    } else if (pets.currentAction != 'stand') {
      _roam?.cancel();
      _roam = null;
    }
    _pushView();
  }

  /// 3-6 idle minutes, then roam if nothing else is going on (spec 3.4).
  Timer _scheduleRoam() => Timer(Duration(seconds: 180 + _random.nextInt(181)), () {
        _roam = null;
        final idle = pets.currentPet != null &&
            pets.currentAction == 'stand' &&
            pets.state.preparingPetId == null &&
            !walker.walking &&
            !presenter.shown &&
            !presenter.pointerOnPet &&
            !_dragging;
        if (!idle) {
          _roam = _scheduleRoam();
          return;
        }
        unawaited(_walk(Duration(seconds: 8 + _random.nextInt(8))));
      });

  Future<void> _showHud() async {
    final v = view;
    if (v == null) return;
    await hud.show(await mover.bounds(), v);
  }

  void _pushView() {
    final v = view;
    if (presenter.shown && v != null) unawaited(hud.update(v));
  }

  void dispose() {
    _roam?.cancel();
    presenter.dispose();
    pets.removeListener(_petsChanged);
    stats.removeListener(_pushView);
  }
}
