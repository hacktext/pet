import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/pet_stats.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';
import '../support/fake_sync_local.dart';

PetStats statsAt(int ms, {double intimacy = 50}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return PetStats(
    intimacy: intimacy,
    satiety: 50,
    health: 100,
    companionStartedAt: t,
    interactionDay: dayOf(t),
    todayInteractions: 0,
    updatedAt: t,
  );
}

void main() {
  late Directory root;
  late FakeHttp http;
  late FakeLocal local;
  late DateTime now;
  late bool signedIn;
  late SyncService sync;

  SyncService make({File? settingsFile, File? voiceFile}) => SyncService(
        root,
        api: ApiClient(http, baseUrl: 'https://x.test'),
        local: local,
        signedIn: () => signedIn,
        now: () => now,
        settingsFile: settingsFile,
        voiceFile: voiceFile,
      );

  setUp(() {
    root = Directory.systemTemp.createTempSync('sync_');
    http = FakeHttp();
    local = FakeLocal();
    now = DateTime.fromMillisecondsSinceEpoch(1790000000000);
    signedIn = true;
    sync = make();
    // By default the server merges nothing in: it echoes what it was sent.
    http.reply = (r) => FakeHttp.ok({'version': 1, 'data': r.json['data']});
  });
  tearDown(() => root.deleteSync(recursive: true));

  Map<String, Object?> meta() =>
      jsonDecode(File('${root.path}${Platform.pathSeparator}sync_meta.json').readAsStringSync())
          as Map<String, Object?>;

  test('the doc: settings and voice under sync_meta times, stats under their own', () async {
    local.settings = const LibraryState(currentPetId: 'builtin-gold', adoptedPetIds: ['builtin-gold']);
    local.voices = {'builtin-xiaoya': 'vivi'};
    local.stats = {'builtin-gold': statsAt(1000), 'Bad_Id': statsAt(1000)};
    sync.settingsChanged();
    now = now.add(const Duration(seconds: 1));
    sync.voiceChanged();
    final doc = sync.buildDoc();
    expect(doc['settings'],
        {'updatedAt': 1790000000000, 'currentPetId': 'builtin-gold', 'adoptedPetIds': ['builtin-gold']});
    expect(doc['voice'], {
      'updatedAt': 1790000001000,
      'choices': {'builtin-xiaoya': 'vivi'}
    });
    // A pet id the server would reject (and with it the whole doc) stays home.
    expect((doc['stats']! as Map).keys, ['builtin-gold']);
    expect(((doc['stats']! as Map)['builtin-gold'] as Map)['updatedAt'], 1000);
    expect(meta(), containsPair('settingsUpdatedAt', 1790000000000));
    expect(meta(), containsPair('voiceUpdatedAt', 1790000001000));
    expect(meta()['schema'], 1);
  });

  test('blocks never set on this computer go up as null, so they cannot overwrite the account', () {
    final doc = sync.buildDoc();
    expect(doc['settings'], isNull);
    expect(doc['voice'], isNull);
    expect(doc['stats'], <String, Object?>{});
  });

  test('upgrading: with no sync_meta yet, the files\' own save times stand in', () {
    final s = File('${root.path}${Platform.pathSeparator}settings.json')..writeAsStringSync('{}');
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    s.setLastModifiedSync(at);
    local.settings = const LibraryState(currentPetId: 'a', adoptedPetIds: ['a']);
    sync = make(settingsFile: s, voiceFile: File('${root.path}${Platform.pathSeparator}voice.json'));
    expect((sync.buildDoc()['settings']! as Map)['updatedAt'], 1700000000000);
    expect(sync.buildDoc()['voice'], isNull);
  });

  test('syncNow PUTs the doc with the last version and keeps the new one', () async {
    http.reply = (r) => FakeHttp.ok({'version': 7, 'data': r.json['data']});
    expect(await sync.syncNow(), isA<ApiOk>());
    expect(http.to('/api/aipet/sync').single.json['base_version'], 0);
    expect(sync.lastSyncAt, now);
    await sync.syncNow();
    expect(http.sent.last.json['base_version'], 7);
    // ...and across a restart.
    expect(make().version, 7);
    expect(make().lastSyncAt, now);
  });

  test('the server\'s newer blocks land locally; equal ones that match are left alone', () async {
    local.settings = const LibraryState(currentPetId: 'a', adoptedPetIds: ['a']);
    local.stats = {'a': statsAt(5000)};
    local.voices = {'z': 'q'}; // never chosen through settingsChanged: time 0
    sync.settingsChanged(); // at 1790000000000
    http.reply = (_) => FakeHttp.ok({
          'version': 2,
          'data': {
            'settings': {
              'updatedAt': 1790000005000,
              'currentPetId': 'b',
              'adoptedPetIds': ['a', 'b']
            },
            'stats': {
              'a': {...statsAt(5000).toJson()},
              'b': {...statsAt(9000, intimacy: 80).toJson()},
            },
            'voice': {'updatedAt': 3, 'choices': []},
          }
        });
    await sync.syncNow();
    expect(local.settings, const LibraryState(currentPetId: 'b', adoptedPetIds: ['a', 'b']));
    expect(local.applied, ['settings', 'stats b', 'voice']);
    expect(local.voices, isEmpty);
    expect(local.stats['b']!.intimacy, 80);
    expect(meta()['settingsUpdatedAt'], 1790000005000);
    expect(meta()['voiceUpdatedAt'], 3);
    expect(sync.dirty, isFalse);
  });

  test('a local block newer than the server\'s reply is kept (changed while the request was out)', () async {
    local.voices = {'x': 'a'};
    sync.voiceChanged();
    final gate = Completer<void>();
    http.reply = (r) async {
      final sent = r.json['data'];
      await gate.future;
      return FakeHttp.ok({'version': 1, 'data': sent});
    };
    final f = sync.syncNow();
    await Future<void>.delayed(Duration.zero);
    now = now.add(const Duration(seconds: 5));
    local.voices = {'x': 'b'};
    sync.voiceChanged();
    gate.complete();
    await f;
    expect(local.voices, {'x': 'b'});
    expect(local.applied, isEmpty);
    expect(sync.dirty, isTrue);
  });

  test('a stats entry older than the local one is not applied', () async {
    local.stats = {'a': statsAt(9000)};
    http.reply = (_) => FakeHttp.ok({
          'version': 1,
          'data': {
            'settings': null,
            'stats': {'a': statsAt(5000).toJson(), 'bad': {'updatedAt': 1}},
            'voice': null,
          }
        });
    await sync.syncNow();
    expect(local.applied, isEmpty);
  });

  test('applying does not count as a local change', () async {
    local.duringApply = sync.settingsChanged;
    http.reply = (_) => FakeHttp.ok({
          'version': 1,
          'data': {
            'settings': {'updatedAt': 5, 'currentPetId': null, 'adoptedPetIds': ['a']},
            'stats': [],
            'voice': null,
          }
        });
    await sync.syncNow();
    expect(local.applied, ['settings']);
    expect(meta()['settingsUpdatedAt'], 5);
    expect(sync.dirty, isFalse);
  });

  test('offline or refused: nothing applied, still dirty, message passed on', () async {
    sync.settingsChanged();
    http.reply = (_) => throw Exception('down');
    expect(await sync.syncNow(), isA<ApiOffline>());
    expect(sync.dirty, isTrue);
    expect(sync.lastSyncAt, isNull);
    http.reply = (_) => FakeHttp.fail(5004, '同步数据太大');
    expect((await sync.syncNow()).message, '同步数据太大');
  });

  test('a malformed reply is an error, not a crash', () async {
    http.reply = (_) => FakeHttp.ok({'version': 'x'});
    expect(await sync.syncNow(), isA<ApiError>());
  });

  test('signed out: no request at all', () async {
    signedIn = false;
    expect(await sync.syncNow(), isA<ApiError>());
    expect(http.sent, isEmpty);
  });

  test('two syncs at once share one request', () async {
    final gate = Completer<void>();
    http.reply = (r) async {
      await gate.future;
      return FakeHttp.ok({'version': 1, 'data': r.json['data']});
    };
    final a = sync.syncNow();
    final b = sync.syncNow();
    gate.complete();
    await Future.wait([a, b]);
    expect(http.sent, hasLength(1));
  });

  test('maybeSync: only when dirty and 5 minutes after the last attempt', () async {
    await sync.maybeSync();
    expect(http.sent, isEmpty, reason: 'nothing changed');
    sync.statsChanged();
    await sync.maybeSync();
    expect(http.sent, hasLength(1), reason: 'never synced yet');
    sync.statsChanged();
    now = now.add(const Duration(minutes: 4));
    await sync.maybeSync();
    expect(http.sent, hasLength(1), reason: 'too soon');
    now = now.add(const Duration(minutes: 1));
    await sync.maybeSync();
    expect(http.sent, hasLength(2));
    signedIn = false;
    sync.statsChanged();
    now = now.add(const Duration(minutes: 10));
    await sync.maybeSync();
    expect(http.sent, hasLength(2), reason: 'signed out');
  });

  test('a failed sync is retried 5 minutes later even with nothing new', () async {
    http.reply = (_) => throw Exception('down');
    await sync.syncNow();
    http.reply = (r) => FakeHttp.ok({'version': 1, 'data': r.json['data']});
    await sync.maybeSync();
    expect(http.sent, hasLength(1));
    now = now.add(const Duration(minutes: 5));
    await sync.maybeSync();
    expect(http.sent, hasLength(2));
  });

  test('signedOut forgets the version and the last sync time, not the local times', () async {
    sync.settingsChanged();
    await sync.syncNow();
    sync.signedOut();
    expect(sync.version, 0);
    expect(sync.lastSyncAt, isNull);
    expect(make().version, 0);
    expect(meta()['settingsUpdatedAt'], 1790000000000);
  });

  test('an unreadable sync_meta.json is quarantined and starts over', () {
    File('${root.path}${Platform.pathSeparator}sync_meta.json').writeAsStringSync('[');
    expect(make().version, 0);
    expect(File('${root.path}${Platform.pathSeparator}sync_meta.json.bad').existsSync(), isTrue);
  });
}
