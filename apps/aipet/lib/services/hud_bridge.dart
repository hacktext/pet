import 'dart:developer' as developer;
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import '../domain/pet.dart';
import 'window_bridge.dart';

/// Pet window <-> panel window (spec 2026-09-19 E 3.1). A bidirectional
/// channel pairs at most two engines; 'aipet/pet' is the pet window and the
/// library, so the panel gets its own.
const kHudChannel = WindowMethodChannel('aipet/hud');

abstract final class HudMethods {
  static const show = 'hudShow';
  static const update = 'hudUpdate';
  static const hide = 'hudHide';
  static const action = 'hudAction';
  static const close = 'hudClose';
  static const hover = 'hudHover';
}

/// A dog's or cat's buttons, in order (spec 3.5); greyed out where the pet
/// lacks the action.
const kHudButtons = ['stand', 'walk', 'feed', 'play'];

/// The panel's buttons for a pet: an animal's four above, then the rest of
/// its actions; a character's own actions -- they are not an animal's. Both
/// in pet.json order.
List<String> hudButtonsFor(Species species, List<String> actions) => species.isCharacter
    ? List.unmodifiable(actions)
    : List.unmodifiable([...kHudButtons, ...actions.where((a) => !kHudButtons.contains(a))]);

/// What the panel shows; numbers already rounded.
/// The panel's 声音 switch beside a speaking character's name: not an
/// action, so it is neither counted nor played.
const kHudVoiceToggle = 'voiceToggle';

class HudView {
  const HudView({
    required this.name,
    required this.cover,
    required this.status,
    required this.companionDays,
    required this.todayInteractions,
    required this.intimacy,
    required this.satiety,
    required this.health,
    required this.buttons,
    required this.enabled,
    this.voiceOn,
  });

  factory HudView.fromJson(Map<Object?, Object?> j) => HudView(
        name: j['name']! as String,
        cover: j['cover']! as String,
        status: j['status']! as String,
        companionDays: j['companionDays']! as int,
        todayInteractions: j['todayInteractions']! as int,
        intimacy: j['intimacy']! as int,
        satiety: j['satiety'] as int?,
        health: j['health']! as int,
        buttons: [for (final v in j['buttons']! as List<Object?>) v! as String],
        enabled: {for (final v in j['enabled']! as List<Object?>) v! as String},
        voiceOn: j['voiceOn'] as bool?,
      );

  final String name;
  final String cover; // absolute path of the pet's cover.png
  final String status;
  final int companionDays;
  final int todayInteractions;
  final int intimacy;
  final int? satiety; // null: no 饱食度 (a character)
  final int health;
  final List<String> buttons; // shown, in order
  final Set<String> enabled; // which of [buttons] this pet has
  final bool? voiceOn; // null: the pet does not speak (no 声音 switch)

  Map<String, Object?> toJson() => {
        'name': name,
        'cover': cover,
        'status': status,
        'companionDays': companionDays,
        'todayInteractions': todayInteractions,
        'intimacy': intimacy,
        'satiety': satiety,
        'health': health,
        'buttons': buttons,
        'enabled': [for (final b in buttons) if (enabled.contains(b)) b],
        'voiceOn': voiceOn,
      };

  @override
  bool operator ==(Object other) =>
      other is HudView &&
      other.name == name &&
      other.cover == cover &&
      other.status == status &&
      other.companionDays == companionDays &&
      other.todayInteractions == todayInteractions &&
      other.intimacy == intimacy &&
      other.satiety == satiety &&
      other.health == health &&
      listEquals(other.buttons, buttons) &&
      setEquals(other.enabled, enabled) &&
      other.voiceOn == voiceOn;

  @override
  int get hashCode => Object.hash(name, cover, status, companionDays, todayInteractions, intimacy, satiety, health,
      Object.hashAll(buttons), Object.hashAllUnordered(enabled), voiceOn);
}

List<double> _rectToList(Rect r) => [r.left, r.top, r.width, r.height];

Rect _rectFromList(Object? v) {
  final l = (v! as List<Object?>).cast<num>();
  return Rect.fromLTWH(l[0].toDouble(), l[1].toDouble(), l[2].toDouble(), l[3].toDouble());
}

/// Pet-window end. Every call is best effort: without a panel the pet
/// window works as before.
class PetHudBridge {
  PetHudBridge(
    this._transport, {
    required this.onAction,
    required this.onClose,
    required this.onHover,
    this.timeout = const Duration(seconds: 2),
  });

  final BridgeTransport _transport;
  final void Function(String key) onAction;
  final void Function() onClose;
  final void Function(bool inside) onHover;
  final Duration timeout;

  void start() => _transport.setHandler((method, args) async {
        final m = args as Map<Object?, Object?>?;
        switch (method) {
          case HudMethods.action:
            onAction(m!['key']! as String);
          case HudMethods.close:
            onClose();
          case HudMethods.hover:
            onHover(m!['inside']! as bool);
        }
        return null;
      });

  Future<void> show(Rect pet, HudView view) =>
      _send(HudMethods.show, {'bounds': _rectToList(pet), 'view': view.toJson()});

  Future<void> update(HudView view) => _send(HudMethods.update, {'view': view.toJson()});

  Future<void> hide() => _send(HudMethods.hide);

  Future<void> _send(String method, [Object? args]) async {
    try {
      await _transport.invoke(method, args).timeout(timeout);
    } catch (e) {
      developer.log('$method failed: $e', name: 'aipet.hud');
    }
  }
}

/// Panel end.
class HudWindowBridge {
  HudWindowBridge(this._transport, {required this.onShow, required this.onUpdate, required this.onHide});

  final BridgeTransport _transport;
  final Future<void> Function(Rect pet, HudView view) onShow;
  final void Function(HudView view) onUpdate;
  final Future<void> Function() onHide;

  void start() => _transport.setHandler((method, args) async {
        final m = args as Map<Object?, Object?>?;
        switch (method) {
          case HudMethods.show:
            await onShow(_rectFromList(m!['bounds']), HudView.fromJson(m['view']! as Map<Object?, Object?>));
          case HudMethods.update:
            onUpdate(HudView.fromJson(m!['view']! as Map<Object?, Object?>));
          case HudMethods.hide:
            await onHide();
        }
        return null;
      });

  void action(String key) => _fire(HudMethods.action, {'key': key});

  void close() => _fire(HudMethods.close);

  void hover(bool inside) => _fire(HudMethods.hover, {'inside': inside});

  void _fire(String method, [Object? args]) {
    Future<Object?>.sync(() => _transport.invoke(method, args))
        .then<void>((_) {}, onError: (Object e) => developer.log('$method failed: $e', name: 'aipet.hud'));
  }
}
