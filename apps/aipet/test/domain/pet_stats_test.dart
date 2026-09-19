import 'package:aipet/domain/pet_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 19, 9);
  PetStats at(DateTime t, {double intimacy = 50, double satiety = 50, double health = 100, int today = 0}) => PetStats(
        intimacy: intimacy,
        satiety: satiety,
        health: health,
        companionStartedAt: t,
        interactionDay: dayOf(t),
        todayInteractions: today,
        updatedAt: t,
      );

  test('a new pet starts at 50 / 50 / 100 on day one', () {
    final s = PetStats.fresh(t0);
    expect([s.intimacy, s.satiety, s.health], [50, 50, 100]);
    expect(s.todayInteractions, 0);
    expect(companionDays(s, t0), 1);
    expect(statusText(s), '状态很好');
  });

  test('satiety drains in a day and health drops once it is below 20', () {
    // 12 h: satiety 50 -> 0; it is below 20 after 7.2 h, so health loses 2/h for ~4.8 h -> ~90.4
    final s = advanceStats(at(t0), t0.add(const Duration(hours: 12)));
    expect(s.satiety, closeTo(0, 1e-6));
    expect(s.health, closeTo(90.4, 0.05));
    expect(s.updatedAt, t0.add(const Duration(hours: 12)));
  });

  test('a well-fed pet recovers health', () {
    // satiety 100 -> 75 in 6 h (never below 50), health +5/h: 50 -> 80
    final s = advanceStats(at(t0, satiety: 100, health: 50), t0.add(const Duration(hours: 6)));
    expect(s.satiety, closeTo(75, 1e-6));
    expect(s.health, closeTo(80, 1e-6));
  });

  test('values stay within 0..100', () {
    final s = advanceStats(at(t0, satiety: 10, health: 5), t0.add(const Duration(hours: 24)));
    expect(s.satiety, 0);
    expect(s.health, 0);
  });

  test('a year away is capped at 30 days and is quick', () {
    final sw = Stopwatch()..start();
    final s = advanceStats(at(t0, satiety: 100, health: 100), t0.add(const Duration(days: 365)));
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect([s.satiety, s.health], [0, 0]);
  });

  test('a clock that went back changes nothing but the timestamp', () {
    final back = t0.subtract(const Duration(hours: 3));
    final s = advanceStats(at(t0, satiety: 70), back);
    expect(s.satiety, 70);
    expect(s.updatedAt, back);
  });

  test("today's count resets on a new day", () {
    final s = advanceStats(at(t0, today: 5), DateTime(2026, 9, 20, 0, 1));
    expect(s.todayInteractions, 0);
    expect(s.interactionDay, DateTime(2026, 9, 20));
  });

  test('an interaction adds intimacy and counts today; feeding adds 30 satiety up to 100', () {
    final s = recordInteraction(at(t0), t0);
    expect(s.intimacy, 51);
    expect(s.todayInteractions, 1);
    expect(s.satiety, 50);
    final fed = recordInteraction(at(t0, satiety: 85, intimacy: 100), t0, fed: true);
    expect(fed.satiety, 100);
    expect(fed.intimacy, 100);
  });

  test('status text follows health first, then satiety', () {
    expect(statusText(at(t0, health: 59, satiety: 90)), '不太舒服');
    expect(statusText(at(t0, satiety: 19)), '饿坏了');
    expect(statusText(at(t0, satiety: 49)), '有点饿了');
    expect(statusText(at(t0, satiety: 50)), '状态很好');
  });

  test('companion days count calendar days', () {
    final s = at(DateTime(2026, 9, 19, 23, 59));
    expect(companionDays(s, DateTime(2026, 9, 20, 0, 1)), 2);
    expect(companionDays(s, DateTime(2026, 9, 19, 23, 59, 30)), 1);
  });

  test('json round trip, and bad json is refused', () {
    final s = recordInteraction(PetStats.fresh(t0), t0.add(const Duration(minutes: 90)), fed: true);
    expect(PetStats.fromJson(Map<Object?, Object?>.from(s.toJson())), s);
    expect(() => PetStats.fromJson({'intimacy': 'x'}), throwsFormatException);
  });
}
