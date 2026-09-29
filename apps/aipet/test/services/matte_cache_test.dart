import 'dart:async';
import 'dart:io';

import 'package:aipet/services/matte_cache.dart';
import 'package:flutter_test/flutter_test.dart';

class FakePrepare {
  int calls = 0;
  final destinations = <String>[];
  Completer<void>? gate;
  Object? error;

  Future<void> call({required String source, required String destination}) async {
    calls++;
    destinations.add(destination);
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    File(destination).writeAsStringSync('matted:${File(source).readAsStringSync()}');
  }
}

void main() {
  late Directory tmp, root;
  late FakePrepare prepare;
  late MatteCache cache;

  File clip(String name, String content) =>
      File('${tmp.path}\\$name')..writeAsStringSync(content);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('matte_');
    root = Directory('${tmp.path}\\matte-cache\\v1');
    prepare = FakePrepare();
    cache = MatteCache(root: root, prepare: prepare.call);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('key is 32 hex chars of sha256 plus the pipeline version', () {
    final k = MatteCache.keyFor('abc'.codeUnits);
    expect(k, matches(RegExp(r'^[0-9a-f]{32}-p3$')));
    expect(k, startsWith('ba7816bf8f01cfea414140de5dae2223')); // sha256("abc")
    expect(MatteCache.keyFor('abd'.codeUnits), isNot(k));
  });

  test('first use mattes into staging, then renames into the cache', () async {
    final f = await cache.ensure(clip('stand.mp4', 'A'));
    expect(prepare.calls, 1);
    expect(prepare.destinations.single, contains('\\.staging\\'));
    expect(f.path, '${root.path}\\${MatteCache.keyFor('A'.codeUnits)}.aipmat');
    expect(f.readAsStringSync(), 'matted:A');
    expect(Directory('${root.path}\\.staging').listSync(), isEmpty);
  });

  test('a cached clip is not matted again', () async {
    final src = clip('stand.mp4', 'A');
    await cache.ensure(src);
    await cache.ensure(src);
    expect(prepare.calls, 1);
  });

  test('keyed by content: the same clip under two paths is matted once', () async {
    final a = await cache.ensure(clip('a.mp4', 'same'));
    final b = await cache.ensure(clip('b.mp4', 'same'));
    expect(prepare.calls, 1);
    expect(b.path, a.path);
  });

  test('concurrent requests share one prepare', () async {
    prepare.gate = Completer<void>();
    final src = clip('walk.mp4', 'W');
    final f1 = cache.ensure(src);
    final f2 = cache.ensure(src);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    prepare.gate!.complete();
    final r = await Future.wait([f1, f2]);
    expect(prepare.calls, 1);
    expect(r[0].path, r[1].path);
  });

  test('a failed prepare leaves nothing behind and the next call retries', () async {
    prepare.error = Exception('decode failed');
    final src = clip('sleep.mp4', 'S');
    await expectLater(cache.ensure(src), throwsException);
    expect(root.listSync().whereType<File>(), isEmpty);
    expect(Directory('${root.path}\\.staging').listSync(), isEmpty);
    prepare.error = null;
    expect((await cache.ensure(src)).readAsStringSync(), 'matted:S');
    expect(prepare.calls, 2);
  });
}
