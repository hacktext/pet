import 'dart:convert';
import 'dart:io';

import 'package:aipet/domain/pet.dart';
import 'package:aipet/domain/walker.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> valid() => {
      'schema': 1,
      'id': 'builtin-gold',
      'name': '金毛',
      'species': 'dog',
      'origin': 'builtin',
      'blurb': '温柔的大暖男，走到哪跟到哪',
      'cover': 'cover.png',
      'actions': ['stand', 'walk', 'sleep', 'lick_paw', 'act_cute'],
    };

void main() {
  final dir = Directory('C:\\pets\\builtin-gold');

  test('parses a valid pet.json', () {
    final p = parsePet(jsonEncode(valid()), dir);
    expect(p.id, 'builtin-gold');
    expect(p.name, '金毛');
    expect(p.species, Species.dog);
    expect(p.origin, PetOrigin.builtin);
    expect(p.blurb, '温柔的大暖男，走到哪跟到哪');
    expect(p.actions, ['stand', 'walk', 'sleep', 'lick_paw', 'act_cute']);
    expect(p.actionFile('walk').path, 'C:\\pets\\builtin-gold\\walk.mp4');
    expect(p.coverFile.path, 'C:\\pets\\builtin-gold\\cover.png');
  });

  test('card and tags are optional; tags keep their order, at most three', () {
    final plain = parsePet(jsonEncode(valid()), dir);
    expect(plain.card, isNull);
    expect(plain.cardFile, isNull);
    expect(plain.tags, isEmpty);
    final p = parsePet(jsonEncode(valid()..['card'] = 'card.jpg'..['tags'] = ['温暖', '忠诚', '治愈', '第四个']), dir);
    expect(p.cardFile!.path, 'C:\\pets\\builtin-gold\\card.jpg');
    expect(p.tags, ['温暖', '忠诚', '治愈']);
  });

  for (final bad in <Object?>['../card.jpg', 'a/card.jpg', '', 3]) {
    test('rejects card $bad', () {
      expect(() => parsePet(jsonEncode(valid()..['card'] = bad), dir), throwsFormatException);
    });
  }

  for (final bad in <Object?>['温暖', [1], ['  ']]) {
    test('rejects tags $bad', () {
      expect(() => parsePet(jsonEncode(valid()..['tags'] = bad), dir), throwsFormatException);
    });
  }

  test('blurb is optional', () {
    final j = valid()..remove('blurb');
    expect(parsePet(jsonEncode(j), dir).blurb, '');
  });

  test('walkFacing is read and defaults to right', () {
    expect(parsePet(jsonEncode(valid()), dir).walkFacing, Facing.right);
    expect(parsePet(jsonEncode(valid()..['walkFacing'] = 'left'), dir).walkFacing, Facing.left);
    expect(parsePet(jsonEncode(valid()..['walkFacing'] = 'right'), dir).walkFacing, Facing.right);
  });

  test('voices are optional and read in order', () {
    expect(parsePet(jsonEncode(valid()), dir).voices, isEmpty);
    final j = valid()
      ..['voices'] = [
        {'id': 'xiaoya', 'name': '温柔小雅'},
        {'id': 'vivi', 'name': '元气 Vivi'},
      ];
    final p = parsePet(jsonEncode(j), dir);
    expect([for (final v in p.voices) '${v.id}:${v.name}'], ['xiaoya:温柔小雅', 'vivi:元气 Vivi']);
  });

  test("voiceLines are the voice's <action>-<n>.wav files, sorted; none for a missing folder", () {
    final tmp = Directory.systemTemp.createTempSync('pet_voices_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final p = parsePet(jsonEncode(valid()..['voices'] = [{'id': 'xiaoya', 'name': '温柔小雅'}]), tmp);
    final d = Directory('${tmp.path}\\voices\\xiaoya')..createSync(recursive: true);
    for (final f in ['act_coy-2.wav', 'act_coy-1.wav', 'talk-1.wav', 'act_coy_x-1.wav', 'act_coy-1.mp3']) {
      File('${d.path}\\$f').writeAsBytesSync([0]);
    }
    expect([for (final f in p.voiceLines('xiaoya', 'act_coy')) f.uri.pathSegments.last], ['act_coy-1.wav', 'act_coy-2.wav']);
    expect(p.voiceLines('xiaoya', 'dance'), isEmpty);
    expect(p.voiceLines('nobody', 'talk'), isEmpty);
  });

  final broken = <String, Map<String, Object?> Function()>{
    'voices not a list': () => valid()..['voices'] = 'xiaoya',
    'voice id with a path': () => valid()..['voices'] = [{'id': '..\\x', 'name': 'x'}],
    'voice without a name': () => valid()..['voices'] = [{'id': 'x'}],
    'duplicate voice': () => valid()..['voices'] = [{'id': 'x', 'name': 'a'}, {'id': 'x', 'name': 'b'}],
    'not json': () => {},
    'walkFacing up': () => valid()..['walkFacing'] = 'up',
    'schema 2': () => valid()..['schema'] = 2,
    'missing id': () => valid()..remove('id'),
    'id with spaces': () => valid()..['id'] = 'Gold Dog',
    'empty name': () => valid()..['name'] = '  ',
    'unknown species': () => valid()..['species'] = 'dragon',
    'unknown origin': () => valid()..['origin'] = 'stolen',
    'cover with a path': () => valid()..['cover'] = '..\\x.png',
    'actions not a list': () => valid()..['actions'] = 'stand',
    'action with a dash': () => valid()..['actions'] = ['stand', 'lick-paw'],
    'duplicate action': () => valid()..['actions'] = ['stand', 'walk', 'walk'],
    'no stand': () => valid()..['actions'] = ['walk', 'sleep'],
  };
  for (final e in broken.entries) {
    test('rejects ${e.key}', () {
      final text = e.key == 'not json' ? '{nope' : jsonEncode(e.value());
      expect(() => parsePet(text, dir), throwsFormatException);
    });
  }

  test('isComplete needs the cover and every listed clip', () {
    final tmp = Directory.systemTemp.createTempSync('pet_complete_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final p = parsePet(jsonEncode(valid()), tmp);
    expect(p.isComplete, isFalse);
    p.coverFile.writeAsBytesSync([0]);
    for (final k in p.actions) {
      p.actionFile(k).writeAsBytesSync([0]);
    }
    expect(p.isComplete, isTrue);
    p.actionFile('sleep').deleteSync();
    expect(p.isComplete, isFalse);
  });

  test('loop policy follows the parent spec 4.6', () {
    for (final k in ['stand', 'walk', 'sleep']) {
      expect(isLooping(k), isTrue, reason: k);
    }
    for (final k in ['lick_paw', 'act_cute', 'feed', 'unknown']) {
      expect(isLooping(k), isFalse, reason: k);
    }
    expect(kIdleAction, 'stand');
  });

  test('Chinese labels with key fallback', () {
    expect(labelFor('stand'), '待机');
    expect(labelFor('lick_paw'), '舔爪子');
    expect(labelFor('act_cute'), '卖萌');
    expect(labelFor('act_coy'), '撒娇');
    expect(labelFor('dance'), '跳舞');
    expect(labelFor('talk'), '说话');
    expect(labelFor('backflip'), 'backflip');
  });
}
