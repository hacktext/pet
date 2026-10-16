import 'package:aipet/domain/needs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DateTime at(int h, [int m = 0]) => DateTime(2026, 10, 16, h, m);

  test('nothing is open before breakfast', () {
    expect(openNeed(at(7, 59), null), isNull);
  });

  test('breakfast at 8:00, a drink at 10:00, lunch at 12:00, a drink at 15:00, dinner at 18:30, a drink at 21:00',
      () {
    expect(openNeed(at(8), null)?.kind, NeedKind.food);
    expect(openNeed(at(10, 5), null)?.kind, NeedKind.water);
    expect(openNeed(at(12, 1), null)?.kind, NeedKind.food);
    expect(openNeed(at(15), null)?.kind, NeedKind.water);
    expect(openNeed(at(18, 30), null)?.kind, NeedKind.food);
    expect(openNeed(at(21, 30), null)?.kind, NeedKind.water);
  });

  test('feeding after a slot started closes it; feeding before it does not', () {
    expect(openNeed(at(8, 20), at(8, 10)), isNull);
    expect(openNeed(at(8, 20), at(7, 50)), Need(kNeedSlots[0], at(8)));
  });

  test('an unserved slot lapses after 2 hours', () {
    expect(openNeed(at(9, 59), null)?.since, at(8));
    expect(openNeed(at(23, 0), null), isNull); // 21:00 + 2 h
    expect(openNeed(at(13, 30), at(12, 5)), isNull); // lunch served, the 10:00 drink long gone
  });

  test('the need carries its words', () {
    expect(NeedKind.food.bubble, '我饿了，想吃饭~');
    expect(NeedKind.water.status, '想喝水了');
  });
}
