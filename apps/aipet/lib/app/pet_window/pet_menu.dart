import 'package:flutter/material.dart';

import '../../domain/pet.dart';

/// Every entry is this tall, so a level's height is countable: the top level
/// is 3 * 36 + 16 of menu padding = 124, the actions 7 * 36 + 16 = 268, and
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
Future<PetMenuPick?> showPetMenu(
  BuildContext context, {
  required Offset at,
  required List<String> actions,
  String? currentAction,
}) async {
  final choice = await _level(context, at, [
    if (actions.isNotEmpty)
      const PopupMenuItem<String>(value: _openActions, height: kPetMenuItemHeight, child: Text('动作')),
    const PopupMenuItem<String>(value: _openLibrary, height: kPetMenuItemHeight, child: Text('打开宠物库')),
    const PopupMenuItem<String>(value: _quit, height: kPetMenuItemHeight, child: Text('退出')),
  ]);
  if (choice == _openLibrary) return const PetMenuOpenLibrary();
  if (choice == _quit) return const PetMenuQuit();
  if (choice != _openActions) return null;
  if (!context.mounted) return null; // the window went away while the menu was up
  final action = await _level(context, at, [
    for (final a in actions) _actionItem(a, current: a == currentAction),
  ]);
  return action == null ? null : PetMenuAction(action);
}

const String _openActions = 'actions';
const String _openLibrary = 'open';
const String _quit = 'quit';

/// One action, ticked when it is the one playing. Not [CheckedPopupMenuItem]:
/// that one is a ListTile, which is 56 px tall whatever `height` asks for, and
/// seven of those overflow the window all over again.
PopupMenuItem<String> _actionItem(String key, {required bool current}) => PopupMenuItem<String>(
      key: Key('pet-menu-action-$key'),
      value: key,
      height: kPetMenuItemHeight,
      child: Row(children: [
        SizedBox(width: 24, child: current ? const Icon(Icons.done, size: 18) : null),
        Text(labelFor(key)),
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
