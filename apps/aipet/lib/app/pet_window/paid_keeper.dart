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
    int? Function()? userId,
    this.onProgress,
    this.onInstalled,
  }) : _userId = userId ?? _noUser {
    final cached = _store.loadOwnedBy(); // not through load(): it needs catalog.json too
    _owned = cached.owned;
    _ownerId = cached.userId;
  }

  static int? _noUser() => null;

  final CharacterService _service;
  final PetInstaller _installer;
  final CatalogStore _store;
  final bool Function() _signedIn;

  /// The signed-in user's id; null when signed out or not known.
  final int? Function() _userId;

  /// After each verified file of a download.
  final void Function(String code, int done, int total)? onProgress;

  /// A character finished installing; awaited before [download] answers true.
  /// Must not throw (a throw is logged and the download still counts).
  final Future<void> Function(String code)? onInstalled;

  late Set<String> _owned;

  /// Whose [_owned] it is (owned.json's user_id); null when not known.
  int? _ownerId;

  /// Bumped by every refresh and sign-out: an answer to an older request is
  /// not applied over a newer one.
  int _generation = 0;
  final _downloads = <String, Future<bool>>{};

  @override
  Set<String> get owned => Set.unmodifiable(_owned);

  /// [p] may be shown: not a paid pet, or one the account owns.
  bool allows(Pet p) =>
      p.origin != PetOrigin.paid || (p.id.startsWith('paid-') && _owned.contains(p.id.substring(5)));

  /// Asks the server what the account owns. Signed out, or on any failure,
  /// the owned set stays as it is.
  @override
  Future<void> refresh() async {
    if (!_signedIn()) return;
    final gen = ++_generation;
    final user = _userId();
    final Set<String> fresh;
    try {
      fresh = (await _service.owned()).codes;
    } catch (e) {
      developer.log('owned characters not refreshed ($e); keeping the cached ones', name: _log);
      return;
    }
    if (gen != _generation) return; // a newer refresh or a sign-out came meanwhile
    _set(fresh, user);
  }

  /// [userId] just signed in. What is cached belongs to someone else (an
  /// expired login, then another account): it goes first, then the server
  /// is asked. The same user, or an unknown owner, keeps it meanwhile.
  Future<void> signedIn(int userId) {
    final owner = _ownerId;
    if (owner != null && owner != userId) signedOut();
    return refresh();
  }

  /// The user signed out: nothing is owned any more, here or in owned.json.
  void signedOut() {
    _generation++;
    _set(const {}, null);
  }

  void _set(Set<String> next, int? owner) {
    final ownerChanged = owner != _ownerId;
    _ownerId = owner;
    if (setEquals(next, _owned) && !ownerChanged) return;
    final changed = !setEquals(next, _owned);
    _owned = {...next};
    try {
      _store.saveOwned(_owned, userId: owner);
    } catch (e) {
      // Kept for this run all the same; the next refresh writes it again.
      developer.log('owned.json not saved: $e', name: _log);
    }
    if (changed) notifyListeners();
  }

  /// Downloads and installs `paid-<code>`; false when it is not owned or
  /// anything failed (files already verified stay for the next try). A second
  /// call while one runs gets the same answer. A code not known as owned
  /// (bought a moment ago, before the push) asks the server once first.
  @override
  Future<bool> download(String code) {
    if (_owned.contains(code)) return _shared(code);
    return refresh().then<bool>((_) => _owned.contains(code) ? _shared(code) : Future.value(false));
  }

  Future<bool> _shared(String code) {
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
