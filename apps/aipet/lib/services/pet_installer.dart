import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/custom_order.dart';
import '../domain/pet.dart';
import 'file_download.dart';

final String _sep = Platform.pathSeparator;
const _log = 'aipet.install';

/// Brings one pet's delivered files into `pets/<pet_id>/`, for custom and paid
/// pets alike. Built in the pet window, the only writer of the pets folder.
///
/// Files go to `pets/.downloading/<pet_id>/<path>` -- each through a `.part`
/// and checked against its size and sha256 -- and a file already there and
/// matching is not fetched again, so a quit mid-download resumes. Only a
/// complete pet is moved into place, in one directory rename. Anything that
/// fails is logged and left for the next trigger, keeping what was verified;
/// nothing here throws or shows an error.
class PetInstaller {
  PetInstaller({required this.petsRoot, required this._transport});

  final Directory petsRoot;
  final DownloadTransport _transport;

  Directory get stagingRoot => Directory('${petsRoot.path}$_sep.downloading');

  Directory _target(String petId) => Directory('${petsRoot.path}$_sep$petId');
  Directory _staging(String petId) => Directory('${stagingRoot.path}$_sep$petId');
  Directory _aside(String petId) => Directory('${petsRoot.path}$_sep.old-$petId');

  /// `pets/<petId>` holds a pet.json naming [petId] with [origin], and every file it lists.
  static Future<bool> isInstalled(Directory petsRoot, String petId, PetOrigin origin) =>
      _isComplete(Directory('${petsRoot.path}$_sep$petId'), petId, origin);

  static Future<bool> _isComplete(Directory dir, String petId, PetOrigin origin) async {
    try {
      final json = File('${dir.path}${_sep}pet.json');
      if (!await json.exists()) return false;
      final pet = parsePet(await json.readAsString(), dir);
      return pet.id == petId && pet.origin == origin && pet.isComplete;
    } catch (_) {
      return false;
    }
  }

  /// True once [assets] is installed; false when something is still missing or
  /// [keepGoing] turned false (verified files stay staged for next time).
  /// [onProgress] hears (done, total) after each file is verified, one already
  /// staged and matching included; a failed file is not counted.
  Future<bool> install(
    CustomAssets assets, {
    required PetOrigin origin,
    required bool Function() keepGoing,
    void Function(int done, int total)? onProgress,
  }) async {
    final petId = assets.petId;
    final staging = _staging(petId);
    var all = true;
    var done = 0;
    // Keep going after a failure: every file verified now is one less next time.
    for (final f in assets.files) {
      if (!keepGoing()) return false; // verified files stay staged for next time
      if (await _ensureFile(staging, f)) {
        onProgress?.call(++done, assets.files.length);
      } else {
        all = false;
      }
    }
    if (!all) return false;
    if (!keepGoing()) return false;
    if (!await _prune(staging, assets)) return false;
    if (!await _isComplete(staging, petId, origin)) {
      developer.log('$petId: the delivered files do not make a complete pet', name: _log);
      return false;
    }
    if (!keepGoing()) return false; // the prune and checks above awaited
    return _install(staging, petId);
  }

  Future<bool> _ensureFile(Directory staging, CustomAsset f) async {
    final target = File('${staging.path}$_sep${f.path.replaceAll('/', _sep)}');
    if (await _matches(target, f)) return true; // verified on an earlier run
    final part = File('${target.path}.part');
    try {
      await part.parent.create(recursive: true);
      await _transport.download(Uri.parse(f.url), part);
      if (!await _matches(part, f)) {
        developer.log('${f.path}: size or sha256 does not match; next time', name: _log);
        await part.delete();
        return false;
      }
      await part.rename(target.path);
      return true;
    } on DownloadFailed catch (e) {
      developer.log('${f.path}: ${e.reason}; next time', name: _log);
      return false;
    } catch (e) {
      developer.log('${f.path}: $e; next time', name: _log);
      return false;
    }
  }

  /// Streamed in chunks: a clip is never read into memory whole, and the UI
  /// isolate is never held for long.
  static Future<bool> _matches(File f, CustomAsset a) async {
    try {
      if (!await f.exists() || await f.length() != a.bytes) return false;
      return (await sha256.bind(f.openRead()).first).toString() == a.sha256;
    } catch (_) {
      return false;
    }
  }

  /// Deletes whatever in [staging] the manifest does not list -- files an
  /// older manifest had, `.part` leftovers -- so only the delivered pet is
  /// installed. Paths compare case-insensitively, as Windows does.
  static Future<bool> _prune(Directory staging, CustomAssets assets) async {
    final keep = <String>{};
    for (final f in assets.files) {
      final segments = f.path.toLowerCase().split('/');
      for (var i = 1; i <= segments.length; i++) {
        keep.add(segments.take(i).join('/'));
      }
    }
    try {
      final entries = await staging.list(recursive: true, followLinks: false).toList();
      for (final e in entries) {
        final rel = e.path.substring(staging.path.length + 1).replaceAll(_sep, '/').toLowerCase();
        if (keep.contains(rel) && e is! Link) continue;
        // A folder deleted above already took this one with it.
        if (await e.exists()) await e.delete(recursive: true);
      }
      return true;
    } catch (e) {
      developer.log('${assets.petId}: could not clear old staged files ($e); next time', name: _log);
      return false;
    }
  }

  /// staging -> `pets/<petId>`, one rename. A folder already there (incomplete,
  /// or deleted and half re-created by hand) is moved aside to `.old-<petId>`
  /// first and deleted after; if the move in fails, it is put back.
  Future<bool> _install(Directory staging, String petId) async {
    final target = _target(petId);
    final aside = _aside(petId);
    try {
      if (await aside.exists()) await aside.delete(recursive: true);
      if (await target.exists()) await target.rename(aside.path);
      try {
        await staging.rename(target.path);
      } catch (_) {
        if (await aside.exists() && !await target.exists()) await aside.rename(target.path);
        rethrow;
      }
    } catch (e) {
      developer.log('$petId: install failed ($e); next time', name: _log);
      return false;
    }
    try {
      if (await aside.exists()) await aside.delete(recursive: true);
    } catch (e) {
      // A dot-folder: the library never lists it, and the next install clears it.
      developer.log('$petId: could not delete the old folder ($e)', name: _log);
    }
    developer.log('$petId installed', name: _log);
    return true;
  }
}
