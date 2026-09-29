/// Light nurture (spec 2026-09-19 desktop interaction, 3.3). Pure: every
/// function is given the time to use. Times are local wall-clock.
library;

const double kSatietyPerHour = 100 / 24; // full to empty in a day
const double kFeedSatiety = 30;
const double kHungryBelow = 20;
const double kFedFrom = 50;
const double kHungryHealthPerHour = 2;
const double kRecoverHealthPerHour = 5;
const Duration kMaxCatchUp = Duration(days: 30);

DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);

class PetStats {
  const PetStats({
    required this.intimacy,
    required this.satiety,
    required this.health,
    required this.companionStartedAt,
    required this.interactionDay,
    required this.todayInteractions,
    required this.updatedAt,
  });

  /// A newly adopted pet.
  factory PetStats.fresh(DateTime now) => PetStats(
        intimacy: 50,
        satiety: 50,
        health: 100,
        companionStartedAt: now,
        interactionDay: dayOf(now),
        todayInteractions: 0,
        updatedAt: now,
      );

  /// Throws [FormatException] on a missing or mistyped field.
  factory PetStats.fromJson(Map<Object?, Object?> j) {
    double number(String k) {
      final v = j[k];
      if (v is! num) throw FormatException('stats "$k" is not a number');
      return v.toDouble();
    }

    int integer(String k) {
      final v = j[k];
      if (v is! int) throw FormatException('stats "$k" is not an integer');
      return v;
    }

    DateTime time(String k) => DateTime.fromMillisecondsSinceEpoch(integer(k));
    return PetStats(
      intimacy: number('intimacy'),
      satiety: number('satiety'),
      health: number('health'),
      companionStartedAt: time('companionStartedAt'),
      interactionDay: time('interactionDay'),
      todayInteractions: integer('todayInteractions'),
      updatedAt: time('updatedAt'),
    );
  }

  final double intimacy;
  final double satiety;
  final double health;
  final DateTime companionStartedAt;
  final DateTime interactionDay; // local midnight of the day todayInteractions counts
  final int todayInteractions;
  final DateTime updatedAt;

  PetStats copyWith({
    double? intimacy,
    double? satiety,
    double? health,
    DateTime? interactionDay,
    int? todayInteractions,
    DateTime? updatedAt,
  }) =>
      PetStats(
        intimacy: intimacy ?? this.intimacy,
        satiety: satiety ?? this.satiety,
        health: health ?? this.health,
        companionStartedAt: companionStartedAt,
        interactionDay: interactionDay ?? this.interactionDay,
        todayInteractions: todayInteractions ?? this.todayInteractions,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, Object?> toJson() => {
        'intimacy': intimacy,
        'satiety': satiety,
        'health': health,
        'companionStartedAt': companionStartedAt.millisecondsSinceEpoch,
        'interactionDay': interactionDay.millisecondsSinceEpoch,
        'todayInteractions': todayInteractions,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  @override
  bool operator ==(Object other) =>
      other is PetStats &&
      other.intimacy == intimacy &&
      other.satiety == satiety &&
      other.health == health &&
      other.companionStartedAt == companionStartedAt &&
      other.interactionDay == interactionDay &&
      other.todayInteractions == todayInteractions &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode =>
      Object.hash(intimacy, satiety, health, companionStartedAt, interactionDay, todayInteractions, updatedAt);
}

double _clamp(double v) => v < 0 ? 0 : (v > 100 ? 100 : v);

PetStats _rollDay(PetStats s, DateTime now) =>
    dayOf(now) == s.interactionDay ? s : s.copyWith(interactionDay: dayOf(now), todayInteractions: 0);

/// Time passes: satiety drains and health follows it, a minute at a time
/// (satiety crosses the 20 / 50 thresholds on the way). A clock that went
/// back changes nothing but the timestamp.
PetStats advanceStats(PetStats s, DateTime now) {
  if (!now.isAfter(s.updatedAt)) return _rollDay(s.copyWith(updatedAt: now), now);
  var from = s.updatedAt;
  if (now.difference(from) > kMaxCatchUp) from = now.subtract(kMaxCatchUp);
  var satiety = s.satiety;
  var health = s.health;
  var hours = now.difference(from).inMicroseconds / Duration.microsecondsPerHour;
  const minute = 1 / 60;
  while (hours > 0) {
    final dt = hours < minute ? hours : minute;
    satiety = _clamp(satiety - kSatietyPerHour * dt);
    if (satiety < kHungryBelow) {
      health = _clamp(health - kHungryHealthPerHour * dt);
    } else if (satiety >= kFedFrom) {
      health = _clamp(health + kRecoverHealthPerHour * dt);
    }
    hours -= dt;
  }
  return _rollDay(s.copyWith(satiety: satiety, health: health, updatedAt: now), now);
}

/// The user played with the pet; [fed] for the feed action.
PetStats recordInteraction(PetStats s, DateTime now, {bool fed = false}) {
  final a = advanceStats(s, now);
  return a.copyWith(
    intimacy: _clamp(a.intimacy + 1),
    todayInteractions: a.todayInteractions + 1,
    satiety: fed ? _clamp(a.satiety + kFeedSatiety) : null,
  );
}

/// Judged on the rounded values, because those are the ones the panel prints
/// beside this line: a pet at 49.6 shows 饱食度 50% and must not be called
/// hungry next to it.
String statusText(PetStats s) {
  if (s.health.round() < 60) return '不太舒服';
  if (s.satiety.round() < kHungryBelow) return '饿坏了';
  if (s.satiety.round() < kFedFrom) return '有点饿了';
  return '状态很好';
}

/// Calendar days since adoption, the first day counting as 1 (UTC dates so a
/// DST night cannot lose a day).
int companionDays(PetStats s, DateTime now) {
  DateTime day(DateTime t) => DateTime.utc(t.year, t.month, t.day);
  return day(now).difference(day(s.companionStartedAt)).inDays + 1;
}
