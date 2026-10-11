import 'dart:async';

import 'package:aipet/domain/account_view.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_account.dart';
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

  test('a channel failure on getState is a BridgeTimeout', () async {
    petEnd.failWith = Exception('engine gone');
    await expectLater(
        main.getState(), throwsA(isA<BridgeTimeout>().having((e) => e.stage, 'stage', 'getState')));
  });

  test('a non-AdoptError from onAdopt comes back as prepare_failed', () async {
    adoptImpl = (id) async {
      await pet.pushState(state.preparing(id));
      throw StateError('bug');
    };
    await expectLater(
        main.adopt('b'), throwsA(isA<AdoptError>().having((e) => e.code, 'code', 'prepare_failed')));
  });

  test('an early channel failure on adopt is a BridgeTimeout, not a raw error', () async {
    petEnd.failWith = Exception('engine gone');
    await expectLater(main.adopt('b'), throwsA(isA<BridgeTimeout>().having((e) => e.stage, 'stage', 'ack')));
  });

  test('dispose while adopt waits for the ack is a BridgeTimeout', () async {
    adoptImpl = (id) => Completer<void>().future; // never completes, never pushes
    final expectation =
        expectLater(main.adopt('b'), throwsA(isA<BridgeTimeout>().having((e) => e.stage, 'stage', 'ack')));
    await main.dispose();
    await expectation;
  });

  group('account', () {
    late FakeAccount account;

    setUp(() {
      account = FakeAccount();
      pet = PetWindowBridge(petEnd,
          state: () => state,
          onAdopt: (id) => adoptImpl(id),
          onMainWindowClosing: () async {},
          onQuit: () async {},
          account: account)
        ..start();
    });

    test('getAccount, and pushes arrive on accounts', () async {
      account.view = const AccountView(phoneMasked: '138****1234', name: 'n');
      expect(await main.getAccount(), account.view);
      final seen = <AccountView>[];
      main.accounts.listen(seen.add);
      await pet.pushAccount(AccountView.signedOut);
      expect(seen, [AccountView.signedOut]);
    });

    test('requests reach the pet window and its replies come back', () async {
      final r = await main.sendSms('13800138000');
      expect(r.ok, isFalse);
      expect(r.message, '发送太频繁');
      expect(r.retryAfter, 42);
      expect((await main.login('13800138000', '123456')).ok, isTrue);
      expect((await main.syncNow()).ok, isTrue);
      await main.logout();
      expect(account.calls, ['sms 13800138000', 'login 13800138000 123456', 'sync', 'logout']);
    });

    test('a pet window that throws or never answers is a failed reply, not an exception', () async {
      account.fail = true;
      expect((await main.login('1', '2')).message, '操作失败，请重试');
      petEnd.silent = true;
      final m = MainWindowBridge(mainEnd,
          ackTimeout: const Duration(milliseconds: 50), accountTimeout: const Duration(milliseconds: 50));
      expect((await m.syncNow()).message, '操作超时，请重试');
      expect(await m.getAccount(), isNull);
      await m.dispose();
    });

    test('without an account handler the pet window answers signed out', () async {
      pet = PetWindowBridge(petEnd,
          state: () => state, onAdopt: (id) async {}, onMainWindowClosing: () async {}, onQuit: () async {})
        ..start();
      expect(await main.getAccount(), AccountView.signedOut);
      expect((await main.syncNow()).ok, isFalse);
    });
  });
}
