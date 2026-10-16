/// Meal and drink times: at each slot the pet asks for food or water with a
/// bubble over its head and waits to be fed (吃饭, which also stands in for
/// drinking: there is no drink clip). Pure: every function is given the time.
/// Times are local wall-clock.
library;

enum NeedKind {
  food('我饿了，想吃饭~', '想吃饭了'),
  water('口渴了，想喝水~', '想喝水了');

  const NeedKind(this.bubble, this.status);

  /// Over the pet's head.
  final String bubble;

  /// The panel's status line while the need is open.
  final String status;
}

class NeedSlot {
  const NeedSlot(this.hour, this.minute, this.kind);

  final int hour;
  final int minute;
  final NeedKind kind;

  DateTime on(DateTime day) => DateTime(day.year, day.month, day.day, hour, minute);
}

/// Breakfast, lunch and dinner, with a drink between each.
const kNeedSlots = [
  NeedSlot(8, 0, NeedKind.food),
  NeedSlot(10, 0, NeedKind.water),
  NeedSlot(12, 0, NeedKind.food),
  NeedSlot(15, 0, NeedKind.water),
  NeedSlot(18, 30, NeedKind.food),
  NeedSlot(21, 0, NeedKind.water),
];

/// A slot nobody served lapses after this: no breakfast request at noon.
const kNeedLapse = Duration(hours: 2);

/// An open need asks again this often.
const kNeedRemind = Duration(minutes: 30);

/// One slot on one day.
class Need {
  const Need(this.slot, this.since);

  final NeedSlot slot;
  final DateTime since;

  NeedKind get kind => slot.kind;

  @override
  bool operator ==(Object other) => other is Need && other.slot == slot && other.since == since;

  @override
  int get hashCode => Object.hash(slot, since);
}

/// The need open at [now]: the latest slot that has started, has not lapsed,
/// and was not served since it started. [lastServed] is the last feeding.
Need? openNeed(DateTime now, DateTime? lastServed) {
  Need? open;
  for (final slot in kNeedSlots) {
    final since = slot.on(now);
    if (since.isAfter(now) || !now.isBefore(since.add(kNeedLapse))) continue;
    if (lastServed != null && !lastServed.isBefore(since)) continue;
    open = Need(slot, since); // slots are in order: the latest one wins
  }
  return open;
}
