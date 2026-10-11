import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/telemetry_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late DateTime now;
  late List<List<Map<String, Object?>>> batches;
  late FutureOr<ApiResult> Function(List<Map<String, Object?>>) answer;
  late TelemetryQueue q;

  TelemetryQueue make(
          {int maxEvents = 5000, int flushAt = 50, Duration flushEvery = const Duration(seconds: 60)}) =>
      TelemetryQueue(
        root,
        send: (events) async {
          batches.add(events);
          return answer(events);
        },
        now: () => now,
        random: Random(7),
        maxEvents: maxEvents,
        flushAt: flushAt,
        flushEvery: flushEvery,
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('telemetry_');
    now = DateTime.fromMillisecondsSinceEpoch(1790000000000);
    batches = [];
    answer = (_) => const ApiOk({'accepted': 1, 'dropped': 0});
    q = make();
  });
  tearDown(() {
    q.dispose();
    root.deleteSync(recursive: true);
  });

  File file() => File('${root.path}${Platform.pathSeparator}telemetry.jsonl');
  List<Map<String, Object?>> lines() => [
        for (final l in file().readAsLinesSync())
          if (l.isNotEmpty) jsonDecode(l) as Map<String, Object?>
      ];

  test('track: uid, name, ts, pet_id and props, in memory and on disk', () {
    q.track('interact', petId: 'builtin-gold', props: {'kind': 'feed'});
    q.track('app_start', props: {'version': '1.0.0'});
    expect(q.pending, hasLength(2));
    final e = q.pending.first;
    expect(e['uid'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(e['name'], 'interact');
    expect(e['ts'], 1790000000000);
    expect(e['pet_id'], 'builtin-gold');
    expect(e['props'], {'kind': 'feed'});
    expect(q.pending.last.containsKey('pet_id'), isFalse);
    expect(lines(), q.pending);
  });

  test('a name the server does not take is not recorded', () {
    q.track('mystery');
    expect(q.pending, isEmpty);
  });

  test('what was not sent survives a restart', () {
    q.track('heartbeat');
    final again = make();
    expect(again.pending.single['name'], 'heartbeat');
    again.dispose();
  });

  test('a corrupt line is skipped, the rest kept', () {
    q.track('heartbeat');
    file().writeAsStringSync('{broken\n', mode: FileMode.append);
    q.dispose();
    q = make();
    expect(q.pending, hasLength(1));
  });

  test('flush sends batches of at most 200 and clears what was accepted', () async {
    q.dispose();
    q = make(flushAt: 1000);
    for (var i = 0; i < 450; i++) {
      q.track('heartbeat');
    }
    await q.flush();
    expect(batches.map((b) => b.length), [200, 200, 50]);
    expect(q.pending, isEmpty);
    expect(lines(), isEmpty);
  });

  test('offline: everything stays for next time', () async {
    answer = (_) => const ApiOffline('down');
    q.track('heartbeat');
    q.track('heartbeat');
    await q.flush();
    expect(batches, hasLength(1));
    expect(q.pending, hasLength(2));
    expect(lines(), hasLength(2));
  });

  test('a batch the server refuses outright is dropped, not resent forever', () async {
    answer = (_) => const ApiError(1004, 'bad events');
    q.track('heartbeat');
    await q.flush();
    expect(q.pending, isEmpty);
  });

  test('events tracked while a flush is in flight are kept', () async {
    final gate = Completer<ApiResult>();
    answer = (_) => batches.length == 1 ? gate.future : const ApiOffline('down');
    q.track('heartbeat');
    final f = q.flush();
    await Future<void>.delayed(Duration.zero);
    q.track('interact', props: {'kind': 'play'});
    gate.complete(const ApiOk(null));
    await f;
    expect(batches[0].map((e) => e['name']), ['heartbeat']);
    expect(q.pending.single['name'], 'interact');
    expect(lines().single['name'], 'interact');
  });

  test('a second flush while one is running does not send twice', () async {
    final gate = Completer<ApiResult>();
    answer = (_) => gate.future;
    q.track('heartbeat');
    final a = q.flush();
    final b = q.flush();
    gate.complete(const ApiOk(null));
    await Future.wait([a, b]);
    expect(batches, hasLength(1));
  });

  test('capped at maxEvents: the oldest go first', () {
    q.dispose();
    q = make(maxEvents: 3);
    for (final n in ['app_start', 'heartbeat', 'login', 'logout']) {
      q.track(n);
    }
    expect(q.pending.map((e) => e['name']), ['heartbeat', 'login', 'logout']);
    expect(make(maxEvents: 3).pending.map((e) => e['name']), ['heartbeat', 'login', 'logout']);
  });

  test('50 pending sends without waiting for the timer', () async {
    for (var i = 0; i < 49; i++) {
      q.track('heartbeat');
    }
    await Future<void>.delayed(Duration.zero);
    expect(batches, isEmpty);
    q.track('heartbeat');
    await Future<void>.delayed(Duration.zero);
    expect(batches.single, hasLength(50));
  });

  test('start flushes now and then every flushEvery', () async {
    q.dispose();
    q = make(flushEvery: const Duration(milliseconds: 20));
    q.track('app_start');
    q.start();
    await Future<void>.delayed(Duration.zero);
    expect(batches, hasLength(1));
    q.track('heartbeat');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(batches, hasLength(2));
    q.dispose();
    q.track('heartbeat');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(batches, hasLength(2));
  });
}
