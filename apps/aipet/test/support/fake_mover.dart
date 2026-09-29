import 'dart:ui';

import 'package:aipet/app/pet_window/window_mover.dart';

/// A pet window on a 1707 x 1027 work area; moves are recorded and applied.
class FakeMover implements WindowMover {
  FakeMover({this.rect = const Rect.fromLTWH(100, 500, 360, 360), this.work = const Rect.fromLTWH(0, 0, 1707, 1027)});

  Rect rect;
  Rect? work;
  final moves = <Offset>[];

  @override
  Future<Rect> bounds() async => rect;

  @override
  Future<Rect?> workArea(Rect window) async => work;

  @override
  void moveTo(Offset topLeft) {
    moves.add(topLeft);
    rect = topLeft & rect.size;
  }
}
