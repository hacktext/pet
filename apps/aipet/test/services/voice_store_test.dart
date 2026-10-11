import 'dart:io';

import 'package:aipet/services/voice_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late VoiceStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('voice_');
    store = VoiceStore(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('nothing chosen yet', () => expect(store.choice('builtin-xiaoya'), isNull));

  test('a choice per pet survives a new store, off included', () {
    store.choose('builtin-xiaoya', 'vivi');
    store.choose('builtin-other', kVoiceOff);
    final again = VoiceStore(root);
    expect(again.choice('builtin-xiaoya'), 'vivi');
    expect(again.choice('builtin-other'), kVoiceOff);
    expect(root.listSync().map((e) => e.uri.pathSegments.last), ['voice.json']);
  });

  test('an unreadable file is a fresh start, not a crash', () {
    File('${root.path}${Platform.pathSeparator}voice.json').writeAsStringSync('{nope');
    expect(VoiceStore(root).choice('builtin-xiaoya'), isNull);
  });

  test('all is a copy; replaceAll swaps every choice and is saved', () {
    store.choose('a', 'x');
    store.all.clear();
    expect(store.all, {'a': 'x'});
    store.replaceAll({'b': kVoiceOff});
    expect(store.choice('a'), isNull);
    expect(VoiceStore(root).all, {'b': kVoiceOff});
  });
}
