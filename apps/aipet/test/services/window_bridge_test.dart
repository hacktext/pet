import 'dart:async';

import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_transport.dart';

void main() {
  late FakeTransport petEnd, mainEnd;
  late LibraryState state;
  late PetWindowBridge pet;
  late MainWindowBridge main;
  late Future<void> Function(String) adoptImpl;
  var closing = 0, quits = 0;

  setUp(() {
    (petEnd, mainEnd) = FakeTransport.pair();
    state = const LibraryState(currentPetId: 'a', adoptedPetIds: ['a']);
    closing = 0;
    quits = 0;
    adoptImpl = (id) async {};
    pet = PetWindowBridge(petEnd,
        state: () => state,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async => closing++,
        onQuit: () async => quits++)
      ..start();
    main = MainWindowBridge(mainEnd,
        ackTimeout: const Duration(milliseconds: 50), adoptTimeout: const Duration(milliseconds: 500))
      ..start();
  });
  tearDown(() => main.dispose());

  test('getState returns what the pet window holds', () async {
    expect(await main.getState(), state);
  });

  test('adopt: ack via stateChanged, then success', () async {
    final seen = <LibraryState>[];
    main.states.listen(seen.add);
    adoptImpl = (id) async {
      state = state.preparing(id);
      await pet.pushState(state);
      await Future<void>.delayed(const Duration(milliseconds: 100)); // longer than ackTimeout
      state = state.adopted(id);
      await pet.pushState(state);
    };
    await main.adopt('b');
    expect(seen.map((s) => s.preparingPetId), ['b', null]);
    expect(seen.last.currentPetId, 'b');
  });

  test('adopt failure comes back as AdoptError with its code', () async {
    adoptImpl = (id) async {
      await pet.pushState(state.preparing(id));
      throw const AdoptError('missing_assets', 'sleep.mp4');
    };
    await expectLater(
        main.adopt('b'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'missing_assets')));
  });

  test('no ack within the timeout is a BridgeTimeout(ack)', () async {
    adoptImpl = (id) => Completer<void>().future; // never pushes, never finishes
    await expectLater(main.adopt('b'), throwsA(isA<BridgeTimeout>().having((e) => e.stage, 'stage', 'ack')));
  });

  test('a hung pet window makes getState time out', () async {
    petEnd.silent = true;
    await expectLater(main.getState(), throwsA(isA<BridgeTimeout>()));
  });

  test('pushing state with no main window open is harmless', () async {
    mainEnd.setHandler(null);
    await pet.pushState(state); // must not throw
  });

  test('closing and quit reach the pet window', () async {
    await main.notifyClosing();
    main.quit();
    await Future<void>.delayed(Duration.zero);
    expect(closing, 1);
    expect(quits, 1);
  });
}
