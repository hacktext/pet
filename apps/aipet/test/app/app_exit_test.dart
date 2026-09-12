import 'dart:async';

import 'package:aipet/app/pet_window/app_exit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> log;
  const failFast = Timeout(Duration(seconds: 5)); // a missing timeout must fail, not hang for 30 s

  Future<void> Function() step(String name) => () async => log.add(name);

  AppExit make({
    Future<void> Function()? hidePet,
    Future<void> Function()? disposePlayer,
    Duration timeout = const Duration(seconds: 2),
  }) =>
      AppExit(
        hide: [hidePet ?? step('hide pet'), step('hide library')],
        release: [disposePlayer ?? step('dispose player'), step('destroy tray')],
        destroy: step('destroy'),
        timeout: timeout,
      );

  setUp(() => log = []);

  test('both windows are hidden before anything is released or destroyed', () async {
    await make().quit();
    expect(log, ['hide pet', 'hide library', 'dispose player', 'destroy tray', 'destroy']);
  });

  test('a step that throws does not skip the other steps or the destroy', () async {
    await make(
      hidePet: () async => throw Exception('hide failed'),
      disposePlayer: () async => throw StateError('dispose failed'),
    ).quit();
    expect(log, ['hide library', 'destroy tray', 'destroy']);
  }, timeout: failFast);

  test('a step that never completes cannot hold up the destroy', () async {
    await make(disposePlayer: () => Completer<void>().future, timeout: const Duration(milliseconds: 50)).quit();
    expect(log.last, 'destroy');
    expect(log, contains('destroy tray'));
  }, timeout: failFast);

  test('a second quit while quitting does nothing', () async {
    final gate = Completer<void>();
    final exit = make(hidePet: () async {
      log.add('hide pet');
      await gate.future;
    });
    final first = exit.quit();
    await exit.quit();
    gate.complete();
    await first;
    expect(log.where((e) => e == 'destroy'), hasLength(1));
    expect(log.where((e) => e == 'hide pet'), hasLength(1));
  }, timeout: failFast);
}
