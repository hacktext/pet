import 'dart:io';

import 'package:crypto/crypto.dart';

/// Bump when pet_matte's output changes, so old caches are not reused.
const String kMattePipelineVersion = 'p1';

typedef PrepareFn = Future<void> Function({required String source, required String destination});

/// Content-addressed .aipmat cache (spec 4.2). Keyed by what the clip IS, not
/// where it lives: the install folder can move, and an upgrade can ship a
/// different clip under the same name.
class MatteCache {
  MatteCache({required this.root, required this._prepare});

  final Directory root;
  final PrepareFn _prepare;
  final Map<String, Future<File>> _inFlight = {};

  static String keyFor(List<int> bytes) =>
      '${sha256.convert(bytes).toString().substring(0, 32)}-$kMattePipelineVersion';

  /// The matted clip for [source], matting it first if it is not cached yet.
  Future<File> ensure(File source) async {
    final key = keyFor(await source.readAsBytes());
    final done = File('${root.path}${Platform.pathSeparator}$key.aipmat');
    if (done.existsSync()) return done;
    // Block body on purpose: an arrow would return the removed Future -- the very future whenComplete returned -- and it would wait on itself forever.
    return _inFlight[key] ??= _build(source, key, done).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<File> _build(File source, String key, File done) async {
    final staging = Directory('${root.path}${Platform.pathSeparator}.staging')..createSync(recursive: true);
    final tmp = File('${staging.path}${Platform.pathSeparator}$key.$pid.tmp');
    try {
      await _prepare(source: source.path, destination: tmp.path);
      return await tmp.rename(done.path); // same volume: atomic, never a half-written cache file
    } catch (_) {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }
}
