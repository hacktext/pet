import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/library_state.dart';
import '../domain/pet_stats.dart';
import 'api_client.dart';
import 'json_file.dart';

/// What sync reads from and writes back to: the pet window's settings, stats
/// and voice choices (it is their only writer).
abstract class SyncLocal {
  /// Who is on the desktop and who is adopted (preparingPetId is ignored).
  LibraryState get settings;
  Map<String, PetStats> get stats;
  Map<String, String> get voices;

  /// The account's settings won: adopt its list, and put its pet on the
  /// desktop when this computer can.
  Future<void> applySettings(LibraryState s);

  /// Only entries newer than (or as new as and different from) the local ones.
  void applyStats(Map<String, PetStats> newer);
  void applyVoices(Map<String, String> choices);
}

/// The server accepts these pet ids only; one other id refuses the whole doc.
final _serverPetId = RegExp(r'^[a-z0-9-]{1,64}$');

/// Cross-computer sync for a signed-in user (web platform spec 4.2 / 8).
///
/// The doc has three blocks, each "last writer wins" on its updatedAt (ms):
/// settings whole, voice whole, stats per pet. Stats carry their own
/// updatedAt; settings and voice get theirs from sync_meta.json, bumped by
/// [settingsChanged] / [voiceChanged]. A PUT always merges on the server and
/// returns the merged doc, which is applied here block by block under the same
/// rule -- so a change made while the request was out is not overwritten.
///
/// sync_meta.json `{schema: 1, settingsUpdatedAt, voiceUpdatedAt, version,
/// lastSyncAt}`. Never throws.
class SyncService {
  SyncService(
    this.root, {
    required this._api,
    required this._local,
    required this._signedIn,
    DateTime Function()? now,
    this.minInterval = const Duration(minutes: 5),
    File? settingsFile,
    File? voiceFile,
  }) : _now = now ?? DateTime.now {
    _loadMeta(settingsFile, voiceFile);
  }

  final Directory root;
  final Duration minInterval;
  final ApiClient _api;
  final SyncLocal _local;
  final bool Function() _signedIn;
  final DateTime Function() _now;

  int _settingsAt = 0;
  int _voiceAt = 0;
  int _version = 0;
  DateTime? _lastSyncAt;
  DateTime? _lastAttempt;
  bool _dirty = false;
  int _changes = 0; // bumped by every local change, to tell what happened mid-request
  bool _applying = false;
  Future<ApiResult>? _running;

  File get file => File('${root.path}${Platform.pathSeparator}sync_meta.json');

  int get version => _version;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get dirty => _dirty;
  bool get syncing => _running != null;

  void _loadMeta(File? settingsFile, File? voiceFile) {
    if (!file.existsSync()) {
      // First run with sync: a settings.json / voice.json already there was
      // last written when its file says, which is just what updatedAt means.
      _settingsAt = _mtime(settingsFile);
      _voiceAt = _mtime(voiceFile);
      return;
    }
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is! Map<String, Object?> || j['schema'] != 1) throw const FormatException('bad schema');
      int read(String k) => switch (j[k]) { final num v => v.toInt(), null => 0, _ => throw FormatException(k) };
      _settingsAt = read('settingsUpdatedAt');
      _voiceAt = read('voiceUpdatedAt');
      _version = read('version');
      final last = read('lastSyncAt');
      _lastSyncAt = last == 0 ? null : DateTime.fromMillisecondsSinceEpoch(last);
    } catch (e) {
      quarantine(file, 'aipet.sync', e);
    }
  }

  static int _mtime(File? f) {
    try {
      return f != null && f.existsSync() ? f.lastModifiedSync().millisecondsSinceEpoch : 0;
    } catch (_) {
      return 0;
    }
  }

  void _saveMeta() {
    try {
      writeJsonAtomic(file, {
        'schema': 1,
        'settingsUpdatedAt': _settingsAt,
        'voiceUpdatedAt': _voiceAt,
        'version': _version,
        'lastSyncAt': _lastSyncAt?.millisecondsSinceEpoch ?? 0,
      });
    } catch (e) {
      developer.log('sync_meta.json save failed: $e', name: 'aipet.sync');
    }
  }

  /// Signed in or not: a change made while signed out still counts as the
  /// newest once the user signs in.
  void settingsChanged() {
    if (_applying) return;
    _settingsAt = _now().millisecondsSinceEpoch;
    _changed();
    _saveMeta();
  }

  void voiceChanged() {
    if (_applying) return;
    _voiceAt = _now().millisecondsSinceEpoch;
    _changed();
    _saveMeta();
  }

  /// Stats carry their own updatedAt; this only says there is something to send.
  void statsChanged() {
    if (_applying) return;
    _changed();
  }

  void _changed() {
    _dirty = true;
    _changes++;
  }

  /// The account is gone from this computer; the local data stays as it is.
  void signedOut() {
    _version = 0;
    _lastSyncAt = null;
    _lastAttempt = null;
    _saveMeta();
  }

  /// The doc as of now. A block never set on this computer goes up as null,
  /// so a fresh install cannot overwrite what the account already has.
  Map<String, Object?> buildDoc() {
    final s = _local.settings;
    return {
      'settings': _settingsAt == 0
          ? null
          : {'updatedAt': _settingsAt, 'currentPetId': s.currentPetId, 'adoptedPetIds': s.adoptedPetIds},
      'stats': {
        for (final e in _local.stats.entries)
          if (_serverPetId.hasMatch(e.key)) e.key: e.value.toJson(),
      },
      'voice': _voiceAt == 0 ? null : {'updatedAt': _voiceAt, 'choices': Map.of(_local.voices)},
    };
  }

  /// Called every minute or so: syncs when something changed (or the last
  /// try failed) and [minInterval] has passed since the last try.
  Future<void> maybeSync() async {
    if (!_signedIn() || !_dirty || _running != null) return;
    final last = _lastAttempt;
    if (last != null && _now().difference(last) < minInterval) return;
    await syncNow();
  }

  /// One PUT and the merged doc applied. A call while one is running joins it.
  Future<ApiResult> syncNow() => _running ??= _sync().whenComplete(() => _running = null);

  Future<ApiResult> _sync() async {
    if (!_signedIn()) return const ApiError(-1, '请先登录');
    _lastAttempt = _now();
    final changesBefore = _changes;
    final r = await _api.putSync(_version, buildDoc());
    if (r is! ApiOk) {
      _dirty = true; // try again after minInterval
      developer.log('sync failed: ${r.message}', name: 'aipet.sync');
      return r;
    }
    final data = r.data;
    final doc = data is Map ? data['data'] : null;
    final version = data is Map ? data['version'] : null;
    if (version is! int || doc is! Map) {
      _dirty = true;
      developer.log('sync reply malformed: $data', name: 'aipet.sync');
      return const ApiError(-1, '同步失败，请稍后再试');
    }
    _version = version;
    _applying = true;
    try {
      await _apply(doc);
    } catch (e) {
      developer.log('applying the synced doc failed: $e', name: 'aipet.sync');
    } finally {
      _applying = false;
    }
    _lastSyncAt = _now();
    _dirty = _changes != changesBefore;
    _saveMeta();
    return r;
  }

  Future<void> _apply(Map<Object?, Object?> doc) async {
    final settings = _block(doc['settings']);
    if (settings != null) {
      final (at, block) = settings;
      final remote = _settingsFrom(block);
      if (remote != null && at >= _settingsAt) {
        final l = _local.settings;
        if (LibraryState(currentPetId: l.currentPetId, adoptedPetIds: l.adoptedPetIds) != remote) {
          await _local.applySettings(remote);
        }
        _settingsAt = at;
      }
    }

    final stats = doc['stats'];
    if (stats is Map) {
      final mine = _local.stats;
      final newer = <String, PetStats>{};
      for (final e in stats.entries) {
        if (e.key is! String || e.value is! Map) continue;
        final PetStats remote;
        try {
          remote = PetStats.fromJson(e.value as Map<Object?, Object?>);
        } catch (_) {
          continue; // a pet some other build wrote differently: leave ours alone
        }
        final local = mine[e.key];
        if (local == null || (!remote.updatedAt.isBefore(local.updatedAt) && remote != local)) {
          newer[e.key as String] = remote;
        }
      }
      if (newer.isNotEmpty) _local.applyStats(newer);
    }

    final voice = _block(doc['voice']);
    if (voice != null) {
      final (at, block) = voice;
      final choices = block['choices'];
      // PHP may send an empty map as [].
      final remote = choices is Map
          ? {for (final e in choices.entries) if (e.key is String && e.value is String) e.key as String: e.value as String}
          : choices is List && choices.isEmpty
              ? <String, String>{}
              : null;
      if (remote != null && at >= _voiceAt) {
        if (!_sameMap(remote, _local.voices)) _local.applyVoices(remote);
        _voiceAt = at;
      }
    }
  }

  /// A settings or voice block: its updatedAt and the block; null when absent or malformed.
  static (int, Map<Object?, Object?>)? _block(Object? b) {
    if (b is! Map) return null;
    final at = b['updatedAt'];
    return at is num ? (at.toInt(), b) : null;
  }

  static LibraryState? _settingsFrom(Map<Object?, Object?> b) {
    final current = b['currentPetId'];
    final adopted = b['adoptedPetIds'];
    if (current != null && current is! String) return null;
    if (adopted is! List || adopted.any((v) => v is! String)) return null;
    return LibraryState(currentPetId: current as String?, adoptedPetIds: adopted.cast<String>().toList());
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}
