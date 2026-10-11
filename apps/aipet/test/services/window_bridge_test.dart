import 'dart:async';

import 'package:aipet/domain/account_view.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/window_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_account.dart';
import '../support/fake_transport.dart';

class _ScriptedTransport implements BridgeTransport {
  _ScriptedTransport(this._onInvoke);
  final Future<Object?> Function(String, Object?) _onInvoke;
  BridgeHandler? handler;

  @override
  Future<Object?> invoke(String method, [Object? args]) => _onInvoke(method, args);

  @override
  void setHandler(BridgeHandler? h) => handler = h;
}

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

  test('a ready pet reaches an open library at once and is not kept', () async {
    final seen = <List<ReadyPet>>[];
    main.readyPets.listen(seen.add);
    await pet.pushReady([const ReadyPet(petId: 'custom-7', name: '豆豆')]);
    expect(seen.single, [const ReadyPet(petId: 'custom-7', name: '豆豆')]);
    expect(await main.takeReady(), isEmpty);
  });

  test('with no library listening, ready pets wait until it asks', () async {
    mainEnd.setHandler(null); // the library window is not running
    await pet.pushReady([const ReadyPet(petId: 'custom-7', name: '豆豆')]);
    await pet.pushReady([const ReadyPet(petId: 'custom-8', name: '旺财')]);
    main.start();
    expect((await main.takeReady()).map((p) => p.petId), ['custom-7', 'custom-8']);
    expect(await main.takeReady(), isEmpty);
  });

  test('refreshCustom reaches the pet window', () async {
    var refreshes = 0;
    pet = PetWindowBridge(petEnd,
        state: () => state,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async {},
        onQuit: () async {},
        onRefreshCustom: () async => refreshes++)
      ..start();
    main.refreshCustom();
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, 1);
  });

  test('overlapping pushes: a failed later push is not wiped by an earlier success', () async {
    final first = Completer<void>();
    var calls = 0;
    final t = _ScriptedTransport((m, a) async {
      if (++calls == 1) {
        await first.future;
        return null;
      }
      throw StateError('library gone');
    });
    final p = PetWindowBridge(t,
        state: () => state, onAdopt: (id) async {}, onMainWindowClosing: () async {}, onQuit: () async {})
      ..start();
    final a = p.pushReady([const ReadyPet(petId: 'custom-1', name: 'a')]);
    await Future<void>.delayed(Duration.zero);
    await p.pushReady([const ReadyPet(petId: 'custom-2', name: 'b')]); // fails
    first.complete();
    await a; // succeeds
    final r = await t.handler!('takeReady', null) as Map;
    expect((r['pets'] as List).map((x) => (x as Map)['petId']), ['custom-2']);
  });

  test('a ready list with some garbage keeps the valid pets', () {
    expect(
        ReadyPet.listFrom({
          'pets': [
            'x',
            {'petId': 'custom-7', 'name': '豆豆'},
            {'petId': 1},
          ]
        }),
        [const ReadyPet(petId: 'custom-7', name: '豆豆')]);
  });

  test('an empty ready list is not emitted', () async {
    final seen = <List<ReadyPet>>[];
    main.readyPets.listen(seen.add);
    await petEnd.invoke(BridgeMethods.petsReady, {'pets': <Object?>[]});
    await Future<void>.delayed(Duration.zero);
    expect(seen, isEmpty);
  });

  test('a throwing onRefreshCustom does not escape', () async {
    pet = PetWindowBridge(petEnd,
        state: () => state,
        onAdopt: (id) => adoptImpl(id),
        onMainWindowClosing: () async {},
        onQuit: () async {},
        onRefreshCustom: () async => throw StateError('boom'))
      ..start();
    main.refreshCustom();
    await Future<void>.delayed(Duration.zero);
  });

  test('a garbled ready list is just empty', () {
    expect(ReadyPet.listFrom(null), isEmpty);
    expect(ReadyPet.listFrom({'pets': ['x', {'petId': 1}]}), isEmpty);
  });
}
