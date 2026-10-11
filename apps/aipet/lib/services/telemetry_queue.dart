import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'api_client.dart';
import 'device_identity.dart';

/// The server keeps only these (pixpickweb-tp config/aipet.php `event_names`,
/// web platform spec 4.3); anything else would be dropped there anyway.
const kTelemetryEvents = {
  'app_start', // props {version}
  'heartbeat', // every 10 minutes while running
  'pet_adopt',
  'pet_switch',
  'interact', // props {kind}
  'voice_change',
  'login',
  'logout',
};

/// [TelemetryQueue.track] as the rest of the app sees it.
typedef TrackFn = void Function(String name, {String? petId, Map<String, Object?>? props});

/// Sends one batch: ApiClient.events for this device in production.
typedef SendEvents = Future<ApiResult> Function(List<Map<String, Object?>> events);

/// Usage events (web platform spec 8): kept in memory and in telemetry.jsonl
/// until the server has them, sent in batches every [flushEvery] or as soon as
/// [flushAt] are waiting. Offline costs nothing but disk: up to [maxEvents]
/// lines, the oldest dropped first. Never throws.
class TelemetryQueue {
  TelemetryQueue(
    this.root, {
    required this._send,
    DateTime Function()? now,
    Random? random,
    this.batchSize = 200,
    this.flushAt = 50,
    this.maxEvents = 5000,
    this.flushEvery = const Duration(seconds: 60),
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random.secure() {
    _pending = _load();
  }

  final Directory root;
  final int batchSize;
  final int flushAt;
  final int maxEvents;
  final Duration flushEvery;
  final SendEvents _send;
  final DateTime Function() _now;
  final Random _random;

  late final List<Map<String, Object?>> _pending;
  Timer? _timer;
  Future<void>? _flushing;
  bool _disposed = false;

  File get file => File('${root.path}${Platform.pathSeparator}telemetry.jsonl');

  List<Map<String, Object?>> get pending => List.unmodifiable(_pending);

  List<Map<String, Object?>> _load() {
    if (!file.existsSync()) return [];
    final out = <Map<String, Object?>>[];
    try {
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final j = jsonDecode(line);
          if (j is Map<String, Object?> && j['uid'] is String && kTelemetryEvents.contains(j['name'])) out.add(j);
        } catch (_) {
          // One torn line (a crash mid-append) must not cost the rest.
        }
      }
    } catch (e) {
      developer.log('telemetry.jsonl unreadable ($e); starting over', name: 'aipet.telemetry');
    }
    return out.length > maxEvents ? out.sublist(out.length - maxEvents) : out;
  }

  void track(String name, {String? petId, Map<String, Object?>? props}) {
    if (!kTelemetryEvents.contains(name)) {
      developer.log('unknown event $name not recorded', name: 'aipet.telemetry');
      return;
    }
    final e = <String, Object?>{
      'uid': uuidV4(_random),
      'name': name,
      'ts': _now().millisecondsSinceEpoch,
      'pet_id': ?petId,
      if (props != null && props.isNotEmpty) 'props': props,
    };
    _pending.add(e);
    if (_pending.length > maxEvents) {
      _pending.removeRange(0, _pending.length - maxEvents);
      _rewrite();
    } else {
      try {
        root.createSync(recursive: true);
        file.writeAsStringSync('${jsonEncode(e)}\n', mode: FileMode.append, flush: true);
      } catch (err) {
        developer.log('telemetry append failed: $err', name: 'aipet.telemetry');
      }
    }
    if (!_disposed && _pending.length >= flushAt) unawaited(flush());
  }

  /// Sends everything waiting, a batch at a time, until done or offline. A
  /// call while one is running joins it.
  Future<void> flush() => _flushing ??= _flushAll().whenComplete(() => _flushing = null);

  Future<void> _flushAll() async {
    while (_pending.isNotEmpty) {
      final batch = _pending.take(batchSize).toList();
      ApiResult r;
      try {
        r = await _send(batch);
      } catch (e) {
        r = ApiOffline('$e');
      }
      if (r is ApiOffline) return; // kept for the next try
      if (r is ApiError) {
        // The server read the batch and turned it down; resending the same
        // events would be turned down the same way, forever.
        developer.log('batch of ${batch.length} refused (${r.code} ${r.message}); dropped', name: 'aipet.telemetry');
      }
      // By uid: events tracked meanwhile, or the cap dropping old ones, moved
      // the list under us.
      final sent = {for (final e in batch) e['uid']};
      _pending.removeWhere((e) => sent.contains(e['uid']));
      _rewrite();
    }
  }

  void _rewrite() {
    try {
      root.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(_pending.map((e) => '${jsonEncode(e)}\n').join(), flush: true);
      tmp.renameSync(file.path);
    } catch (e) {
      developer.log('telemetry rewrite failed: $e', name: 'aipet.telemetry');
    }
  }

  /// Sends what an earlier run left behind, then every [flushEvery].
  void start() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(flushEvery, (_) => unawaited(flush()));
    unawaited(flush());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
