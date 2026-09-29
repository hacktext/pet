import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pet_shell/actions.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('pet_actions_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File touch(String name) =>
      File('${dir.path}${Platform.pathSeparator}$name')..writeAsStringSync('x');

  group('discoverActions', () {
    test('one action per mp4, keyed by file name, stand first then alphabetical', () {
      touch('walk.mp4');
      touch('lick_paw.mp4');
      touch('stand.mp4');
      touch('notes.txt');
      expect(discoverActions(dir).map((a) => a.key), ['stand', 'lick_paw', 'walk']);
    });

    test('competitor-style <key>-<key>.mp4 names collapse to <key>', () {
      touch('walk-walk.mp4');
      touch('act_cute-act_cute.mp4');
      expect(discoverActions(dir).map((a) => a.key), ['act_cute', 'walk']);
    });

    test('extension is matched case-insensitively and keys are lower-cased', () {
      touch('SLEEP.MP4');
      expect(discoverActions(dir).single.key, 'sleep');
    });

    test('empty directory yields no actions', () {
      expect(discoverActions(dir), isEmpty);
    });

    test('each action carries its loop flag, label and source file', () {
      final sleep = touch('sleep.mp4');
      touch('spin.mp4');
      final byKey = {for (final a in discoverActions(dir)) a.key: a};
      expect(byKey['sleep']!.loops, isTrue);
      expect(byKey['spin']!.loops, isFalse);
      expect(byKey['sleep']!.label, '睡觉');
      expect(byKey['sleep']!.source.path, sleep.path);
    });
  });

  group('actionFromFile', () {
    test('builds an action from a single clip (AIPET_DEV_CLIP)', () {
      final a = actionFromFile(touch('walk-walk.mp4'))!;
      expect(a.key, 'walk');
      expect(a.loops, isTrue);
    });

    test('rejects non-mp4 files', () {
      expect(actionFromFile(touch('readme.txt')), isNull);
    });
  });

  group('isLooping follows spec 4.6: stand/walk/sleep loop, the rest are one-shot', () {
    for (final k in ['stand', 'walk', 'sleep']) {
      test('$k loops', () => expect(isLooping(k), isTrue));
    }
    for (final k in ['feed', 'play', 'spin', 'lick_paw', 'act_cute', 'unknown_key']) {
      test('$k is one-shot', () => expect(isLooping(k), isFalse));
    }
  });

  group('labelFor', () {
    test('known keys get a Chinese label', () {
      expect(labelFor('stand'), '待机');
      expect(labelFor('lick_paw'), '舔爪子');
    });

    test('unknown keys fall back to the key itself', () {
      expect(labelFor('backflip'), 'backflip');
    });
  });

  group('defaultActionKey', () {
    test('prefers stand', () => expect(defaultActionKey(['walk', 'stand']), 'stand'));
    test('otherwise the first key', () => expect(defaultActionKey(['walk', 'sleep']), 'walk'));
    test('null when there is nothing', () => expect(defaultActionKey([]), isNull));
  });

  group('needsPrepare', () {
    test('true when the cache file does not exist', () {
      final src = touch('stand.mp4');
      expect(needsPrepare(src, File('${dir.path}${Platform.pathSeparator}missing.aipmat')), isTrue);
    });

    test('true when the cache is older than the source clip', () {
      final src = touch('stand.mp4');
      final cache = touch('stand.aipmat');
      cache.setLastModifiedSync(DateTime(2020));
      src.setLastModifiedSync(DateTime(2021));
      expect(needsPrepare(src, cache), isTrue);
    });

    test('false when the cache is newer than the source clip', () {
      final src = touch('stand.mp4');
      final cache = touch('stand.aipmat');
      src.setLastModifiedSync(DateTime(2020));
      cache.setLastModifiedSync(DateTime(2021));
      expect(needsPrepare(src, cache), isFalse);
    });
  });

  group('cachePathFor', () {
    test('is stable for the same source and lives under the cache dir', () {
      final src = touch('stand.mp4');
      final a = cachePathFor(dir.path, src, 'stand');
      expect(a, cachePathFor(dir.path, src, 'stand'));
      expect(a, startsWith(dir.path));
      expect(a, endsWith('.aipmat'));
      expect(a, contains('stand'));
    });

    test('differs for same-named clips from different folders', () {
      final other = Directory('${dir.path}${Platform.pathSeparator}other')..createSync();
      final a = touch('stand.mp4');
      final b = File('${other.path}${Platform.pathSeparator}stand.mp4')..writeAsStringSync('x');
      expect(cachePathFor(dir.path, a, 'stand'), isNot(cachePathFor(dir.path, b, 'stand')));
    });
  });
}
