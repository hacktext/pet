import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../domain/pet.dart';
import '../../services/catalog_store.dart';
import '../../services/character_service.dart';
import '../../services/pet_installer.dart';
import '../../services/window_bridge.dart';

const _log = 'aipet.paid';

/// Which paid characters the account owns, as the pet window knows it, and
/// their downloads. The pet window is the only writer of pets/ and owned.json.
///
/// [owned] starts as the cached owned.json, so an offline launch or an expired
/// login keeps what was bought; only [signedOut] or the server saying so
/// takes a character away. Listeners hear every change of [owned].
class PaidKeeper extends ChangeNotifier implements PaidHandler {
  PaidKeeper(
    this._service,
    this._installer,
    this._store, {
    required this._signedIn,
    this.onProgress,
    this.onInstalled,
  }) : _owned = _cached(_store);

  final CharacterService _service;
  final PetInstaller _installer;
  final CatalogStore _store;
  final bool Function() _signedIn;

  /// After each verified file of a download.
  final void Function(String code, int done, int total)? onProgress;

  /// A character finished installing; awaited before [download] answers true.
  /// Must not throw (a throw is logged and the download still counts).
  final Future<void> Function(String code)? onInstalled;

  Set<String> _owned;

  /// Bumped by every refresh and sign-out: an answer to an older request is
  /// not applied over a newer one.
  int _generation = 0;
  final _downloads = <String, Future<bool>>{};

  static Set<String> _cached(CatalogStore store) => {...?store.load()?.owned};

  @override
  Set<String> get owned => Set.unmodifiable(_owned);

  /// [p] may be shown: not a paid pet, or one the account owns.
  bool allows(Pet p) => p.origin != PetOrigin.paid || _owned.contains(p.id.substring(5));

  /// Asks the server what the account owns. Signed out, or on any failure,
  /// the owned set stays as it is.
  @override
  Future<void> refresh() async {
    if (!_signedIn()) return;
    final gen = ++_generation;
    final Set<String> fresh;
    try {
      fresh = await _service.owned();
    } catch (e) {
      developer.log('owned characters not refreshed ($e); keeping the cached ones', name: _log);
      return;
    }
    if (gen != _generation) return; // a newer refresh or a sign-out came meanwhile
    _set(fresh);
  }

  /// The user signed out: nothing is owned any more, here or in owned.json.
  void signedOut() {
    _generation++;
    _set(const {});
  }

  void _set(Set<String> next) {
    if (setEquals(next, _owned)) return;
    _owned = {...next};
    try {
      _store.saveOwned(_owned);
    } catch (e) {
      // Kept for this run all the same; the next refresh writes it again.
      developer.log('owned.json not saved: $e', name: _log);
    }
    notifyListeners();
  }

  /// Downloads and installs `paid-<code>`; false when it is not owned or
  /// anything failed (files already verified stay for the next try). A second
  /// call while one runs gets the same answer.
  @override
  Future<bool> download(String code) {
    if (!_owned.contains(code)) return Future.value(false);
    // A block, not `=> remove(code)`: whenComplete would wait for the future
    // that remove returns -- this one.
    return _downloads[code] ??= _download(code).whenComplete(() {
      _downloads.remove(code);
    });
  }

  Future<bool> _download(String code) async {
    final petId = 'paid-$code';
    try {
      final assets = await _service.assets(code);
      if (assets.petId != petId) {
        developer.log('$code: the server delivered ${assets.petId}', name: _log);
        return false;
      }
      final ok = await _installer.install(
        assets,
        origin: PetOrigin.paid,
        keepGoing: () => _owned.contains(code), // signed out mid-download: stop
        onProgress: (done, total) => onProgress?.call(code, done, total),
      );
      if (!ok) return false;
    } catch (e) {
      developer.log('$code: download failed ($e)', name: _log);
      return false;
    }
    try {
      await onInstalled?.call(code);
    } catch (e) {
      developer.log('$code: after install: $e', name: _log);
    }
    return true;
  }
}
