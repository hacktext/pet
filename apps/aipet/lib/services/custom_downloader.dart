import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/custom_order.dart';
import '../domain/pet.dart';
import 'api_client.dart';
import 'file_download.dart';
import 'pet_installer.dart';

final String _sep = Platform.pathSeparator;
const _log = 'aipet.custom';

/// Brings delivered custom pets down into `pets/<pet_id>/` (generation spec
/// 6.1). Built in the pet window, the only writer of the pets folder.
///
/// Files go to `pets/.downloading/<pet_id>/<path>` -- each through a `.part`
/// and checked against its size and sha256 -- and a file already there and
/// matching is not fetched again, so a quit mid-download resumes. Only a
/// complete pet is moved into place, in one directory rename. Anything that
/// fails is logged and left for the next trigger, keeping what was verified;
/// nothing here throws or shows an error.
class CustomDownloader {
  CustomDownloader({
    required this._api,
    required this._transport,
    required this.petsRoot,
    required this._signedIn,
    required this._onInstalled,
  });

  final Directory petsRoot;
  final ApiClient _api;
  final DownloadTransport _transport;
  final bool Function() _signedIn;
  final Future<void> Function(List<CustomDelivery>) _onInstalled;

  Future<void>? _running;
  bool _again = false;

  Directory get stagingRoot => Directory('${petsRoot.path}$_sep.downloading');

  bool get running => _running != null;

  late final PetInstaller _installer = PetInstaller(petsRoot: petsRoot, transport: _transport);

  /// One pass at a time. A trigger that arrives during a pass (login and the
  /// sync it starts, say) gets the same future, and one more pass runs after
  /// this one -- a delivery may have appeared since it asked.
  Future<void> run() {
    final current = _running;
    if (current != null) {
      _again = true;
      return current;
    }
    final done = Completer<void>();
    _running = done.future;
    unawaited(_loop(done));
    return done.future;
  }

  Future<void> _loop(Completer<void> done) async {
    // The last check of _again and the clearing of _running happen in one
    // synchronous step (no await between them), so a run() can never land in
    // between and be lost: it either set _again in time for the check or
    // starts a fresh run after it.
    try {
      do {
        _again = false;
        try {
          await _pass();
        } catch (e, s) {
          developer.log('pass failed: $e', name: _log, error: e, stackTrace: s);
        }
      } while (_again);
    } finally {
      _running = null;
      done.complete();
    }
  }

  Future<void> _pass() async {
    if (!_signedIn()) return;
    final r = await _api.customDeliveries();
    if (r is! ApiOk) {
      developer.log('deliveries: ${r.message}', name: _log);
      return;
    }
    final installed = <CustomDelivery>[];
    for (final d in CustomDelivery.listFrom(r.data)) {
      if (!_signedIn()) break;
      if (await PetInstaller.isInstalled(petsRoot, d.petId, PetOrigin.custom)) continue;
      if (await _fetch(d)) installed.add(d);
    }
    if (installed.isNotEmpty) await _onInstalled(installed);
  }

  /// True once [d] is installed; false when something is still missing.
  Future<bool> _fetch(CustomDelivery d) async {
    final r = await _api.customAssets(d.id);
    if (r is! ApiOk) {
      developer.log('${d.petId} assets: ${r.message}', name: _log);
      return false;
    }
    final assets = CustomAssets.fromJson(r.data);
    if (assets == null || assets.petId != d.petId) {
      developer.log('${d.petId}: unusable assets reply', name: _log);
      return false;
    }
    return _installer.install(assets, origin: PetOrigin.custom, keepGoing: _signedIn);
  }
}
