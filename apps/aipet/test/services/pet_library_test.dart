import 'dart:io';

import 'package:aipet/domain/pet.dart';
import 'package:aipet/services/pet_library.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/pet_fixtures.dart';

/// A root that exists but cannot be listed (e.g. access denied).
class _UnlistableDir extends Fake implements Directory {
  _UnlistableDir(this.path);

  @override
  final String path;

  @override
  bool existsSync() => true;

  @override
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) =>
      throw PathAccessException(path, const OSError('Access is denied.', 5));
}

void main() {
  late Directory tmp, builtin, custom;
  late PetLibrary lib;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('library_');
    builtin = Directory('${tmp.path}\\builtin')..createSync();
    custom = Directory('${tmp.path}\\custom')..createSync();
    lib = PetLibrary(builtinRoot: builtin, customRoot: custom);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('built-ins first, then custom pets, each sorted by id', () {
    writePet(builtin, id: 'builtin-ragdoll', species: 'cat');
    writePet(builtin, id: 'builtin-gold');
    writePet(custom, id: 'custom-lucky', origin: 'custom');
    expect(lib.scan().map((p) => p.id), ['builtin-gold', 'builtin-ragdoll', 'custom-lucky']);
  });

  test('a broken pet.json is skipped, the rest still load', () {
    writePet(builtin, id: 'builtin-gold');
    Directory('${builtin.path}\\broken').createSync();
    File('${builtin.path}\\broken\\pet.json').writeAsStringSync('{nope');
    Directory('${builtin.path}\\no-json').createSync();
    File('${builtin.path}\\stray.txt').writeAsStringSync('x');
    expect(lib.scan().map((p) => p.id), ['builtin-gold']);
  });

  test('a folder whose origin does not match its root is skipped', () {
    writePet(builtin, id: 'sneaky', origin: 'custom');
    writePet(custom, id: 'also-sneaky', origin: 'builtin');
    expect(lib.scan(), isEmpty);
  });

  test('a paid pet under the custom root is listed, under the built-in root it is skipped', () {
    writePet(custom, id: 'paid-x', origin: 'paid');
    writePet(builtin, id: 'paid-y', origin: 'paid');
    expect(lib.scan().map((p) => p.id), ['paid-x']);
    expect(lib.scan().single.origin, PetOrigin.paid);
  });

  test('duplicate ids: the built-in wins', () {
    writePet(builtin, id: 'twin', name: '系统');
    writePet(custom, id: 'twin', origin: 'custom', name: '定制');
    final pets = lib.scan();
    expect(pets.single.name, '系统');
    expect(pets.single.origin, PetOrigin.builtin);
  });

  test('missing roots are simply empty', () {
    final none = PetLibrary(builtinRoot: Directory('${tmp.path}\\x'), customRoot: Directory('${tmp.path}\\y'));
    expect(none.scan(), isEmpty);
  });

  test('a root that cannot be listed counts as empty; the other root still loads', () {
    writePet(custom, id: 'custom-lucky', origin: 'custom');
    final locked = PetLibrary(builtinRoot: _UnlistableDir('${tmp.path}\\locked'), customRoot: custom);
    expect(locked.scan().map((p) => p.id), ['custom-lucky']);
  });

  test('incomplete folders are still listed (the card shows 素材缺失)', () {
    writePet(builtin, id: 'half', complete: false);
    final p = lib.scan().single;
    expect(p.isComplete, isFalse);
  });

  test('byId', () {
    writePet(builtin, id: 'builtin-gold');
    final pets = lib.scan();
    expect(PetLibrary.byId(pets, 'builtin-gold')?.id, 'builtin-gold');
    expect(PetLibrary.byId(pets, 'nope'), isNull);
  });

  test('dot folders (a download in progress, a pet being replaced) are not pets', () {
    writePet(custom, id: 'custom-7', origin: 'custom');
    writePet(Directory('${custom.path}\\.downloading'), id: 'custom-8', origin: 'custom');
    // A complete, valid pet folder moved aside while its replacement goes in.
    writePet(custom, id: 'custom-9', origin: 'custom').renameSync('${custom.path}\\.old-custom-9');
    expect(lib.scan().map((p) => p.id), ['custom-7']);
  });
}
