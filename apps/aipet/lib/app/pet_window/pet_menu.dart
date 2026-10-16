import 'package:flutter/material.dart';

import '../../domain/pet.dart';
import '../../domain/pet_size.dart';

/// Every entry is this tall, so a level's height is countable: the top level
/// is at most 6 * 36 + 16 of menu padding = 232, the actions 7 * 36 + 16 = 268, and
/// showMenu allows 360 - 16 = 344 inside the pet window.
const double kPetMenuItemHeight = 36;

/// What the user picked from the pet's right-click menu; null for a menu
/// dismissed without a pick.
sealed class PetMenuPick {
  const PetMenuPick();
}

/// Play one of the pet's actions.
final class PetMenuAction extends PetMenuPick {
  const PetMenuAction(this.action);

  final String action;
}

/// Speak in this voice from now on; null is 静音.
final class PetMenuVoice extends PetMenuPick {
  const PetMenuVoice(this.voice);

  final String? voice;
}

/// Make the pet this big from now on.
final class PetMenuSize extends PetMenuPick {
  const PetMenuSize(this.size);

  final PetSize size;
}

/// 隐藏: off the desktop until the tray or the hotkey brings it back.
final class PetMenuHide extends PetMenuPick {
  const PetMenuHide();
}

/// 打开宠物库.
final class PetMenuOpenLibrary extends PetMenuPick {
  const PetMenuOpenLibrary();
}

/// 退出.
final class PetMenuQuit extends PetMenuPick {
  const PetMenuQuit();
}

/// The pet's right-click menu, opened at [at] (a global position), in two
/// levels because the menu lives in the pet window's overlay and that window
/// is 360x360 -- its size is the pet's hit area, so it cannot grow. One flat
/// menu of seven actions plus 打开宠物库 and 退出 is 496 px tall, 152 more
/// than fits, and the two commands end up below the fold. Three entries on
/// top and the actions on a level of their own both fit with room to spare.
///
/// [actions] empty (nobody adopted yet) drops 动作, leaving the two commands.
/// [voices] non-empty (a character that speaks) adds 声音, a level of its
/// voices and 静音 with [currentVoice] -- null for 静音 -- ticked. 大小 is
/// always there, a level of the sizes with [currentSize] ticked. A pet
/// smaller than 大 has a smaller window; the caller grows it to
/// [kPetMenuRoom] while the menu is up, so these counts still hold.
Future<PetMenuPick?> showPetMenu(
  BuildContext context, {
  required Offset at,
  required List<String> actions,
  String? currentAction,
  List<PetVoice> voices = const [],
  String? currentVoice,
  PetSize currentSize = PetSize.fallback,
}) async {
  final choice = await _level(context, at, [
    if (actions.isNotEmpty)
      const PopupMenuItem<String>(value: _openActions, height: kPetMenuItemHeight, child: Text('动作')),
    if (voices.isNotEmpty)
      const PopupMenuItem<String>(value: _openVoices, height: kPetMenuItemHeight, child: Text('声音')),
    const PopupMenuItem<String>(value: _openSizes, height: kPetMenuItemHeight, child: Text('大小')),
    const PopupMenuItem<String>(value: _hide, height: kPetMenuItemHeight, child: Text('隐藏')),
    const PopupMenuItem<String>(value: _openLibrary, height: kPetMenuItemHeight, child: Text('打开宠物库')),
    const PopupMenuItem<String>(value: _quit, height: kPetMenuItemHeight, child: Text('退出')),
  ]);
  if (choice == _openLibrary) return const PetMenuOpenLibrary();
  if (choice == _hide) return const PetMenuHide();
  if (choice == _quit) return const PetMenuQuit();
  if (choice != _openActions && choice != _openVoices && choice != _openSizes) return null;
  if (!context.mounted) return null; // the window went away while the menu was up
  if (choice == _openSizes) {
    final size = await _level(context, at, [
      for (final s in PetSize.values.reversed)
        _checkItem('pet-menu-size-${s.name}', s.name, s.label, current: s == currentSize),
    ]);
    final picked = PetSize.byName(size);
    return picked == null ? null : PetMenuSize(picked);
  }
  if (choice == _openVoices) {
    final voice = await _level(context, at, [
      for (final v in voices) _checkItem('pet-menu-voice-${v.id}', v.id, v.name, current: v.id == currentVoice),
      _checkItem('pet-menu-voice-off', _off, '静音', current: currentVoice == null),
    ]);
    return voice == null ? null : PetMenuVoice(voice == _off ? null : voice);
  }
  final action = await _level(context, at, [
    for (final a in actions) _actionItem(a, current: a == currentAction),
  ]);
  return action == null ? null : PetMenuAction(action);
}

const String _openActions = 'actions';
const String _openVoices = 'voices';
const String _openSizes = 'sizes';
const String _hide = 'hide';
const String _off = 'off';
const String _openLibrary = 'open';
const String _quit = 'quit';

/// One action, ticked when it is the one playing. Not [CheckedPopupMenuItem]:
/// that one is a ListTile, which is 56 px tall whatever `height` asks for, and
/// seven of those overflow the window all over again.
PopupMenuItem<String> _actionItem(String key, {required bool current}) =>
    _checkItem('pet-menu-action-$key', key, labelFor(key), current: current);

PopupMenuItem<String> _checkItem(String key, String value, String label, {required bool current}) =>
    PopupMenuItem<String>(
      key: Key(key),
      value: value,
      height: kPetMenuItemHeight,
      child: Row(children: [
        SizedBox(width: 24, child: current ? const Icon(Icons.done, size: 18) : null),
        Text(label),
      ]),
    );

Future<String?> _level(BuildContext context, Offset at, List<PopupMenuEntry<String>> items) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: items,
  );
}
