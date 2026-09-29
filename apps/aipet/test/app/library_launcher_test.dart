import 'dart:async';

import 'package:aipet/app/pet_window/library_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> windows; // ids desktop_multi_window would list as open
  late List<String> calls;
  late int created;
  Completer<void>? createGate;
  Object? createFails;
  late LibraryLauncher launcher;

  setUp(() {
    windows = [];
    calls = [];
    created = 0;
    createGate = null;
    createFails = null;
    launcher = LibraryLauncher(
      create: () async {
        calls.add('create');
        if (createGate != null) await createGate!.future;
        if (createFails != null) throw createFails!;
        final id = 'w${++created}';
        windows.add(id);
        return id;
      },
      listOpenWindowIds: () async => List.of(windows),
      show: (id) async => calls.add('show $id'),
      hide: (id) async => calls.add('hide $id'),
    );
  });

  test('hideIfOpen hides the library only while it exists', () async {
    await launcher.hideIfOpen(); // never opened
    await launcher.open();
    await launcher.hideIfOpen();
    windows.clear(); // destroyed
    await launcher.hideIfOpen();
    expect(calls, ['create', 'show w1', 'hide w1']);
  });

  test('a tray double-click (two concurrent opens) creates one window', () async {
    createGate = Completer<void>();
    final first = launcher.open();
    final second = launcher.open();
    await Future<void>.delayed(Duration.zero);
    createGate!.complete();
    await Future.wait([first, second]);
    expect(calls, ['create', 'show w1']);
    expect(windows, ['w1']);
  });

  test('open() while the library is open only shows it', () async {
    await launcher.open();
    await launcher.open();
    expect(calls, ['create', 'show w1', 'show w1']);
  });

  test('open() after the library window was destroyed creates it again', () async {
    await launcher.open();
    windows.clear(); // the user's × destroyed it
    await launcher.open();
    expect(calls, ['create', 'show w1', 'create', 'show w2']);
  });

  test('a failed open does not block the next one', () async {
    createFails = Exception('no window');
    await expectLater(launcher.open(), throwsException);
    createFails = null;
    await launcher.open();
    expect(calls, ['create', 'create', 'show w1']);
  });
}
