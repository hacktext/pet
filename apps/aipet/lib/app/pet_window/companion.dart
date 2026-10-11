import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import '../../domain/pet.dart';
import '../../domain/pet_stats.dart';
import '../../services/hud_bridge.dart';
import '../../services/voice_player.dart';
import '../../services/voice_store.dart';
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
    required this.voices,
    required this.voicePlayer,
    Random? random,
    this.userWalk = const Duration(seconds: 20),
    this.onInteract,
    this.onVoiceChosen,
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
  final VoiceStore voices;
  final VoicePlayer voicePlayer;
  final Duration userWalk;
  final Random _random;

  /// The user did something with the pet (telemetry's `interact`): [kind] is
  /// the action key from the panel or the menu, or `drag`.
  final void Function(String petId, String kind)? onInteract;

  /// The user picked another voice for the pet: a voice id or [kVoiceOff].
  final void Function(String petId, String voice)? onVoiceChosen;
  late final HudPresenter presenter;
  late final PetHudBridge hud;

  Timer? _roam;
  int _walkGen = 0;
  int _showGen = 0; // only the newest _showHud may place the panel
  int _walks = 0; // _walk bodies still in flight; the last one out frees the panel
  bool _dragging = false;

  /// Shut down or disposed -- once either has happened the panel is on its way
  /// off the screen and nothing may put it back.
  bool _disposed = false;
  String? _petId;

  /// The panel's content; null with nobody on the desktop.
  HudView? get view {
    final pet = pets.currentPet;
    final s = stats.current;
    if (pet == null || s == null) return null;
    final buttons = hudButtonsFor(pet.species, pet.actions);
    return HudView(
      name: pet.name,
      cover: pet.coverFile.path,
      status: statusText(s),
      companionDays: companionDays(s, stats.now),
      todayInteractions: s.todayInteractions,
      intimacy: s.intimacy.round(),
      satiety: s.satiety.round(),
      health: s.health.round(),
      buttons: buttons,
      enabled: {for (final b in buttons) if (pet.actions.contains(b)) b},
    );
  }

  /// A button in the panel or an item in the right-click menu: counts as an
  /// interaction; 'walk' walks across the screen, anything else plays.
  Future<void> userAction(String key) async {
    // The panel is hidden on the way out, not stopped: a click already on its
    // way still arrives over the bridge. Acting on it would rewrite
    // stats.json during the teardown and walk a window that is off screen.
    if (_disposed) return;
    final pet = pets.currentPet;
    if (pet == null || !pet.actions.contains(key)) return;
    stats.interact(key);
    onInteract?.call(pet.id, key);
    if (key == 'walk') {
      voicePlayer.stop();
      return _walk(userWalk);
    }
    _walkGen++;
    walker.stop();
    await pets.playAction(key);
    if (!_disposed && pets.currentPet == pet) _speak(pet, key);
  }

  /// The current pet's voices; empty for one that does not speak.
  List<PetVoice> get availableVoices => pets.currentPet?.voices ?? const [];

  /// The voice the current pet speaks in: the one chosen for it, else its
  /// first; null when it has none or was set to 静音.
  String? get currentVoice {
    final pet = pets.currentPet;
    if (pet == null || pet.voices.isEmpty) return null;
    final chosen = voices.choice(pet.id);
    if (chosen == kVoiceOff) return null;
    return pet.voices.any((v) => v.id == chosen) ? chosen : pet.voices.first.id;
  }

  /// From the right-click menu: a voice id, or null for 静音.
  void chooseVoice(String? voice) {
    final pet = pets.currentPet;
    if (_disposed || pet == null) return;
    final before = voices.choice(pet.id);
    voices.choose(pet.id, voice ?? kVoiceOff);
    if (before != (voice ?? kVoiceOff)) onVoiceChosen?.call(pet.id, voice ?? kVoiceOff);
    if (voice == null) voicePlayer.stop();
  }

  /// One of the lines for [action] in the current voice; an action with none
  /// cuts off whatever was still being said.
  void _speak(Pet pet, String action) {
    final voice = currentVoice;
    final lines = voice == null ? const <File>[] : pet.voiceLines(voice, action);
    if (lines.isEmpty) return voicePlayer.stop();
    voicePlayer.play(lines[_random.nextInt(lines.length)]);
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
      // Not once we are on our way out: a walk stopped by shutdown() wakes up
      // here after the panel has been hidden, and freeing the panel with the
      // pointer still on the pet would ask for it right back.
      if (!_disposed) presenter.busy = _dragging || walker.walking || _walks > 0;
    }
    if (gen == _walkGen && pets.currentAction == 'walk') await pets.playAction('stand');
  }

  void petEnter() => presenter.petEnter();

  void petExit() => presenter.petExit();

  void dragStarted() {
    final pet = pets.currentPet;
    if (!_disposed && pet != null) onInteract?.call(pet.id, 'drag');
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
  ///
  /// Marking us finished comes first, and before the hide: whatever wakes up
  /// while we wait -- a stopped walk freeing the panel, a stats listener --
  /// must not ask for a panel we have just taken away.
  Future<void> shutdown() async {
    _disposed = true;
    voicePlayer.stop();
    presenter.dispose();
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
      voicePlayer.stop(); // the last pet's line does not carry over
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
      // Below the check above: a show given up for want of a pet places
      // nothing, so it must not invalidate one that is still in flight.
      final gen = ++_showGen;
      // Asking the platform for our own rectangle is a round trip: a drag or
      // a walk starting meanwhile makes the presenter hide the panel and
      // forget it, and a show landing after that would leave a panel on the
      // desktop that the presenter believes is gone -- never updated, never
      // taken away. `shown` alone is not enough either: it is true again once
      // the pointer settles back on the pet, and the round trips can answer
      // out of order, so an older one would place the panel over the window's
      // old rectangle and leave it there.
      final b = await mover.bounds();
      if (_disposed || gen != _showGen || !presenter.shown) return;
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
    voicePlayer.stop();
    _walkGen++;
    walker.stop();
    _roam?.cancel();
    _roam = null;
    presenter.dispose();
    pets.removeListener(_petsChanged);
    stats.removeListener(_pushView);
  }
}
