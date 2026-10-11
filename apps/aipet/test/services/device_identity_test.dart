import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aipet/services/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';

final _v4 = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('device_'));
  tearDown(() => root.deleteSync(recursive: true));

  File file() => File('${root.path}${Platform.pathSeparator}device.json');

  test('uuidV4 is a lowercase version-4 UUID, different every time', () {
    final r = Random(1);
    final ids = {for (var i = 0; i < 50; i++) uuidV4(r)};
    expect(ids, hasLength(50));
    for (final id in ids) {
      expect(id, matches(_v4));
    }
  });

  test('created once, then the same id on every launch', () {
    final id = DeviceIdentity(root).id;
    expect(id, matches(_v4));
    expect(DeviceIdentity(root).id, id);
    expect(jsonDecode(file().readAsStringSync()), {'schema': 1, 'deviceId': id});
  });

  test('an unreadable device.json is quarantined and replaced', () {
    file().writeAsStringSync('{nope');
    final id = DeviceIdentity(root).id;
    expect(id, matches(_v4));
    expect(File('${file().path}.bad').existsSync(), isTrue);
    expect(DeviceIdentity(root).id, id);
  });

  test('a device id that is not a UUID is not used', () {
    file().writeAsStringSync(jsonEncode({'schema': 1, 'deviceId': 'hello'}));
    expect(DeviceIdentity(root).id, matches(_v4));
  });

  test('a folder that cannot be written still gives an id for this run', () {
    final blocked = File('${root.path}${Platform.pathSeparator}blocked')..writeAsStringSync('');
    expect(DeviceIdentity(Directory(blocked.path)).id, matches(_v4));
  });
}
