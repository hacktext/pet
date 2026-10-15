import 'package:aipet/app/pet_window/pet_menu.dart';
import 'package:aipet/domain/pet.dart';
import 'package:aipet/domain/pet_size.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The seven actions the acceptance run's corgi had -- the set that outgrew
/// the window.
const _actions = ['stand', 'walk', 'run', 'sleep', 'feed', 'play', 'spin'];

/// The pet window (spec 3.1). showMenu lays out inside it, so a level that
/// grew too tall can only scroll, and whatever is at the bottom goes with it.
const _window = Size(360, 360);

void main() {
  late List<PetMenuPick?> picked;

  Future<void> open(WidgetTester t,
      {List<String> actions = _actions,
      String? current = 'stand',
      List<PetVoice> voices = const [],
      String? voice,
      PetSize size = PetSize.fallback}) async {
    t.view.physicalSize = _window;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    picked = [];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async => picked.add(
                await showPetMenu(ctx,
                    at: const Offset(180, 180),
                    actions: actions,
                    currentAction: current,
                    voices: voices,
                    currentVoice: voice,
                    currentSize: size)),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ));
    await t.tapAt(const Offset(180, 180));
    await t.pumpAndSettle();
  }

  Future<void> pick(WidgetTester t, Finder entry) async {
    await t.tap(entry);
    await t.pumpAndSettle();
  }

  /// How far the open level can scroll; anything above zero is the defect.
  double slack(WidgetTester t) => t.state<ScrollableState>(find.byType(Scrollable)).position.maxScrollExtent;

  Finder action(String key) => find.byKey(Key('pet-menu-action-$key'));

  testWidgets('the top level is 动作, 大小, 打开宠物库 and 退出, with no action on it', (t) async {
    await open(t);
    for (final s in ['动作', '大小', '打开宠物库', '退出']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    for (final a in _actions) {
      expect(find.text(labelFor(a)), findsNothing, reason: a);
    }
  });

  testWidgets('with no pet the top level is 大小 and the two commands', (t) async {
    await open(t, actions: const [], current: null);
    expect(find.text('动作'), findsNothing);
    expect(find.text('大小'), findsOneWidget);
    expect(find.text('打开宠物库'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
  });

  testWidgets('动作 opens every action of the pet, the current one ticked', (t) async {
    await open(t);
    await pick(t, find.text('动作'));
    for (final a in _actions) {
      expect(find.text(labelFor(a)), findsOneWidget, reason: a);
    }
    expect(find.text('打开宠物库'), findsNothing);
    expect(find.byIcon(Icons.done), findsOneWidget);
    expect(find.descendant(of: action('stand'), matching: find.byIcon(Icons.done)), findsOneWidget);
  });

  testWidgets('neither level needs a scroll inside the pet window', (t) async {
    await open(t);
    expect(slack(t), 0, reason: 'top level');
    await pick(t, find.text('动作'));
    expect(slack(t), 0, reason: 'actions');
    for (final a in _actions) {
      // 36 and not a pixel more: an entry that quietly grew is what puts the
      // level over the window's height again.
      expect(t.getSize(action(a)).height, kPetMenuItemHeight, reason: a);
      final r = t.getRect(action(a));
      expect(r.top, greaterThanOrEqualTo(0), reason: a);
      expect(r.bottom, lessThanOrEqualTo(_window.height), reason: a);
    }
  });

  testWidgets('picking an action reports it', (t) async {
    await open(t);
    await pick(t, find.text('动作'));
    await pick(t, action('spin')); // the last one: the first to fall below the fold
    expect(picked, [isA<PetMenuAction>().having((p) => p.action, 'action', 'spin')]);
  });

  testWidgets('打开宠物库 and 退出 report themselves', (t) async {
    await open(t);
    await pick(t, find.text('打开宠物库'));
    expect(picked, [isA<PetMenuOpenLibrary>()]);
    await open(t);
    await pick(t, find.text('退出'));
    expect(picked, [isA<PetMenuQuit>()]);
  });

  const voices = [PetVoice(id: 'xiaoya', name: '温柔小雅'), PetVoice(id: 'vivi', name: '元气 Vivi')];

  testWidgets('no 声音 for a pet without voices', (t) async {
    await open(t);
    expect(find.text('声音'), findsNothing);
  });

  testWidgets('声音 lists the voices and 静音, the current one ticked, and reports the pick', (t) async {
    await open(t, voices: voices, voice: 'vivi');
    expect(slack(t), 0, reason: 'top level with 声音');
    await pick(t, find.text('声音'));
    for (final s in ['温柔小雅', '元气 Vivi', '静音']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(find.descendant(of: find.byKey(const Key('pet-menu-voice-vivi')), matching: find.byIcon(Icons.done)),
        findsOneWidget);
    await pick(t, find.text('温柔小雅'));
    expect(picked, [isA<PetMenuVoice>().having((p) => p.voice, 'voice', 'xiaoya')]);

    await open(t, voices: voices, voice: null);
    await pick(t, find.text('声音'));
    expect(find.descendant(of: find.byKey(const Key('pet-menu-voice-off')), matching: find.byIcon(Icons.done)),
        findsOneWidget);
    await pick(t, find.text('静音'));
    expect(picked, [isA<PetMenuVoice>().having((p) => p.voice, 'voice', isNull)]);
  });

  testWidgets('大小 lists 大, 中 and 小, the current one ticked, and reports the pick', (t) async {
    await open(t, size: PetSize.medium);
    await pick(t, find.text('大小'));
    expect(slack(t), 0, reason: 'sizes');
    final labels = [for (final s in ['large', 'medium', 'small']) t.getRect(find.byKey(Key('pet-menu-size-$s'))).top];
    expect(labels, orderedEquals([...labels]..sort()), reason: '大 on top');
    expect(find.descendant(of: find.byKey(const Key('pet-menu-size-medium')), matching: find.byIcon(Icons.done)),
        findsOneWidget);
    expect(find.byIcon(Icons.done), findsOneWidget);
    await pick(t, find.text('小'));
    expect(picked, [isA<PetMenuSize>().having((p) => p.size, 'size', PetSize.small)]);
  });

  testWidgets('the fullest top level still fits without a scroll', (t) async {
    await open(t, voices: voices);
    for (final s in ['动作', '声音', '大小', '打开宠物库', '退出']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    expect(slack(t), 0);
  });

  testWidgets('dismissing either level reports nothing', (t) async {
    await open(t);
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    expect(picked, [null]);
    await open(t);
    await pick(t, find.text('动作'));
    await t.tapAt(const Offset(4, 4));
    await t.pumpAndSettle();
    expect(picked, [null]);
  });
}
