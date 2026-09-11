import 'dart:convert';
import 'dart:io';

import 'package:aipet/domain/pet.dart';
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

  test('blurb is optional', () {
    final j = valid()..remove('blurb');
    expect(parsePet(jsonEncode(j), dir).blurb, '');
  });

  final broken = <String, Map<String, Object?> Function()>{
    'not json': () => {},
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
    expect(labelFor('backflip'), 'backflip');
  });
}
