import 'dart:async';
import 'dart:developer' as developer;
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
      // Panel calls are best-effort, local IPC: 500 ms is far longer than a
      // healthy round trip, and a slow or wedged panel must never hold up
      // the pet window (spec: quit's own short overall budget).
      timeout: const Duration(milliseconds: 500),
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
  int _walks = 0; // _walk bodies still in flight; the last one out frees the panel
  bool _dragging = false;
  bool _disposed = false;
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
    _walks++;
    presenter.busy = true;
    try {
      await pets.playAction('walk');
      if (gen != _walkGen) {
        // Superseded while our own clip was still being matted. If it landed
        // anyway it would loop in place forever, so hand it back to stand.
        if (pets.currentAction == 'walk' && !walker.walking) unawaited(pets.playAction('stand'));
        return;
      }
      if (pets.currentAction != 'walk') return;
      await walker.walk(length);
    } finally {
      // The panel stays down while a drag, a live walk or the walk that took
      // this one's place is still going on. walker.walking alone is not
      // enough: WalkDriver.walk() ends the walk it replaces before it has
      // awaited the window bounds, so the superseded walk wakes up here one
      // microtask later, while its replacement is not yet walking -- and the
      // panel would pop up over a window that is about to move away.
      _walks--;
      presenter.busy = _dragging || walker.walking || _walks > 0;
    }
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

  /// Quitting: stop walking and take the panel off the screen, and wait for
  /// the panel to actually be gone -- quitting from the pet's right-click menu
  /// happens with the pointer on the pet, so the panel is usually up, and the
  /// native teardown after destroy() takes seconds with a topmost window still
  /// on screen. Waiting is safe: every hud call is capped at 500 ms (the
  /// bridge's own timeout) and AppExit runs its hide steps together, so this
  /// can cost at most a quarter of its 2 s budget.
  Future<void> shutdown() async {
    _walkGen++;
    walker.stop();
    _roam?.cancel();
    _roam = null;
    await hud.hide();
  }

  void _petsChanged() {
    if (_disposed) return;
    final id = pets.currentPet?.id;
    if (id != _petId) {
      _petId = id;
      stats.select(id);
      // Adopting goes through the controller, not through us, so a walk can
      // still be sliding the window while the new pet stands on screen. The
      // parked _walk wakes into its own superseded branch.
      _walkGen++;
      walker.stop();
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
        if (_disposed) return;
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
    if (_disposed) return;
    try {
      final v = view;
      if (v == null) return;
      // Asking the platform for our own rectangle is a round trip: a drag or
      // a walk starting meanwhile makes the presenter hide the panel and
      // forget it, and a show landing after that would leave a panel on the
      // desktop that the presenter believes is gone -- never updated, never
      // taken away.
      final b = await mover.bounds();
      if (_disposed || !presenter.shown) return;
      await hud.show(b, v);
      if (!presenter.shown) unawaited(hud.hide());
    } catch (e) {
      developer.log('showHud failed: $e', name: 'aipet.hud');
    }
  }

  void _pushView() {
    if (_disposed) return;
    final v = view;
    if (presenter.shown && v != null) unawaited(hud.update(v));
  }

  void dispose() {
    _disposed = true;
    _walkGen++;
    walker.stop();
    _roam?.cancel();
    _roam = null;
    presenter.dispose();
    pets.removeListener(_petsChanged);
    stats.removeListener(_pushView);
  }
}
