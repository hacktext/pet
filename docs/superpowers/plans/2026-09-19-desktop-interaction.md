# 桌面互动 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 鼠标移到宠物上出现状态面板（数值 + 站立 / 行走 / 喂食 / 玩耍）；轻度养成数值随时间变化、按宠物保存；「行走」和空闲时的自动走动让宠物横穿屏幕。

**Architecture:** 纯 Dart 领域层（`PetStats` 规则、`Walker` 轨迹、`hudPosition` 定位）+ 服务层（`StatsStore`、`aipet/hud` 通道、不抢焦点的 Win32 窗口操作）+ 宠物窗里的 `StatsKeeper`、`WalkDriver`、`HudPresenter`，由 `Companion` 统一调度；
面板是第三个 Flutter 引擎（`hud_window`），由宠物窗创建并常驻隐藏。**不抢焦点**：`window_manager` 在 Windows 上的 `show()` 总调 `SetForegroundWindow`，`setPosition()` 走 `SetWindowPos(HWND_TOP)` 且不带 `SWP_NOACTIVATE`，
所以走路移窗和显示面板一律用 FFI 调 `SetWindowPos(… SWP_NOACTIVATE)`。

**Tech Stack:** Flutter 3.47.2 / Dart 3.13.2（`apps/aipet`）；desktop_multi_window 0.3.1、window_manager 0.5.2、screen_retriever 0.2.2、ffi 2.2.0；Python（`tools/petgen`，只改打包）。

**Spec:** `docs/superpowers/specs/2026-09-19-desktop-interaction-design.md`

## Global Constraints

- 仓库根 `C:\Users\Administrator\code\aipet`，分支 `feat/aipet-main-window`，只做 Windows。PowerShell 5.1 没有 `&&`。
- Flutter 不在 PATH：每个 PowerShell 调用先 `$env:PATH = "C:\Users\Administrator\code\envs\flutter\bin;$env:PATH"`；测试在 `apps\aipet` 下 `flutter test <file>`，全量 `flutter test`（当前 115），静态检查 `flutter analyze`。
- petgen 测试：`Set-Location C:\Users\Administrator\code\aipet\tools\petgen; .\.venv\Scripts\python -m pytest -q`（当前 90）。
- **不启动 aipet.exe、不发鼠标键盘输入**（用户在用电脑）；窗口行为留到真机验收。
- **走路移窗、显示面板不得调用 `windowManager.show/setPosition/setBounds`**（会抢焦点），只用 Task 7 的 `NativeWindow`。读位置 `windowManager.getBounds()`、隐藏 `windowManager.hide()` 可以用。
- 宠物窗是唯一写 `settings.json`、`stats.json` 的一方。
- 数值规则（spec 3.3）：新宠物 50 / 50 / 100；饱食每小时 −100/24，喂食 +30；饱食 < 20 时健康每小时 −2，≥ 50 时 +5；互动亲密 +1；上限 100、下限 0；补算最多 30 天。
- 走路：速度 90 逻辑像素 / 秒；点「行走」走 20 秒；空闲 3–6 分钟后自动走 8–15 秒；面板悬停 300 ms 显示、离开 600 ms 隐藏。
- 工作区里 `HANDOFF.md`、`docs/superpowers/plans/2026-09-10-main-window-pet-library-results.md`、`docs/superpowers/plans/2026-09-19-front-facing-pets-results.md`、`tools/dev/*.ps1` 不属于本计划，一律 `git add <具体路径>`。
- 提交信息末尾 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`。

---

## File Structure

```
apps/aipet/lib/domain/pet_stats.dart            PetStats + advanceStats / recordInteraction / statusText / companionDays（Task 1）
apps/aipet/lib/services/stats_store.dart        stats.json（Task 2）
apps/aipet/lib/app/pet_window/stats_keeper.dart 当前宠物的数值：切换、每分钟推进、互动、保存（Task 2）
apps/aipet/lib/domain/walker.dart               Facing、kWalkSpeed、roomierSide、Walker（Task 3）
apps/aipet/lib/domain/hud_layout.dart           kHudSize、hudPosition（Task 3）
apps/aipet/lib/domain/pet.dart                  walkFacing（Task 4）
tools/petgen/petgen/package.py                  walk_facing、pet_json(walkFacing)（Task 4）
apps/aipet/assets/pets/builtin-*/pet.json       手工补 walkFacing（Task 4）
apps/aipet/lib/services/hud_bridge.dart         HudView、PetHudBridge、HudWindowBridge、通道 aipet/hud（Task 5）
apps/aipet/lib/app/pet_window/hud_presenter.dart 悬停 / 显示状态机（Task 6）
apps/aipet/lib/services/native_window.dart      FFI：找本进程窗口、不激活地移动 / 显示（Task 7）
apps/aipet/lib/services/displays.dart           displayWorkArea（Task 7）
apps/aipet/lib/app/pet_window/window_mover.dart WindowMover、DesktopWindowMover（Task 7）
apps/aipet/lib/app/pet_window/walk_driver.dart  一次走路：定时器驱动 Walker 移窗、镜像（Task 8）
apps/aipet/lib/app/pet_window/companion.dart    调度：用户动作、走路、自动走动、面板内容（Task 9）
apps/aipet/lib/app/hud_window/hud_panel.dart    面板界面（Task 10）
apps/aipet/lib/app/hud_window/hud_window_entry.dart 面板引擎入口（Task 10）
apps/aipet/lib/main.dart                        按参数分派三种窗口（Task 10）
apps/aipet/lib/app/pet_window/pet_window_app.dart 接线（Task 11）
apps/aipet/pubspec.yaml                         screen_retriever、ffi（Task 7）
docs/superpowers/plans/2026-09-19-desktop-interaction-results.md 执行结果（Task 12）
```

---

### Task 1: 养成数值规则 `PetStats`

**Files:**
- Create: `apps/aipet/lib/domain/pet_stats.dart`
- Test: `apps/aipet/test/domain/pet_stats_test.dart`

**Interfaces:**
- Produces: `class PetStats`（字段 `intimacy/satiety/health: double`、`companionStartedAt/interactionDay/updatedAt: DateTime`、`todayInteractions: int`；`PetStats.fresh(DateTime now)`、`copyWith`、`toJson()`、`PetStats.fromJson(Map<Object?, Object?>)`（坏字段抛 `FormatException`）、`==`）；
  `DateTime dayOf(DateTime)`；`PetStats advanceStats(PetStats, DateTime now)`；`PetStats recordInteraction(PetStats, DateTime now, {bool fed = false})`；`String statusText(PetStats)`；`int companionDays(PetStats, DateTime now)`。

- [ ] **Step 1: 写失败的测试** —— 新建 `apps/aipet/test/domain/pet_stats_test.dart`：

```dart
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
```

- [ ] **Step 2: 运行确认失败**：`flutter test test/domain/pet_stats_test.dart` → 编译失败（`pet_stats.dart` 不存在）。

- [ ] **Step 3: 实现** —— 新建 `apps/aipet/lib/domain/pet_stats.dart`：

```dart
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

String statusText(PetStats s) {
  if (s.health < 60) return '不太舒服';
  if (s.satiety < kHungryBelow) return '饿坏了';
  if (s.satiety < kFedFrom) return '有点饿了';
  return '状态很好';
}

/// Calendar days since adoption, the first day counting as 1 (UTC dates so a
/// DST night cannot lose a day).
int companionDays(PetStats s, DateTime now) {
  DateTime day(DateTime t) => DateTime.utc(t.year, t.month, t.day);
  return day(now).difference(day(s.companionStartedAt)).inDays + 1;
}
```

- [ ] **Step 4: 运行确认通过**：`flutter test test/domain/pet_stats_test.dart` → 11 passed；`flutter analyze` → No issues found。
- [ ] **Step 5: 提交**：`git add apps/aipet/lib/domain/pet_stats.dart apps/aipet/test/domain/pet_stats_test.dart`；
  `git commit -m "feat(aipet): light nurture stats -- satiety, health, intimacy, today's count" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 2: `StatsStore` 与 `StatsKeeper`

**Files:**
- Create: `apps/aipet/lib/services/stats_store.dart`、`apps/aipet/lib/app/pet_window/stats_keeper.dart`
- Test: `apps/aipet/test/services/stats_store_test.dart`、`apps/aipet/test/app/stats_keeper_test.dart`

**Interfaces:**
- Consumes: Task 1。
- Produces: `StatsStore(Directory root)`：`File get file`、`Map<String, PetStats> load()`（不抛）、`void save(Map<String, PetStats>)`；
  `StatsKeeper(StatsStore, {DateTime Function()? now}) extends ChangeNotifier`：`PetStats? get current`、`DateTime get now`、`void select(String? petId)`、`void tick()`、`void interact(String action)`。

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/services/stats_store_test.dart`：

```dart
import 'dart:io';

import 'package:aipet/domain/pet_stats.dart';
import 'package:aipet/services/stats_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late StatsStore store;
  final t0 = DateTime(2026, 9, 19, 9);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('stats_');
    store = StatsStore(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a first run has no stats', () => expect(store.load(), isEmpty));

  test('round trip', () {
    final all = {'builtin-gold': PetStats.fresh(t0), 'builtin-corgi': recordInteraction(PetStats.fresh(t0), t0, fed: true)};
    store.save(all);
    expect(store.load(), all);
  });

  test('an unreadable file is kept as .bad and treated as empty', () {
    store.file.writeAsStringSync('{nope');
    expect(store.load(), isEmpty);
    expect(File('${store.file.path}.bad').existsSync(), isTrue);
    expect(store.file.existsSync(), isFalse);
  });

  test('one bad entry is dropped, the others kept', () {
    store.file.writeAsStringSync('{"schema":1,"pets":{"a":{"intimacy":"x"},'
        '"b":${_json(PetStats.fresh(t0))}}}');
    expect(store.load().keys, ['b']);
  });
}

String _json(PetStats s) => '{${s.toJson().entries.map((e) => '"${e.key}":${e.value}').join(',')}}';
```

`apps/aipet/test/app/stats_keeper_test.dart`：

```dart
import 'dart:io';

import 'package:aipet/app/pet_window/stats_keeper.dart';
import 'package:aipet/services/stats_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late DateTime now;
  StatsKeeper make() => StatsKeeper(StatsStore(tmp), now: () => now);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('keeper_');
    now = DateTime(2026, 9, 19, 9);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('nobody selected: no stats, and actions are ignored', () {
    final k = make()..interact('feed');
    expect(k.current, isNull);
  });

  test('a newly selected pet starts fresh and is saved', () {
    make().select('builtin-gold');
    final again = make()..select('builtin-gold');
    expect([again.current!.intimacy, again.current!.satiety, again.current!.health], [50, 50, 100]);
  });

  test('feeding and playing change the numbers and are saved', () {
    final k = make()..select('builtin-gold');
    k.interact('feed');
    k.interact('play');
    expect(k.current!.satiety, 80);
    expect(k.current!.intimacy, 52);
    expect(k.current!.todayInteractions, 2);
    expect((make()..select('builtin-gold')).current!.satiety, 80);
  });

  test('tick catches up the time that passed', () {
    final k = make()..select('builtin-gold');
    now = now.add(const Duration(hours: 6)); // satiety 50 -> 25
    k.tick();
    expect(k.current!.satiety, closeTo(25, 1e-6));
  });

  test('each pet keeps its own numbers', () {
    final k = make()..select('builtin-gold');
    k.interact('feed');
    k.select('builtin-corgi');
    expect(k.current!.satiety, 50);
    k.select('builtin-gold');
    expect(k.current!.satiety, 80);
  });

  test('a failed save does not throw', () {
    final blocker = File('${tmp.path}\\blocker')..writeAsStringSync('x'); // a file where the folder should be
    final k = StatsKeeper(StatsStore(Directory(blocker.path)), now: () => now);
    expect(() => k.select('builtin-gold'), returnsNormally);
    expect(k.current, isNotNull); // still on screen even though it was not saved
  });
}
```

- [ ] **Step 2: 运行确认失败**：两个测试文件编译失败。

- [ ] **Step 3: 实现**

`apps/aipet/lib/services/stats_store.dart`：

```dart
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/pet_stats.dart';

/// stats.json (spec 2026-09-19 E 3.3): every adopted pet's stats. Only the
/// pet window writes it, like settings.json.
class StatsStore {
  StatsStore(this.root);

  final Directory root;

  File get file => File('${root.path}${Platform.pathSeparator}stats.json');

  /// Never throws. An unreadable file is kept as stats.json.bad and treated
  /// as empty; a single bad entry is dropped.
  Map<String, PetStats> load() {
    if (!file.existsSync()) return {};
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map<String, Object?> || j['schema'] != 1 || j['pets'] is! Map<String, Object?>) {
        throw const FormatException('bad schema');
      }
      final out = <String, PetStats>{};
      for (final e in (j['pets']! as Map<String, Object?>).entries) {
        try {
          out[e.key] = PetStats.fromJson(e.value! as Map<Object?, Object?>);
        } catch (err) {
          developer.log('stats for ${e.key} dropped ($err)', name: 'aipet.stats');
        }
      }
      return out;
    } catch (e) {
      developer.log('stats.json unreadable ($e); quarantined as .bad', name: 'aipet.stats');
      try {
        final bad = File('${file.path}.bad');
        if (bad.existsSync()) bad.deleteSync();
        file.renameSync(bad.path);
      } catch (quarantineError) {
        developer.log('quarantine failed ($quarantineError)', name: 'aipet.stats');
      }
      return {};
    }
  }

  void save(Map<String, PetStats> all) {
    root.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      jsonEncode({'schema': 1, 'pets': {for (final e in all.entries) e.key: e.value.toJson()}}),
      flush: true,
    );
    tmp.renameSync(file.path); // never a half-written stats.json
  }
}
```

`apps/aipet/lib/app/pet_window/stats_keeper.dart`：

```dart
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/pet_stats.dart';
import '../../services/stats_store.dart';

/// The current pet's stats, kept up to date and saved (spec 2026-09-19 E 3.3).
class StatsKeeper extends ChangeNotifier {
  StatsKeeper(this._store, {DateTime Function()? now}) : _now = now ?? DateTime.now {
    _all = _store.load();
  }

  final StatsStore _store;
  final DateTime Function() _now;
  late final Map<String, PetStats> _all;
  String? _petId;

  PetStats? get current => _petId == null ? null : _all[_petId];

  DateTime get now => _now();

  /// Switches to [petId] -- a pet seen for the first time starts fresh -- and
  /// catches up the time since its stats were last saved.
  void select(String? petId) {
    _petId = petId;
    if (petId != null) _put(petId, advanceStats(_all[petId] ?? PetStats.fresh(_now()), _now()));
    notifyListeners();
  }

  /// Called once a minute by the pet window.
  void tick() {
    final id = _petId;
    if (id == null) return;
    _put(id, advanceStats(_all[id]!, _now()));
    notifyListeners();
  }

  /// The user picked [action] from the panel or the menu.
  void interact(String action) {
    final id = _petId;
    if (id == null) return;
    _put(id, recordInteraction(_all[id]!, _now(), fed: action == 'feed'));
    notifyListeners();
  }

  /// Best effort, like settings.json: a failed save must not undo what is on screen.
  void _put(String id, PetStats s) {
    _all[id] = s;
    try {
      _store.save(_all);
    } catch (e) {
      developer.log('stats save failed: $e', name: 'aipet.stats');
    }
  }
}
```

- [ ] **Step 4: 运行确认通过**：两个文件 4 + 6 passed；`flutter analyze` 零问题。
- [ ] **Step 5: 提交**：`git add` 四个文件；`git commit -m "feat(aipet): stats.json and the current pet's stats keeper" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 3: 走路轨迹 `Walker` 与面板定位 `hudPosition`

**Files:**
- Create: `apps/aipet/lib/domain/walker.dart`、`apps/aipet/lib/domain/hud_layout.dart`
- Test: `apps/aipet/test/domain/walker_test.dart`、`apps/aipet/test/domain/hud_layout_test.dart`

**Interfaces:**
- Produces: `enum Facing { left, right }`；`const double kWalkSpeed = 90`；`Facing roomierSide(double x, double minX, double maxX)`；
  `Walker({required double x, required double minX, required double maxX, required Facing heading, required Duration length, double speed = kWalkSpeed})`：`double get x`、`Facing get heading`、`bool get done`、`bool step(Duration dt)`；
  `const Size kHudSize = Size(440, 250)`；`Offset hudPosition(Rect pet, Size hud, Rect work)`。

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/domain/walker_test.dart`：

```dart
import 'package:aipet/domain/walker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const s1 = Duration(seconds: 1);

  test('walks at the speed toward its heading', () {
    final w = Walker(x: 100, minX: 0, maxX: 1000, heading: Facing.right, length: const Duration(seconds: 5));
    expect(w.step(s1), isTrue);
    expect(w.x, closeTo(190, 1e-9));
    expect(w.heading, Facing.right);
  });

  test('turns at the end and walks back the rest of the way', () {
    // 90 px: 50 to reach 1000, then 40 back
    final w = Walker(x: 950, minX: 0, maxX: 1000, heading: Facing.right, length: const Duration(seconds: 5));
    w.step(s1);
    expect(w.x, closeTo(960, 1e-9));
    expect(w.heading, Facing.left);
  });

  test('stops when its time is up, using only the time left', () {
    final w = Walker(x: 100, minX: 0, maxX: 1000, heading: Facing.right, length: const Duration(milliseconds: 1500));
    expect(w.step(s1), isTrue);
    expect(w.step(s1), isFalse); // only 0.5 s left: 45 px
    expect(w.x, closeTo(235, 1e-9));
    expect(w.done, isTrue);
    expect(w.step(s1), isFalse);
    expect(w.x, closeTo(235, 1e-9));
  });

  test('no room: stays put instead of spinning', () {
    final w = Walker(x: 300, minX: 300, maxX: 300, heading: Facing.left, length: const Duration(seconds: 5));
    w.step(s1);
    expect(w.x, 300);
  });

  test('starts toward the roomier side', () {
    expect(roomierSide(100, 0, 1000), Facing.right);
    expect(roomierSide(900, 0, 1000), Facing.left);
  });
}
```

`apps/aipet/test/domain/hud_layout_test.dart`：

```dart
import 'dart:ui';

import 'package:aipet/domain/hud_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const work = Rect.fromLTWH(0, 0, 1707, 1027);

  test('centred above the pet, overlapping the empty top of its window', () {
    // top 500 + 24 - 250 = 274; centre 1180 - 220 = 960
    expect(hudPosition(const Rect.fromLTWH(1000, 500, 360, 360), kHudSize, work), const Offset(960, 274));
  });

  test('flips below when there is no room above', () {
    // above would be 100 + 24 - 250 < 0 -> below: 460 + 6
    expect(hudPosition(const Rect.fromLTWH(1000, 100, 360, 360), kHudSize, work), const Offset(960, 466));
  });

  test('kept inside the work area left and right', () {
    expect(hudPosition(const Rect.fromLTWH(1500, 500, 360, 360), kHudSize, work).dx, 1707 - 440);
    expect(hudPosition(const Rect.fromLTWH(-100, 500, 360, 360), kHudSize, work).dx, 0);
  });

  test('flipped below but kept above the bottom of a short work area', () {
    expect(hudPosition(const Rect.fromLTWH(1000, 100, 360, 360), kHudSize, const Rect.fromLTWH(0, 0, 1707, 500)).dy, 250);
  });
}
```

- [ ] **Step 2: 运行确认失败**：两个文件编译失败。

- [ ] **Step 3: 实现**

`apps/aipet/lib/domain/walker.dart`：

```dart
/// Which way an animal faces or walks.
enum Facing { left, right }

/// Walking speed across the desktop, logical pixels per second (spec
/// 2026-09-19 E 3.4; tune by eye against the clips' stride at acceptance).
const double kWalkSpeed = 90;

/// A walk starts toward the side with more room.
Facing roomierSide(double x, double minX, double maxX) => (x - minX) > (maxX - x) ? Facing.left : Facing.right;

/// One walk along [minX, maxX] (the window's left edge): turns at either end.
class Walker {
  Walker({
    required double x,
    required this.minX,
    required this.maxX,
    required Facing heading,
    required Duration length,
    this.speed = kWalkSpeed,
  })  : _x = x < minX ? minX : (x > maxX ? maxX : x),
        _heading = heading,
        _left = length;

  final double minX;
  final double maxX;
  final double speed;
  double _x;
  Facing _heading;
  Duration _left;

  double get x => _x;
  Facing get heading => _heading;
  bool get done => _left <= Duration.zero;

  /// Moves for [dt] (never past the walk's time); returns false once it is over.
  bool step(Duration dt) {
    if (done) return false;
    final d = dt > _left ? _left : dt;
    _left -= d;
    if (maxX <= minX) return !done; // no room to walk: stand still
    var dist = speed * d.inMicroseconds / Duration.microsecondsPerSecond;
    while (dist > 0) {
      final room = _heading == Facing.right ? maxX - _x : _x - minX;
      if (dist <= room) {
        _x += _heading == Facing.right ? dist : -dist;
        dist = 0;
      } else {
        _x = _heading == Facing.right ? maxX : minX;
        dist -= room;
        _heading = _heading == Facing.right ? Facing.left : Facing.right;
      }
    }
    return !done;
  }
}
```

`apps/aipet/lib/domain/hud_layout.dart`：

```dart
import 'dart:math' as math;
import 'dart:ui';

/// The panel window, logical pixels (spec 2026-09-19 E 3.1).
const Size kHudSize = Size(440, 250);

/// The panel overlaps the empty top of the pet window so it sits just above
/// the head; below the window it keeps a small gap.
const double kHudOverlap = 24;
const double kHudBelowGap = 6;

/// Top-left of the panel: centred over the pet, flipped below it when it
/// would leave the work area at the top, and kept inside left and right.
Offset hudPosition(Rect pet, Size hud, Rect work) {
  var y = pet.top + kHudOverlap - hud.height;
  if (y < work.top) y = math.min(pet.bottom + kHudBelowGap, work.bottom - hud.height);
  final x = (pet.center.dx - hud.width / 2).clamp(work.left, math.max(work.left, work.right - hud.width)).toDouble();
  return Offset(x, y);
}
```

- [ ] **Step 4: 运行确认通过**：5 + 4 passed；`flutter analyze` 零问题。
- [ ] **Step 5: 提交**：`git commit -m "feat(aipet): walking path and panel placement" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`（`git add` 四个文件）

---

### Task 4: 走路朝向 `walkFacing`

**Files:**
- Modify: `apps/aipet/lib/domain/pet.dart`、`tools/petgen/petgen/package.py`、`tools/petgen/petgen/__main__.py`（`cmd_package` 一行）
- Modify: `apps/aipet/assets/pets/builtin-gold/pet.json`、`builtin-corgi/pet.json`、`builtin-ragdoll/pet.json`
- Test: `apps/aipet/test/domain/pet_test.dart`、`tools/petgen/tests/test_package.py`

**Interfaces:**
- Consumes: Task 3 的 `Facing`。
- Produces: `Pet.walkFacing: Facing`（构造参数默认 `Facing.right`）；`parsePet` 读可选字段 `walkFacing`（`left`/`right`，其他值抛 `FormatException`）；
  petgen `walk_facing(video: Path) -> str`、`pet_json(pet: str, walk_facing: str = "right") -> dict`（多一个键 `walkFacing`）。

- [ ] **Step 1: 写失败的测试**

`apps/aipet/test/domain/pet_test.dart`：在 `import 'package:aipet/domain/pet.dart';` 后加 `import 'package:aipet/domain/walker.dart';`；在 `broken` 表里加一项
`'walkFacing up': () => valid()..['walkFacing'] = 'up',`；在 `test('blurb is optional', ...)` 之后加：

```dart
  test('walkFacing is read and defaults to right', () {
    expect(parsePet(jsonEncode(valid()), dir).walkFacing, Facing.right);
    expect(parsePet(jsonEncode(valid()..['walkFacing'] = 'left'), dir).walkFacing, Facing.left);
    expect(parsePet(jsonEncode(valid()..['walkFacing'] = 'right'), dir).walkFacing, Facing.right);
  });
```

`tools/petgen/tests/test_package.py`：`test_pet_json_matches_spec_schema` 改为调用 `pet_json("ragdoll", "left")`，期望字典末尾加 `"walkFacing": "left"`；import 行改为
`from petgen.package import COVER_MAX, make_cover, pet_json, walk_facing`；文件顶部加 `import subprocess` 与 `import numpy as np`；末尾加：

```python
def test_walk_facing_finds_the_side_the_head_is_on(tmp_path):
    for head_left, want in [(True, "left"), (False, "right")]:
        f = np.zeros((24, 240, 240, 3), np.uint8)
        f[...] = (0, 255, 0)
        f[:, 120:200, 40:200] = (200, 150, 100)                      # body
        cols = slice(40, 90) if head_left else slice(150, 200)
        f[:, 60:120, cols] = (200, 150, 100)                         # head, above one end of the body
        v = tmp_path / f"walk-{want}.mp4"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "240x240",
                        "-r", "24", "-i", "-", "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", str(v)],
                       input=f.tobytes(), check=True)
        assert walk_facing(v) == want
```

（头部左：主体行 60–199、上四分之一是第 60–94 行，只有头，列中心 64.5 < 主体中线 119.5 → left；镜像后 → right。）

- [ ] **Step 2: 运行确认失败**：`flutter test test/domain/pet_test.dart`（`walkFacing` 未定义）；`pytest tests/test_package.py`（`ImportError: walk_facing`）。

- [ ] **Step 3: 实现**

`apps/aipet/lib/domain/pet.dart`：
1. 顶部 import 加 `import 'walker.dart';`。
2. `Pet` 构造加 `this.walkFacing = Facing.right,`，字段加：

```dart
  /// Which way the walk clip faces; the pet window mirrors it when walking
  /// the other way (spec 2026-09-19 E 3.4).
  final Facing walkFacing;
```

3. `parsePet` 里 `final cover = ...` 之前加：

```dart
  final facing = raw['walkFacing'];
  final walkFacing = switch (facing) {
    null || 'right' => Facing.right,
    'left' => Facing.left,
    _ => throw FormatException('walkFacing must be left or right, got $facing'),
  };
```

   并在 `return Pet(` 里加 `walkFacing: walkFacing,`。

`tools/petgen/petgen/package.py`：顶部加 `from pathlib import Path` 与 `import numpy as np`；`pet_json` 改为：

```python
def pet_json(pet: str, walk_facing: str = "right") -> dict:
    p = PETS[pet]
    return {"schema": 1, "id": f"builtin-{pet}", "name": p["name"], "species": p["species"],
            "origin": "builtin", "blurb": p["blurb"], "cover": "cover.png", "actions": list(ACTIONS),
            "walkFacing": walk_facing}


def walk_facing(video: Path) -> str:
    """'left' or 'right': the side the walking animal's head is on -- the
    upper quarter of the keyed subject is mostly head. The client mirrors the
    clip when it walks the other way (spec 2026-09-19 E 3.4)."""
    from petgen.finish import frame_rgb
    from petgen.keycheck import alpha_map
    ys, xs = np.nonzero(alpha_map(frame_rgb(video, 0)) > 128)
    upper = xs[ys < ys.min() + (ys.max() - ys.min()) * 0.25]
    return "left" if upper.mean() < (xs.min() + xs.max()) / 2 else "right"
```

`tools/petgen/petgen/__main__.py` 的 `cmd_package`：import 行加 `walk_facing`（`from petgen.package import ACTIONS, make_cover, pet_json, walk_facing`），写 pet.json 那行改为
`json.dumps(pet_json(a.pet, walk_facing(d / "walk-final.mp4")), ...)`。

三个内置 `pet.json`：在 `"actions": [...]` 之后加一行 `"walkFacing": "left"`（金毛）/ `"right"`（柯基）/ `"right"`（布偶猫）（2026-09-19 实测：金毛朝左，柯基、布偶猫朝右），保持 2 空格缩进、UTF-8、末尾换行。

- [ ] **Step 4: 运行确认通过**：`flutter test test/domain/pet_test.dart`；`flutter test`（全量不回退）；`pytest -q`（91）。
- [ ] **Step 5: 提交**：`git add` 以上文件；`git commit -m "feat: walkFacing -- which way a pet's walk clip faces" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 5: 面板通道 `aipet/hud`

**Files:**
- Create: `apps/aipet/lib/services/hud_bridge.dart`
- Test: `apps/aipet/test/services/hud_bridge_test.dart`

**Interfaces:**
- Consumes: `window_bridge.dart` 的 `BridgeTransport`、`WindowChannelTransport`；测试用 `test/support/fake_transport.dart`。
- Produces: `const kHudChannel = WindowMethodChannel('aipet/hud')`；`abstract final class HudMethods`；`const kHudButtons = ['stand', 'walk', 'feed', 'play']`；
  `class HudView`（`name, cover, status: String`，`companionDays, todayInteractions, intimacy, satiety, health: int`，`enabled: Set<String>`；`toJson` / `fromJson` / `==`）；
  `PetHudBridge(BridgeTransport, {onAction(String), onClose(), onHover(bool), timeout})`：`start()`、`Future<void> show(Rect pet, HudView)`、`update(HudView)`、`hide()`（都不抛）；
  `HudWindowBridge(BridgeTransport, {Future<void> onShow(Rect, HudView), void onUpdate(HudView), Future<void> onHide()})`：`start()`、`action(String)`、`close()`、`hover(bool)`（发出即忘）。

- [ ] **Step 1: 写失败的测试** —— `apps/aipet/test/services/hud_bridge_test.dart`：

```dart
import 'dart:ui';

import 'package:aipet/services/hud_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';

const view = HudView(
  name: '体验版：金毛',
  cover: 'C:\\pets\\builtin-gold\\cover.png',
  status: '状态很好',
  companionDays: 3,
  todayInteractions: 7,
  intimacy: 57,
  satiety: 100,
  health: 100,
  enabled: {'stand', 'walk', 'feed'},
);

void main() {
  test('HudView survives the channel', () {
    expect(HudView.fromJson(Map<Object?, Object?>.from(view.toJson())), view);
  });

  test('show / update / hide reach the panel with the pet window rectangle', () async {
    final (petEnd, panelEnd) = FakeTransport.pair();
    final got = <String>[];
    HudWindowBridge(panelEnd,
        onShow: (r, v) async => got.add('show $r ${v.name}'),
        onUpdate: (v) => got.add('update ${v.todayInteractions}'),
        onHide: () async => got.add('hide')).start();
    final pet = PetHudBridge(petEnd, onAction: (_) {}, onClose: () {}, onHover: (_) {})..start();
    await pet.show(const Rect.fromLTWH(10, 20, 360, 360), view);
    await pet.update(view);
    await pet.hide();
    expect(got, ['show ${const Rect.fromLTWH(10, 20, 360, 360)} 体验版：金毛', 'update 7', 'hide']);
  });

  test("the panel's buttons, close and hover reach the pet window", () async {
    final (petEnd, panelEnd) = FakeTransport.pair();
    final got = <String>[];
    PetHudBridge(petEnd, onAction: (k) => got.add('action $k'), onClose: () => got.add('close'), onHover: (i) => got.add('hover $i'))
        .start();
    final panel = HudWindowBridge(panelEnd, onShow: (_, _) async {}, onUpdate: (_) {}, onHide: () async {})..start();
    panel.action('feed');
    panel.close();
    panel.hover(true);
    await Future<void>.delayed(Duration.zero);
    expect(got, ['action feed', 'close', 'hover true']);
  });

  test('no panel listening: the pet window carries on', () async {
    final (petEnd, _) = FakeTransport.pair();
    final pet = PetHudBridge(petEnd, onAction: (_) {}, onClose: () {}, onHover: (_) {});
    await expectLater(pet.show(Rect.zero, view), completes);
  });

  test('a hung panel does not hold the pet window up', () async {
    final (petEnd, panelEnd) = FakeTransport.pair();
    HudWindowBridge(panelEnd, onShow: (_, _) async {}, onUpdate: (_) {}, onHide: () async {}).start();
    panelEnd.silent = true;
    final pet = PetHudBridge(petEnd,
        onAction: (_) {}, onClose: () {}, onHover: (_) {}, timeout: const Duration(milliseconds: 50));
    await expectLater(pet.hide(), completes);
  });
}
```

- [ ] **Step 2: 运行确认失败**：编译失败。

- [ ] **Step 3: 实现** —— `apps/aipet/lib/services/hud_bridge.dart`：

```dart
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

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

/// The panel's buttons, in order (spec 3.5).
const kHudButtons = ['stand', 'walk', 'feed', 'play'];

/// What the panel shows; numbers already rounded.
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
    required this.enabled,
  });

  factory HudView.fromJson(Map<Object?, Object?> j) => HudView(
        name: j['name']! as String,
        cover: j['cover']! as String,
        status: j['status']! as String,
        companionDays: j['companionDays']! as int,
        todayInteractions: j['todayInteractions']! as int,
        intimacy: j['intimacy']! as int,
        satiety: j['satiety']! as int,
        health: j['health']! as int,
        enabled: {for (final v in j['enabled']! as List<Object?>) v! as String},
      );

  final String name;
  final String cover; // absolute path of the pet's cover.png
  final String status;
  final int companionDays;
  final int todayInteractions;
  final int intimacy;
  final int satiety;
  final int health;
  final Set<String> enabled; // which of kHudButtons this pet has

  Map<String, Object?> toJson() => {
        'name': name,
        'cover': cover,
        'status': status,
        'companionDays': companionDays,
        'todayInteractions': todayInteractions,
        'intimacy': intimacy,
        'satiety': satiety,
        'health': health,
        'enabled': [for (final b in kHudButtons) if (enabled.contains(b)) b],
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
      setEquals(other.enabled, enabled);

  @override
  int get hashCode => Object.hash(name, cover, status, companionDays, todayInteractions, intimacy, satiety, health,
      Object.hashAllUnordered(enabled));
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
```

（`WindowChannelTransport` 已接受一个 `WindowMethodChannel` 参数：`WindowChannelTransport(kHudChannel)`。）

- [ ] **Step 4: 运行确认通过**：5 passed；`flutter analyze` 零问题。
- [ ] **Step 5: 提交**：`git commit -m "feat(aipet): aipet/hud channel between the pet window and the panel" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 6: 悬停状态机 `HudPresenter`

**Files:**
- Create: `apps/aipet/lib/app/pet_window/hud_presenter.dart`
- Test: `apps/aipet/test/app/hud_presenter_test.dart`

**Interfaces:**
- Produces: `HudPresenter({required void Function() show, required void Function() hide, Duration showDelay = 300ms, Duration hideDelay = 600ms})`：
  `petEnter()`、`petExit()`、`hudEnter()`、`hudExit()`、`close()`、`set busy(bool)`、`bool get shown`、`bool get pointerOnPet`、`dispose()`。

- [ ] **Step 1: 写失败的测试**（计时器用 `testWidgets` 的假时钟）—— `apps/aipet/test/app/hud_presenter_test.dart`：

```dart
import 'package:aipet/app/pet_window/hud_presenter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> log;
  late HudPresenter p;
  const ms = Duration(milliseconds: 1);
  setUp(() {
    log = [];
    p = HudPresenter(show: () => log.add('show'), hide: () => log.add('hide'));
  });
  tearDown(() => p.dispose());

  testWidgets('hovering the pet shows the panel after 300 ms', (t) async {
    p.petEnter();
    await t.pump(ms * 299);
    expect(log, isEmpty);
    await t.pump(ms);
    expect(log, ['show']);
    expect(p.shown, isTrue);
  });

  testWidgets('a quick pass never shows it', (t) async {
    p.petEnter();
    await t.pump(ms * 200);
    p.petExit();
    await t.pump(const Duration(seconds: 1));
    expect(log, isEmpty);
  });

  testWidgets('leaving hides after 600 ms unless the pointer reaches the panel', (t) async {
    p.petEnter();
    await t.pump(ms * 300);
    p.petExit();
    await t.pump(ms * 400);
    p.hudEnter();
    await t.pump(const Duration(seconds: 1));
    expect(log, ['show']);
    p.hudExit();
    await t.pump(ms * 599);
    expect(log, ['show']);
    await t.pump(ms);
    expect(log, ['show', 'hide']);
  });

  testWidgets('x hides at once and keeps it hidden until the pointer leaves the pet', (t) async {
    p.petEnter();
    await t.pump(ms * 300);
    p.hudEnter();
    p.close();
    expect(log, ['show', 'hide']);
    p.hudExit(); // still over the pet
    await t.pump(const Duration(seconds: 1));
    expect(log, ['show', 'hide']);
    p.petExit();
    p.petEnter();
    await t.pump(ms * 300);
    expect(log, ['show', 'hide', 'show']);
  });

  testWidgets('busy hides at once and blocks it; idle again while hovering shows it', (t) async {
    p.petEnter();
    await t.pump(ms * 300);
    p.busy = true;
    expect(log, ['show', 'hide']);
    await t.pump(const Duration(seconds: 1));
    expect(log, ['show', 'hide']);
    p.busy = false;
    await t.pump(ms * 300);
    expect(log, ['show', 'hide', 'show']);
  });
}
```

- [ ] **Step 2: 运行确认失败**：编译失败。

- [ ] **Step 3: 实现** —— `apps/aipet/lib/app/pet_window/hud_presenter.dart`：

```dart
import 'dart:async';

/// When the panel is up (spec 2026-09-19 E 3.2): 300 ms over the pet shows
/// it, 600 ms off both the pet and the panel hides it, x hides it until the
/// pointer has left the pet, and walking or dragging (busy) hides it at once.
class HudPresenter {
  HudPresenter({
    required this.show,
    required this.hide,
    this.showDelay = const Duration(milliseconds: 300),
    this.hideDelay = const Duration(milliseconds: 600),
  });

  final void Function() show;
  final void Function() hide;
  final Duration showDelay;
  final Duration hideDelay;

  bool _inPet = false;
  bool _inHud = false;
  bool _dismissed = false;
  bool _busy = false;
  bool _shown = false;
  Timer? _pending;

  bool get shown => _shown;
  bool get pointerOnPet => _inPet;

  void petEnter() {
    _inPet = true;
    _reconsider();
  }

  void petExit() {
    _inPet = false;
    _dismissed = false;
    _reconsider();
  }

  void hudEnter() {
    _inHud = true;
    _reconsider();
  }

  void hudExit() {
    _inHud = false;
    if (!_inPet) _dismissed = false;
    _reconsider();
  }

  void close() {
    _dismissed = true;
    _reconsider();
  }

  set busy(bool v) {
    if (v == _busy) return;
    _busy = v;
    _reconsider();
  }

  void _reconsider() {
    _pending?.cancel();
    _pending = null;
    final want = !_busy && !_dismissed && (_inPet || (_shown && _inHud));
    if (want && !_shown) {
      _pending = Timer(showDelay, () {
        _pending = null;
        _shown = true;
        show();
      });
    } else if (!want && _shown) {
      if (_busy || _dismissed) {
        _shown = false;
        hide();
      } else {
        _pending = Timer(hideDelay, () {
          _pending = null;
          _shown = false;
          hide();
        });
      }
    }
  }

  void dispose() {
    _pending?.cancel();
    _pending = null;
  }
}
```

- [ ] **Step 4: 运行确认通过**：5 passed；`flutter analyze` 零问题。
- [ ] **Step 5: 提交**：`git commit -m "feat(aipet): hover logic for the status panel" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 7: 不抢焦点的窗口操作（FFI）、显示器可用区域、`WindowMover`

**Files:**
- Modify: `apps/aipet/pubspec.yaml`（依赖加 `screen_retriever: ^0.2.2`、`ffi: ^2.2.0`）
- Create: `apps/aipet/lib/services/native_window.dart`、`apps/aipet/lib/services/displays.dart`、`apps/aipet/lib/app/pet_window/window_mover.dart`

**Interfaces:**
- Produces: `NativeWindow.find(String title) -> NativeWindow?`（本进程、指定标题的顶层窗口）、`moveTo(int x, int y)`、`showAt(int x, int y)`（物理像素，不激活）；
  `Future<Rect?> displayWorkArea(Rect window)`（逻辑像素）；`abstract class WindowMover { Future<Rect> bounds(); Future<Rect?> workArea(Rect window); void moveTo(Offset topLeft); }`；
  `DesktopWindowMover(NativeWindow? native) implements WindowMover`；`double physicalScale()`。

平台胶水代码，没有可在单测里验证的逻辑（要真实桌面）——本任务**不写单测**，靠 `flutter analyze`、后续任务的假实现与真机验收（TDD 的平台胶水例外，已在计划中说明）。

- [ ] **Step 1: 依赖**

`pubspec.yaml` 的 `dependencies:` 里 `crypto: ^3.0.7` 之后加：

```yaml
  screen_retriever: ^0.2.2
  ffi: ^2.2.0
```

运行 `flutter pub get`（两者都已在本机 pub 缓存；失败再加 `--offline`）。

- [ ] **Step 2: `apps/aipet/lib/services/native_window.dart`**

```dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// A top-level window of this process, moved and shown WITHOUT taking focus.
/// window_manager on Windows cannot: show() always calls SetForegroundWindow
/// and setPosition() is SetWindowPos(HWND_TOP) without SWP_NOACTIVATE, which
/// would steal the user's focus on every walking frame and every hover
/// (spec 2026-09-19 E 3.1). Coordinates are physical pixels.
class NativeWindow {
  NativeWindow._(this._hwnd);

  final int _hwnd;

  /// This process's top-level window titled [title], or null.
  static NativeWindow? find(String title) {
    if (!Platform.isWindows) return null;
    final text = title.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      var h = _findWindowEx(0, 0, nullptr, text);
      while (h != 0) {
        _getWindowThreadProcessId(h, pid);
        if (pid.value == _getCurrentProcessId()) return NativeWindow._(h);
        h = _findWindowEx(0, h, nullptr, text);
      }
      return null;
    } finally {
      calloc.free(text);
      calloc.free(pid);
    }
  }

  /// Moves the window; no activation, no z-order change.
  void moveTo(int x, int y) => _setWindowPos(_hwnd, 0, x, y, 0, 0, _swpNoSize | _swpNoZOrder | _swpNoActivate);

  /// Shows the window at (x, y), topmost, without activating it.
  void showAt(int x, int y) =>
      _setWindowPos(_hwnd, _hwndTopmost, x, y, 0, 0, _swpNoSize | _swpNoActivate | _swpShowWindow);
}

final _user32 = DynamicLibrary.open('user32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');

final _findWindowEx = _user32.lookupFunction<IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
    int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)>('FindWindowExW');
final _getWindowThreadProcessId = _user32
    .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _getCurrentProcessId = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
final _setWindowPos = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int)>('SetWindowPos');

const _hwndTopmost = -1;
const _swpNoSize = 0x0001;
const _swpNoZOrder = 0x0004;
const _swpNoActivate = 0x0010;
const _swpShowWindow = 0x0040;
```

- [ ] **Step 3: `apps/aipet/lib/services/displays.dart`**

```dart
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

/// Physical pixels per logical pixel of this engine's window (what
/// window_manager itself multiplies by).
double physicalScale() => PlatformDispatcher.instance.views.first.devicePixelRatio;

/// The work area (logical pixels, taskbar excluded) of the display holding
/// [window]'s centre; the primary display's if none does; null if unknown.
Future<Rect?> displayWorkArea(Rect window) async {
  try {
    Rect area(Display d) => (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);
    for (final d in await screenRetriever.getAllDisplays()) {
      if (area(d).contains(window.center)) return area(d);
    }
    return area(await screenRetriever.getPrimaryDisplay());
  } catch (_) {
    return null;
  }
}
```

- [ ] **Step 4: `apps/aipet/lib/app/pet_window/window_mover.dart`**

```dart
import 'dart:ui';

import 'package:window_manager/window_manager.dart';

import '../../services/displays.dart';
import '../../services/native_window.dart';

/// Where the pet window is and how to move it; faked in tests.
abstract class WindowMover {
  /// The window, logical pixels.
  Future<Rect> bounds();

  /// Work area of the display holding [window], logical pixels; null if unknown.
  Future<Rect?> workArea(Rect window);

  /// Moves the window's top-left to [topLeft] (logical) without taking focus.
  void moveTo(Offset topLeft);
}

class DesktopWindowMover implements WindowMover {
  DesktopWindowMover(this._native);

  final NativeWindow? _native;

  @override
  Future<Rect> bounds() => windowManager.getBounds();

  @override
  Future<Rect?> workArea(Rect window) => displayWorkArea(window);

  @override
  void moveTo(Offset topLeft) {
    final s = physicalScale();
    _native?.moveTo((topLeft.dx * s).round(), (topLeft.dy * s).round());
  }
}
```

- [ ] **Step 5: 检查与提交**：`flutter analyze` 零问题；`flutter test` 全过。`git add apps/aipet/pubspec.yaml apps/aipet/pubspec.lock apps/aipet/lib/services/native_window.dart apps/aipet/lib/services/displays.dart apps/aipet/lib/app/pet_window/window_mover.dart`；
  `git commit -m "feat(aipet): move and show windows without taking focus (FFI SetWindowPos NOACTIVATE)" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 8: 一次走路 `WalkDriver`

**Files:**
- Create: `apps/aipet/lib/app/pet_window/walk_driver.dart`、`apps/aipet/test/support/fake_mover.dart`
- Test: `apps/aipet/test/app/walk_driver_test.dart`

**Interfaces:**
- Consumes: Task 3 `Walker`、`roomierSide`、`Facing`、`kWalkSpeed`；Task 7 `WindowMover`。
- Produces: `WalkDriver(WindowMover mover, {required Facing Function() facing, DateTime Function()? clock, Duration frame = 33ms, double speed = kWalkSpeed}) extends ChangeNotifier`：
  `bool get walking`、`bool get mirrored`、`Future<bool> walk(Duration length)`（时间走完 true；没开始或被停 false）、`void stop()`、`dispose()`。

- [ ] **Step 1: 写失败的测试** —— 假的移窗器（Task 9 也用）`apps/aipet/test/support/fake_mover.dart`：

```dart
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
```

`apps/aipet/test/app/walk_driver_test.dart`：

```dart
import 'package:aipet/app/pet_window/walk_driver.dart';
import 'package:aipet/domain/walker.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_mover.dart';

void main() {
  const frame = Duration(milliseconds: 33);
  late DateTime now;
  late FakeMover mover;
  late WalkDriver d;
  var facing = Facing.left;

  Future<void> run(WidgetTester t, Duration span) async {
    final end = now.add(span);
    while (now.isBefore(end)) {
      now = now.add(frame);
      await t.pump(frame);
    }
  }

  setUp(() {
    now = DateTime(2026, 9, 19);
    mover = FakeMover();
    facing = Facing.left;
    d = WalkDriver(mover, facing: () => facing, clock: () => now, frame: frame);
  });
  tearDown(() => d.dispose());

  testWidgets('walks toward the roomier side at the walking speed, mirrored when facing the other way', (t) async {
    final done = d.walk(const Duration(seconds: 2));
    await t.pump();
    expect(d.walking, isTrue);
    expect(d.mirrored, isTrue); // heading right, clip faces left
    await run(t, const Duration(seconds: 1)); // 31 frames of 33 ms = 1.023 s -> ~92 px
    expect(mover.moves.last.dx, closeTo(192, 3));
    expect(mover.moves.last.dy, 500);
    await run(t, const Duration(seconds: 2));
    expect(await done, isTrue);
    expect(d.walking, isFalse);
  });

  testWidgets('turns at the edge of the work area', (t) async {
    mover.work = const Rect.fromLTWH(0, 0, 500, 1027); // maxX 140; from 100: left has more room
    facing = Facing.right;
    final done = d.walk(const Duration(seconds: 3));
    await t.pump();
    expect(d.mirrored, isTrue); // heading left
    await run(t, const Duration(milliseconds: 1500)); // 46 frames = 1.518 s -> 136.6 px: 100 to 0, then 36.6 back
    expect(mover.moves.map((m) => m.dx).reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(3)); // within a frame of 0
    expect(mover.moves.last.dx, closeTo(36.6, 3));
    expect(d.mirrored, isFalse); // heading right now
    d.stop();
    expect(await done, isFalse);
  });

  testWidgets('stop ends it early; no more moves', (t) async {
    final done = d.walk(const Duration(seconds: 5));
    await run(t, const Duration(milliseconds: 500));
    d.stop();
    expect(await done, isFalse);
    final n = mover.moves.length;
    await run(t, const Duration(seconds: 1));
    expect(mover.moves, hasLength(n));
    expect(d.walking, isFalse);
  });

  testWidgets('no work area: does not start', (t) async {
    mover.work = null;
    expect(await d.walk(const Duration(seconds: 5)), isFalse);
    expect(mover.moves, isEmpty);
    expect(d.walking, isFalse);
  });

  testWidgets('a new walk ends the previous one', (t) async {
    final first = d.walk(const Duration(seconds: 5));
    await run(t, const Duration(milliseconds: 200));
    final second = d.walk(const Duration(seconds: 1));
    expect(await first, isFalse);
    await run(t, const Duration(milliseconds: 1200));
    expect(await second, isTrue);
  });
}
```

- [ ] **Step 2: 运行确认失败**：编译失败。

- [ ] **Step 3: 实现** —— `apps/aipet/lib/app/pet_window/walk_driver.dart`：

```dart
import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../domain/walker.dart';
import 'window_mover.dart';

/// One walk across the desktop (spec 2026-09-19 E 3.4): the window follows a
/// Walker about 30 times a second at its current height. [mirrored] tells the
/// view to flip the walk clip when it walks against the clip's facing.
class WalkDriver extends ChangeNotifier {
  WalkDriver(
    this._mover, {
    required this.facing,
    DateTime Function()? clock,
    this.frame = const Duration(milliseconds: 33),
    this.speed = kWalkSpeed,
  }) : _clock = clock ?? DateTime.now;

  final WindowMover _mover;

  /// The current pet's walk clip facing (pet.json walkFacing).
  final Facing Function() facing;
  final DateTime Function() _clock;
  final Duration frame;
  final double speed;

  Walker? _walker;
  Timer? _timer;
  Completer<bool>? _done;
  int _gen = 0;

  bool get walking => _walker != null;

  bool get mirrored {
    final w = _walker;
    return w != null && w.heading != facing();
  }

  /// Walks for [length]. Completes true when the time is up; false when it
  /// could not start (no work area) or was stopped / replaced.
  Future<bool> walk(Duration length) async {
    stop();
    final gen = ++_gen;
    final b = await _mover.bounds();
    final work = await _mover.workArea(b);
    if (gen != _gen || work == null) return false;
    final minX = work.left;
    final maxX = work.right - b.width;
    final w = Walker(
        x: b.left, minX: minX, maxX: maxX, heading: roomierSide(b.left, minX, maxX), length: length, speed: speed);
    _walker = w;
    final done = _done = Completer<bool>();
    var last = _clock();
    var heading = w.heading;
    notifyListeners();
    _timer = Timer.periodic(frame, (_) {
      final now = _clock();
      final more = w.step(now.difference(last));
      last = now;
      _mover.moveTo(Offset(w.x, b.top));
      if (w.heading != heading) {
        heading = w.heading;
        notifyListeners();
      }
      if (!more) _finish(true);
    });
    return done.future;
  }

  void stop() {
    _gen++;
    _finish(false);
  }

  void _finish(bool completed) {
    _timer?.cancel();
    _timer = null;
    if (_walker == null) return;
    _walker = null;
    final d = _done;
    _done = null;
    notifyListeners();
    d?.complete(completed);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
```

- [ ] **Step 4: 运行确认通过**：5 passed；`flutter analyze` 零问题。
- [ ] **Step 5: 提交**：`git commit -m "feat(aipet): walk the pet window across the screen" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 9: 调度 `Companion`

**Files:**
- Create: `apps/aipet/lib/app/pet_window/companion.dart`
- Test: `apps/aipet/test/app/companion_test.dart`

**Interfaces:**
- Consumes: `PetWindowController`（`currentPet`、`currentAction`、`state`、`playAction`、`addListener`）；Task 2 `StatsKeeper`；Task 5 `PetHudBridge`、`HudView`、`kHudButtons`；Task 6 `HudPresenter`；Task 7 `WindowMover`；Task 8 `WalkDriver`；Task 1 `statusText`、`companionDays`。
- Produces: `Companion({required PetWindowController pets, required StatsKeeper stats, required WalkDriver walker, required WindowMover mover, required BridgeTransport hudTransport, Random? random, Duration userWalk = 20 s})`：
  `HudView? get view`、`Future<void> userAction(String key)`、`petEnter()`、`petExit()`、`dragStarted()`、`dragEnded()`、`Future<void> shutdown()`（停走、收面板）、`dispose()`；`late final HudPresenter presenter`；`late final PetHudBridge hud`。

- [ ] **Step 1: 写失败的测试**

先把 `apps/aipet/test/app/pet_window_controller_test.dart` 里的 `class FakePlayer`（连同它用到的 import：`dart:async`、`dart:io`、`pet_window_controller.dart`、`package:flutter/foundation.dart`）
原样移到新文件 `apps/aipet/test/support/fake_player.dart`，原测试文件改为 `import '../support/fake_player.dart';`（行为不变，跑一遍该文件确认仍全过）。

`apps/aipet/test/app/companion_test.dart`：

```dart
import 'dart:io';
import 'dart:math';

import 'package:aipet/app/pet_window/companion.dart';
import 'package:aipet/app/pet_window/pet_window_controller.dart';
import 'package:aipet/app/pet_window/stats_keeper.dart';
import 'package:aipet/app/pet_window/walk_driver.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/walker.dart';
import 'package:aipet/services/hud_bridge.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:aipet/services/settings_store.dart';
import 'package:aipet/services/stats_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_mover.dart';
import '../support/fake_player.dart';
import '../support/fake_transport.dart';
import '../support/pet_fixtures.dart';

/// Always the shortest idle (3 min) and the shortest roam (8 s).
class LowRandom implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

const kSeven = ['stand', 'walk', 'sleep', 'feed', 'play', 'lick_paw', 'act_cute'];

void main() {
  const frame = Duration(milliseconds: 33);
  late Directory tmp;
  late DateTime now;
  late FakePlayer player;
  late FakeMover mover;
  late PetWindowController pets;
  late StatsKeeper stats;
  late WalkDriver walker;
  late Companion c;
  late List<String> panel;

  Future<void> run(WidgetTester t, Duration span) async {
    final end = now.add(span);
    while (now.isBefore(end)) {
      now = now.add(frame);
      await t.pump(frame);
    }
  }

  Future<void> boot() async {
    tmp = Directory.systemTemp.createTempSync('companion_');
    final builtin = Directory('${tmp.path}\\builtin')..createSync();
    writePet(builtin, id: 'builtin-gold', name: '金毛', actions: kSeven);
    final appData = Directory('${tmp.path}\\appdata');
    SettingsStore(appData).save(const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']));
    now = DateTime(2026, 9, 19, 9);
    player = FakePlayer();
    mover = FakeMover();
    pets = PetWindowController(
      library: PetLibrary(builtinRoot: builtin, customRoot: Directory('${tmp.path}\\custom')),
      settings: SettingsStore(appData),
      ensure: (f) async => f,
      player: player,
      push: (_) async {},
    );
    stats = StatsKeeper(StatsStore(appData), now: () => now);
    walker = WalkDriver(mover, facing: () => Facing.left, clock: () => now, frame: frame);
    final (petEnd, panelEnd) = FakeTransport.pair();
    panel = [];
    HudWindowBridge(panelEnd,
        onShow: (r, v) async => panel.add('show $r ${v.name} ${v.todayInteractions}'),
        onUpdate: (v) => panel.add('update ${v.todayInteractions}'),
        onHide: () async => panel.add('hide')).start();
    c = Companion(pets: pets, stats: stats, walker: walker, mover: mover, hudTransport: petEnd, random: LowRandom());
    await pets.boot();
  }

  void finish() {
    c.dispose();
    walker.dispose();
    tmp.deleteSync(recursive: true);
  }

  testWidgets('the panel shows the pet, its numbers and the buttons it has', (t) async {
    await boot();
    final v = c.view!;
    expect(v.name, '金毛');
    expect([v.intimacy, v.satiety, v.health, v.companionDays, v.todayInteractions], [50, 50, 100, 1, 0]);
    expect(v.status, '状态很好'); // satiety 50 is not below 50
    expect(v.enabled, {'stand', 'walk', 'feed', 'play'});
    finish();
  });

  testWidgets('a button plays the action and counts an interaction; feeding fills the bowl', (t) async {
    await boot();
    await c.userAction('feed');
    expect(player.plays.last, 'builtin-gold/feed.mp4|once');
    expect(stats.current!.satiety, 80);
    expect(stats.current!.todayInteractions, 1);
    finish();
  });

  testWidgets('walk moves the window for 20 s and ends on stand', (t) async {
    await boot();
    final done = c.userAction('walk');
    await run(t, const Duration(seconds: 21));
    await done;
    expect(mover.moves, isNotEmpty);
    expect(player.plays, containsAllInOrder(['builtin-gold/walk.mp4|loop', 'builtin-gold/stand.mp4|loop']));
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    expect(walker.walking, isFalse);
    finish();
  });

  testWidgets('another action mid-walk stops the walk and does not snap back to stand', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 2));
    await c.userAction('lick_paw');
    await walking;
    await run(t, const Duration(seconds: 1));
    expect(player.plays.last, 'builtin-gold/lick_paw.mp4|once');
    expect(walker.walking, isFalse);
    finish();
  });

  testWidgets('dragging stops a walk and returns to stand', (t) async {
    await boot();
    final walking = c.userAction('walk');
    await run(t, const Duration(seconds: 1));
    c.dragStarted();
    await walking;
    await t.pump();
    expect(walker.walking, isFalse);
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    c.dragEnded();
    finish();
  });

  testWidgets('hovering shows the panel over the pet window; a change updates it', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(milliseconds: 300));
    expect(panel, ['show ${mover.rect} 金毛 0']);
    await c.userAction('play');
    await t.pump();
    expect(panel.last, 'update 1');
    c.petExit();
    await t.pump(const Duration(milliseconds: 600));
    expect(panel.last, 'hide');
    finish();
  });

  testWidgets('after 3 idle minutes it roams by itself for 8 s, without counting an interaction', (t) async {
    await boot();
    await t.pump(const Duration(minutes: 3)); // the walk clock (now) is left alone: the roam starts from here
    expect(player.plays.last, 'builtin-gold/walk.mp4|loop');
    await run(t, const Duration(seconds: 9));
    expect(player.plays.last, 'builtin-gold/stand.mp4|loop');
    expect(stats.current!.todayInteractions, 0);
    finish();
  });

  testWidgets('no roaming while the pointer is on the pet', (t) async {
    await boot();
    c.petEnter();
    await t.pump(const Duration(minutes: 3));
    expect(player.plays.where((p) => p.contains('walk')), isEmpty);
    c.petExit();
    finish();
  });
}
```

- [ ] **Step 2: 运行确认失败**：编译失败（`companion.dart` 不存在）。

- [ ] **Step 3: 实现** —— `apps/aipet/lib/app/pet_window/companion.dart`：

```dart
import 'dart:async';
import 'dart:math';

import '../../domain/pet_stats.dart';
import '../../services/hud_bridge.dart';
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
    Random? random,
    this.userWalk = const Duration(seconds: 20),
  }) : _random = random ?? Random() {
    presenter = HudPresenter(show: () => unawaited(_showHud()), hide: () => unawaited(hud.hide()));
    hud = PetHudBridge(
      hudTransport,
      onAction: (k) => unawaited(userAction(k)),
      onClose: presenter.close,
      onHover: (inside) => inside ? presenter.hudEnter() : presenter.hudExit(),
    )..start();
    pets.addListener(_petsChanged);
    stats.addListener(_pushView);
  }

  final PetWindowController pets;
  final StatsKeeper stats;
  final WalkDriver walker;
  final WindowMover mover;
  final Duration userWalk;
  final Random _random;
  late final HudPresenter presenter;
  late final PetHudBridge hud;

  Timer? _roam;
  int _walkGen = 0;
  bool _dragging = false;
  String? _petId;

  /// The panel's content; null with nobody on the desktop.
  HudView? get view {
    final pet = pets.currentPet;
    final s = stats.current;
    if (pet == null || s == null) return null;
    return HudView(
      name: pet.name,
      cover: pet.coverFile.path,
      status: statusText(s),
      companionDays: companionDays(s, stats.now),
      todayInteractions: s.todayInteractions,
      intimacy: s.intimacy.round(),
      satiety: s.satiety.round(),
      health: s.health.round(),
      enabled: {for (final b in kHudButtons) if (pet.actions.contains(b)) b},
    );
  }

  /// A button in the panel or an item in the right-click menu: counts as an
  /// interaction; 'walk' walks across the screen, anything else plays.
  Future<void> userAction(String key) async {
    final pet = pets.currentPet;
    if (pet == null || !pet.actions.contains(key)) return;
    stats.interact(key);
    if (key == 'walk') return _walk(userWalk);
    _walkGen++;
    walker.stop();
    await pets.playAction(key);
  }

  Future<void> _walk(Duration length) async {
    final gen = ++_walkGen;
    presenter.busy = true;
    await pets.playAction('walk');
    if (gen == _walkGen && pets.currentAction == 'walk') await walker.walk(length);
    presenter.busy = _dragging;
    if (gen == _walkGen && pets.currentAction == 'walk') await pets.playAction('stand');
  }

  void petEnter() => presenter.petEnter();

  void petExit() => presenter.petExit();

  void dragStarted() {
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

  /// Quitting: stop walking and take the panel off the screen.
  Future<void> shutdown() async {
    _walkGen++;
    walker.stop();
    _roam?.cancel();
    await hud.hide();
  }

  void _petsChanged() {
    final id = pets.currentPet?.id;
    if (id != _petId) {
      _petId = id;
      stats.select(id);
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
    final v = view;
    if (v == null) return;
    await hud.show(await mover.bounds(), v);
  }

  void _pushView() {
    final v = view;
    if (presenter.shown && v != null) unawaited(hud.update(v));
  }

  void dispose() {
    _roam?.cancel();
    presenter.dispose();
    pets.removeListener(_petsChanged);
    stats.removeListener(_pushView);
  }
}
```

- [ ] **Step 4: 运行确认通过**：8 passed；`flutter test` 全量；`flutter analyze` 零问题。
- [ ] **Step 5: 提交**（含 `test/support/fake_player.dart` 与改过 import 的 `pet_window_controller_test.dart`）：`git commit -m "feat(aipet): companion -- panel actions, walking, roaming and the panel's view" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 10: 面板窗口（界面、入口、分派）

**Files:**
- Create: `apps/aipet/lib/app/hud_window/hud_panel.dart`、`apps/aipet/lib/app/hud_window/hud_window_entry.dart`
- Modify: `apps/aipet/lib/main.dart`
- Test: `apps/aipet/test/app/hud_panel_test.dart`

**Interfaces:**
- Consumes: Task 3 `kHudSize`、`hudPosition`；Task 5 `HudView`、`HudWindowBridge`、`kHudChannel`、`kHudButtons`；Task 7 `NativeWindow`、`displayWorkArea`、`physicalScale`。
- Produces: `HudPanel({required HudView view, required void Function(String) onAction, required VoidCallback onClose})`（按钮键 `Key('hud-button-<key>')`、关闭 `Key('hud-close')`）；
  `const kHudWindowArgs = 'hud_window'`、`const kHudTitle = 'aipet hud'`、`Future<void> runHudWindow()`。

- [ ] **Step 1: 写失败的测试** —— `apps/aipet/test/app/hud_panel_test.dart`：

```dart
import 'package:aipet/app/hud_window/hud_panel.dart';
import 'package:aipet/services/hud_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const view = HudView(
  name: '体验版：金毛',
  cover: 'Z:\\missing\\cover.png',
  status: '状态很好',
  companionDays: 3,
  todayInteractions: 7,
  intimacy: 57,
  satiety: 100,
  health: 100,
  enabled: {'stand', 'walk', 'feed'},
);

void main() {
  late List<String> got;
  Future<void> pump(WidgetTester t) async {
    got = [];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Center(
                child: HudPanel(view: view, onAction: (k) => got.add(k), onClose: () => got.add('close'))))));
  }

  testWidgets('shows the name, status, days, today and the three numbers', (t) async {
    await pump(t);
    for (final s in ['体验版：金毛', '状态很好', '陪伴 3 天', '今日互动 7 次', '亲密度', '饱食度', '健康度', '57%', '100%']) {
      expect(find.textContaining(s), findsWidgets, reason: s);
    }
  });

  testWidgets('a button sends its action; a missing action is disabled', (t) async {
    await pump(t);
    await t.tap(find.byKey(const Key('hud-button-feed')));
    await t.tap(find.byKey(const Key('hud-button-play')));
    await t.tap(find.byKey(const Key('hud-close')));
    expect(got, ['feed', 'close']);
  });

  testWidgets('labels read 站立 / 行走 / 喂食 / 玩耍', (t) async {
    await pump(t);
    for (final s in ['站立', '行走', '喂食', '玩耍']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
  });
}
```

- [ ] **Step 2: 运行确认失败**：编译失败。

- [ ] **Step 3: 实现**

`apps/aipet/lib/app/hud_window/hud_panel.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/hud_layout.dart';
import '../../services/hud_bridge.dart';

/// The status panel (spec 2026-09-19 E 3.5), after the competitor's: name and
/// status, companion days and today's count, three numbers, four buttons.
class HudPanel extends StatelessWidget {
  const HudPanel({super.key, required this.view, required this.onAction, required this.onClose});

  final HudView view;
  final void Function(String key) onAction;
  final VoidCallback onClose;

  static const _labels = {'stand': '站立', 'walk': '行走', 'feed': '喂食', 'play': '玩耍'};
  static const _icons = {
    'stand': Icons.pets,
    'walk': Icons.directions_walk,
    'feed': Icons.rice_bowl,
    'play': Icons.sports_baseball,
  };
  static const _ink = Color(0xFF3D2B2B);
  static const _rose = Color(0xFFB2566B);
  static const _card = Color(0xFFFBEDEC);

  @override
  Widget build(BuildContext context) => Container(
        width: kHudSize.width,
        height: kHudSize.height,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7F5),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFFF1D8D4)),
        ),
        child: Column(children: [
          Row(children: [
            _avatar(),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(view.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _ink)),
                Text(view.status, style: const TextStyle(fontSize: 12, color: _rose)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Text('陪伴 ${view.companionDays} 天', style: const TextStyle(fontSize: 12, color: _ink)),
                Text('今日互动 ${view.todayInteractions} 次', style: const TextStyle(fontSize: 11, color: _ink)),
              ]),
            ),
            IconButton(
              key: const Key('hud-close'),
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20, color: _ink),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _stat('亲密度', view.intimacy, const Color(0xFFF06292)),
            const SizedBox(width: 8),
            _stat('饱食度', view.satiety, const Color(0xFFFFA726)),
            const SizedBox(width: 8),
            _stat('健康度', view.health, const Color(0xFF66BB6A)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            for (final (i, b) in kHudButtons.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              _button(b),
            ],
          ]),
        ]),
      );

  Widget _avatar() => ClipOval(
        child: Container(
          width: 44,
          height: 44,
          color: _card,
          child: Image.file(File(view.cover),
              fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.pets, color: _rose)),
        ),
      );

  Widget _stat(String label, int value, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(label, style: const TextStyle(fontSize: 12, color: _ink)),
              const Spacer(),
              Text('$value%', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: value / 100, minHeight: 5, color: color, backgroundColor: color.withValues(alpha: 0.18)),
            ),
          ]),
        ),
      );

  Widget _button(String key) {
    final enabled = view.enabled.contains(key);
    return Expanded(
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: Key('hud-button-$key'),
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? () => onAction(key) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                Icon(_icons[key], size: 22, color: _rose),
                const SizedBox(height: 2),
                Text(_labels[key]!, style: const TextStyle(fontSize: 13, color: _ink)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
```

`apps/aipet/lib/app/hud_window/hud_window_entry.dart`：

```dart
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/hud_layout.dart';
import '../../services/displays.dart';
import '../../services/hud_bridge.dart';
import '../../services/native_window.dart';
import '../../services/window_bridge.dart';
import 'hud_panel.dart';

/// Arguments string that makes an engine the status panel.
const kHudWindowArgs = 'hud_window';
const kHudTitle = 'aipet hud';

/// The panel engine (spec 2026-09-19 E 3.1): created hidden by the pet
/// window, shown next to it WITHOUT taking focus (NativeWindow, never
/// windowManager.show), hidden again on request.
Future<void> runHudWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: kHudSize,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      title: kHudTitle,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setHasShadow(false);
      await windowManager.setResizable(false);
    },
  );
  final view = ValueNotifier<HudView?>(null);
  NativeWindow? native;
  final bridge = HudWindowBridge(
    WindowChannelTransport(kHudChannel),
    onShow: (pet, v) async {
      view.value = v;
      native ??= NativeWindow.find(kHudTitle);
      final work = await displayWorkArea(pet) ?? pet.inflate(kHudSize.longestSide);
      final p = hudPosition(pet, kHudSize, work);
      final s = physicalScale();
      native?.showAt((p.dx * s).round(), (p.dy * s).round());
    },
    onUpdate: (v) => view.value = v,
    onHide: () => windowManager.hide(),
  )..start();
  runApp(HudApp(view: view, bridge: bridge));
}

class HudApp extends StatelessWidget {
  const HudApp({super.key, required this.view, required this.bridge});

  final ValueNotifier<HudView?> view;
  final HudWindowBridge bridge;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: MouseRegion(
            onEnter: (_) => bridge.hover(true),
            onExit: (_) => bridge.hover(false),
            child: ValueListenableBuilder<HudView?>(
              valueListenable: view,
              builder: (_, v, _) => v == null
                  ? const SizedBox.shrink()
                  : HudPanel(view: v, onAction: bridge.action, onClose: bridge.close),
            ),
          ),
        ),
      );
}
```

`apps/aipet/lib/main.dart`：import 加 `import 'app/hud_window/hud_window_entry.dart';`，分派改为：

```dart
  final self = await WindowController.fromCurrentEngine();
  switch (self.arguments) {
    case kMainWindowArgs:
      await runMainWindow();
    case kHudWindowArgs:
      await runHudWindow();
    default:
      await runPetWindow();
  }
```

（注释改为 “One process, three engines: the primary engine is the pet window; kMainWindowArgs is the library, kHudWindowArgs the status panel.”）

- [ ] **Step 4: 运行确认通过**：`flutter test test/app/hud_panel_test.dart` 3 passed（若 440×250 在测试默认 800×600 画布里溢出报错，检查字体大小 / 间距，不改尺寸常量）；`flutter test` 全量；`flutter analyze` 零问题。
- [ ] **Step 5: 提交**：`git commit -m "feat(aipet): the status panel window" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 11: 宠物窗接线

**Files:**
- Modify: `apps/aipet/lib/app/pet_window/pet_window_app.dart`

**Interfaces:**
- Consumes: Task 2、7、8、9、10。

无新单测（接线；靠 `flutter analyze`、全量测试不回退、真机验收）。

- [ ] **Step 1: `runPetWindow` 接线**：
  1. import 加：`dart:async` 已有；加 `package:desktop_multi_window/desktop_multi_window.dart`、`../../domain/walker.dart`、`../../services/hud_bridge.dart`、`../../services/native_window.dart`、`../../services/stats_store.dart`、`../hud_window/hud_window_entry.dart`、`companion.dart`、`stats_keeper.dart`、`walk_driver.dart`、`window_mover.dart`。
  2. `controller` 构造之后加：

```dart
  final mover = DesktopWindowMover(NativeWindow.find('aipet pet'));
  final stats = StatsKeeper(StatsStore(appData));
  final walker = WalkDriver(mover, facing: () => controller.currentPet?.walkFacing ?? Facing.right);
  final companion = Companion(
    pets: controller,
    stats: stats,
    walker: walker,
    mover: mover,
    hudTransport: WindowChannelTransport(kHudChannel),
  );
  Timer.periodic(const Duration(minutes: 1), (_) => stats.tick());
```

  3. `AppExit` 的 `hide:` 列表改为 `[companion.shutdown, windowManager.hide, launcher.hideIfOpen]`。
  4. `runApp(PetWindowApp(...))` 多传 `companion: companion, walker: walker`；`await controller.boot();` 之后加：

```dart
  // The panel engine, created once and kept hidden; without it the pet
  // window works as before (spec 2026-09-19 E 4).
  unawaited(WindowController.create(WindowConfiguration(arguments: kHudWindowArgs, hiddenAtLaunch: true))
      .then<void>((_) {}, onError: (Object e) => developer.log('panel window failed: $e', name: 'aipet.hud')));
```

  （顶部加 `import 'dart:developer' as developer;`。）

- [ ] **Step 2: `PetWindowApp` 接线**：
  1. 构造加 `required this.companion, required this.walker`，字段 `final Companion companion; final WalkDriver walker;`。
  2. `_showMenu` 里 `await c.playAction(choice.substring('action:'.length));` 改为 `await widget.companion.userAction(choice.substring('action:'.length));`。
  3. `build` 里 `GestureDetector` 外包一层 `MouseRegion(onEnter: (_) => widget.companion.petEnter(), onExit: (_) => widget.companion.petExit(), child: ...)`；
     `onPanStart: (_) => windowManager.startDragging(),` 改为：

```dart
              onPanStart: (_) async {
                widget.companion.dragStarted();
                try {
                  await windowManager.startDragging(); // returns when the drag ends (modal SC_MOVE loop)
                } finally {
                  widget.companion.dragEnded();
                }
              },
```

  4. 视频那层改为随 `walker` 翻转：

```dart
                ListenableBuilder(
                  listenable: widget.walker,
                  builder: (_, child) => Transform.flip(flipX: widget.walker.mirrored, child: child),
                  child: ValueListenableBuilder<AlphaVideoController?>(
                    valueListenable: widget.player.controller,
                    builder: (_, vc, _) => vc == null ? const SizedBox.shrink() : AlphaVideoView(controller: vc),
                  ),
                ),
```

- [ ] **Step 3: 检查**：`flutter analyze` 零问题；`flutter test` 全过（115 + 本计划新增）；`flutter build windows --release` 成功（构建不启动程序）。
- [ ] **Step 4: 提交**：`git commit -m "feat(aipet): wire the panel, stats and walking into the pet window" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`

---

### Task 12: 回归、文档（控制器执行）

- [ ] **Step 1: 回归**：`flutter analyze`；`flutter test`；petgen `pytest -q`；原生 `ctest`（不应受影响）；`flutter build windows --release`。
- [ ] **Step 2: 结果文件** `docs/superpowers/plans/2026-09-19-desktop-interaction-results.md`：各任务提交、测试数、裁决；真机验收清单（待用户同意后执行）：
  悬停 300 ms 出面板、位置在头上方 / 顶部时翻到下方、× 行为、按钮（喂食后饱食 +30、今日互动 +1）、行走横穿与到边转身、翻转方向（金毛朝左、柯基 / 布偶猫朝右）、
  **走路和面板出现时当前前台窗口焦点不变**、自动走动（可临时把 3 分钟改短验证后改回）、重启后数值保留、退出时面板随之消失。
- [ ] **Step 3: HANDOFF** 第 0 节写进度；第 5 节加：命中测试仍按矩形（透明处悬停也会出面板）。提交结果文件：`git commit -m "docs: desktop interaction results" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"`
