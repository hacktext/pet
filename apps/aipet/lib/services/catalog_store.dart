import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../domain/paid_character.dart';
import 'file_download.dart';

/// `<appData>/catalog/`: the last paid-character catalog the backend sent
/// (catalog.json), which of them the account owns (owned.json) and their card
/// photos (`cards/<code>.jpg`), so the library works offline.
class CatalogStore {
  CatalogStore(Directory appData) : _dir = Directory('${appData.path}${Platform.pathSeparator}catalog');

  final Directory _dir;

  File _file(String name) => File('${_dir.path}${Platform.pathSeparator}$name');

  /// Null when no catalog was ever cached (or catalog.json is unreadable);
  /// an unreadable owned.json is nothing owned. Never throws.
  ({List<PaidCharacter> items, Set<String> owned})? load() {
    final List<PaidCharacter> items;
    try {
      final f = _file('catalog.json');
      if (!f.existsSync()) return null;
      items = paidCatalogFrom(jsonDecode(f.readAsStringSync()));
    } catch (e) {
      developer.log('catalog.json unreadable ($e); nothing cached', name: 'aipet.catalog');
      return null;
    }
    var owned = <String>{};
    try {
      final f = _file('owned.json');
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is! List<Object?>) throw const FormatException('not a list');
        owned = {for (final c in j) if (c is String) c};
      }
    } catch (e) {
      developer.log('owned.json unreadable ($e); nothing owned', name: 'aipet.catalog');
    }
    return (items: items, owned: owned);
  }

  void save(List<PaidCharacter> items) => _write('catalog.json', [for (final c in items) c.toJson()]);

  void saveOwned(Set<String> owned) => _write('owned.json', owned.toList()..sort());

  File cardFile(String code) =>
      File('${_dir.path}${Platform.pathSeparator}cards${Platform.pathSeparator}$code.jpg');

  /// Downloads the card photo unless it is already there; never throws.
  Future<void> cacheCard(PaidCharacter c, DownloadTransport t) async {
    final url = c.cardUrl;
    if (url == null) return;
    try {
      final f = cardFile(c.code);
      if (f.existsSync() && f.lengthSync() > 0) return;
      f.parent.createSync(recursive: true);
      final part = File('${f.path}.part');
      await t.download(Uri.parse(url), part);
      part.renameSync(f.path);
    } catch (e) {
      developer.log('card ${c.code} not cached ($e)', name: 'aipet.catalog');
    }
  }

  void _write(String name, Object json) {
    _dir.createSync(recursive: true);
    final f = _file(name);
    final tmp = File('${f.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(json), flush: true);
    tmp.renameSync(f.path);
  }
}
