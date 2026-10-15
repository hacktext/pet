import 'dart:math' as math;
import 'dart:ui';

/// How big the pet stands on the desktop: the pet window's edge, logical
/// pixels. The window is the pet's hit area, so a smaller pet also takes up
/// less of the desktop.
enum PetSize {
  small('小', 200),
  medium('中', 270),
  large('大', 360);

  const PetSize(this.label, this.edge);

  final String label;
  final double edge;

  /// What a first run gets: the size the pet always had.
  static const fallback = large;

  static PetSize? byName(Object? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return null;
  }
}

/// The right-click menu lays out inside the pet window, and its levels were
/// counted against 360 x 360 (see pet_menu.dart). A smaller pet's window
/// grows to this while the menu is up.
const double kPetMenuRoom = 360;

/// The window for a pet at [pet] while the menu is up: [kPetMenuRoom] square,
/// centred on the pet and pushed back inside [work] when there is one. The
/// pet itself does not move; it is drawn at its old rectangle inside this.
Rect menuRoomFor(Rect pet, Rect? work) {
  if (pet.width >= kPetMenuRoom && pet.height >= kPetMenuRoom) return pet;
  var left = pet.center.dx - kPetMenuRoom / 2;
  var top = pet.center.dy - kPetMenuRoom / 2;
  if (work != null) {
    left = left.clamp(work.left, math.max(work.left, work.right - kPetMenuRoom)).toDouble();
    top = top.clamp(work.top, math.max(work.top, work.bottom - kPetMenuRoom)).toDouble();
  }
  return Rect.fromLTWH(left, top, kPetMenuRoom, kPetMenuRoom);
}

/// The pet window at [pet] resized to [size]: its feet stay where they were
/// (bottom centre), so a pet standing on the taskbar keeps standing on it.
Rect resizedPet(Rect pet, PetSize size) =>
    Rect.fromLTWH(pet.center.dx - size.edge / 2, pet.bottom - size.edge, size.edge, size.edge);
