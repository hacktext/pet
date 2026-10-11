import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'json_file.dart';

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

bool isUuid(String s) => _uuid.hasMatch(s);

/// A random (version 4) UUID, lowercase.
String uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// device.json `{schema: 1, deviceId}`: this install's id for the statistics
/// (web platform spec 8), made up the first time it is asked for.
class DeviceIdentity {
  DeviceIdentity(this.root);

  final Directory root;
  String? _id;

  File get file => File('${root.path}${Platform.pathSeparator}device.json');

  /// Never throws: a file that cannot be written still gives an id for this run.
  String get id => _id ??= _loadOrCreate();

  String _loadOrCreate() {
    if (file.existsSync()) {
      try {
        final j = jsonDecode(file.readAsStringSync());
        final id = j is Map<String, Object?> && j['schema'] == 1 ? j['deviceId'] : null;
        if (id is String && isUuid(id)) return id.toLowerCase();
        throw const FormatException('bad deviceId');
      } catch (e) {
        quarantine(file, 'aipet.device', e);
      }
    }
    final id = uuidV4();
    try {
      writeJsonAtomic(file, {'schema': 1, 'deviceId': id});
    } catch (e) {
      developer.log('device.json save failed: $e', name: 'aipet.device');
    }
    return id;
  }
}
