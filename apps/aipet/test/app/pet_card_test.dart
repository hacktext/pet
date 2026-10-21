import 'dart:io';

import 'package:aipet/app/main_window/pet_card.dart';
import 'package:aipet/app/main_window/theme.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/domain/paid_character.dart';
import 'package:aipet/domain/pet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final _pet = Pet(
  id: 'builtin-gold',
  name: '金毛',
  species: Species.dog,
  origin: PetOrigin.builtin,
  blurb: '温柔的大暖男，走到哪跟到哪',
  dir: Directory('C:\\nowhere'),
  cover: 'cover.png',
  actions: const ['stand'],
);

final _longNamePet = Pet(
  id: 'builtin-long',
  name: '很长的名字很长的名字很长的名字很长的名字很长的名字很长的名字很长的名字很长的名字',
  species: Species.dog,
  origin: PetOrigin.builtin,
  blurb: '温柔的大暖男，走到哪跟到哪',
  dir: Directory('C:\\nowhere'),
  cover: 'cover.png',
  actions: const ['stand'],
);

void main() {
  Future<List<int>> pump(WidgetTester tester, CardStatus status, {Pet? pet, double width = 200, double height = 300}) async {
    final taps = <int>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, height: height, child: PetCard(pet: pet ?? _pet, status: status, onAdopt: () => taps.add(1))),
        ),
      ),
    ));
    return taps;
  }

  const cases = {
    CardStatus.adoptable: ('带它回家', true),
    CardStatus.switchable: ('换它陪我', true),
    CardStatus.companion: ('陪伴中', false),
    CardStatus.preparing: ('正在准备…', false),
    CardStatus.missing: ('素材缺失', false),
  };

  for (final MapEntry(key: status, value: (label, enabled)) in cases.entries) {
    testWidgets('$status shows "$label" and is ${enabled ? 'tappable' : 'disabled'}', (tester) async {
      final taps = await pump(tester, status);
      expect(find.text('金毛'), findsOneWidget);
      expect(find.text('温柔的大暖男，走到哪跟到哪'), findsOneWidget);
      expect(find.text(label), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed != null, enabled);
      await tester.tap(find.text(label));
      expect(taps.length, enabled ? 1 : 0);
    });
  }

  testWidgets('a character is TA, not 它; tags take the blurb\'s place', (tester) async {
    final girl = Pet(
      id: 'builtin-xiaoya',
      name: '小雅',
      species: Species.girl,
      origin: PetOrigin.builtin,
      blurb: '黑长直的温柔女孩',
      dir: Directory('C:\\nowhere'),
      cover: 'cover.png',
      actions: const ['stand'],
      tags: const ['温柔', '治愈'],
    );
    await pump(tester, CardStatus.adoptable, pet: girl);
    expect(find.text('带TA回家'), findsOneWidget);
    expect(find.text('温柔'), findsOneWidget);
    expect(find.text('治愈'), findsOneWidget);
    expect(find.text('黑长直的温柔女孩'), findsNothing);
    await pump(tester, CardStatus.switchable, pet: girl);
    expect(find.text('换TA陪我'), findsOneWidget);
  });

  testWidgets('preparing shows a spinner', (tester) async {
    await pump(tester, CardStatus.preparing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  test('palette matches the spec', () {
    // 2026-10-20: cream and coffee, apricot for the lead action.
    expect(AppColors.page, const Color(0xFFFFF8F0));
    expect(AppColors.card, const Color(0xFFFFFCF8));
    expect(AppColors.accent, const Color(0xFF7D4B32));
    expect(AppColors.orangeGradient.colors, const [Color(0xFFF3B07C), Color(0xFFE8894F)]);
    expect(AppColors.accentSoft, const Color(0xFFF8E8D9));
    expect(AppColors.text, const Color(0xFF5A3423));
    expect(AppColors.textMuted, const Color(0xFFA2826F));
    expect(buildAppTheme().scaffoldBackgroundColor, AppColors.page);
  });

  group('a paid character', () {
    final suwan = Pet(
      id: 'paid-suwan',
      name: '苏晚',
      species: Species.girl,
      origin: PetOrigin.paid,
      blurb: '',
      dir: Directory('C:\\nowhere'),
      cover: 'suwan.jpg',
      actions: const [],
      tags: const ['温柔'],
      voices: const [PetVoice(id: 'suwan', name: '苏晚')],
    );

    Future<({List<String> unlocks, List<String> downloads})> pumpPaid(WidgetTester tester, PaidState paid,
        {double? progress, CardStatus status = CardStatus.adoptable}) async {
      final unlocks = <String>[], downloads = <String>[];
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 330,
              child: PetCard(
                pet: suwan,
                status: status,
                onAdopt: () {},
                onVoice: (_) {},
                paid: paid,
                priceCents: 1990,
                onUnlock: () => unlocks.add('suwan'),
                onDownload: () => downloads.add('suwan'),
                progress: progress,
              ),
            ),
          ),
        ),
      ));
      return (unlocks: unlocks, downloads: downloads);
    }

    BoxDecoration badge(WidgetTester tester, String label) => tester
        .widget<Container>(find.ancestor(of: find.text(label), matching: find.byType(Container)).first)
        .decoration! as BoxDecoration;

    testWidgets('locked: 付费 on apricot, ¥19.90 解锁, no voice line', (tester) async {
      final taps = await pumpPaid(tester, PaidState.locked);
      expect(find.text('付费'), findsOneWidget);
      expect(badge(tester, '付费').gradient, AppColors.orangeGradient);
      expect(tester.widget<Text>(find.text('付费')).style!.color, Colors.white);
      expect(find.textContaining('声音：'), findsNothing);
      await tester.tap(find.text('¥19.90 解锁'));
      expect(taps.unlocks, ['suwan']);
      expect(taps.downloads, isEmpty);
    });

    testWidgets('owned: 已购 on coffee and 下载', (tester) async {
      final taps = await pumpPaid(tester, PaidState.owned);
      expect(find.text('已购'), findsOneWidget);
      expect(badge(tester, '已购').color, AppColors.accent);
      expect(find.text('付费'), findsNothing);
      await tester.tap(find.text('下载'));
      expect(taps.downloads, ['suwan']);
    });

    testWidgets('downloading: 下载中 42%, disabled', (tester) async {
      await pumpPaid(tester, PaidState.downloading, progress: 5 / 12);
      expect(find.text('已购'), findsOneWidget);
      expect(find.text('下载中 42%'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    });

    testWidgets('installed: 已购 and the usual buttons, with its voice line', (tester) async {
      await pumpPaid(tester, PaidState.installed);
      expect(find.text('已购'), findsOneWidget);
      expect(find.text('带TA回家'), findsOneWidget);
      expect(find.text('声音：静音'), findsOneWidget);
      await pumpPaid(tester, PaidState.installed, status: CardStatus.companion);
      expect(find.text('陪伴中'), findsOneWidget);
    });
  });

  testWidgets('a free pet wears no badge', (tester) async {
    await pump(tester, CardStatus.adoptable);
    expect(find.text('付费'), findsNothing);
    expect(find.text('已购'), findsNothing);
  });

  testWidgets('a long name stays on one line and leaves room for the cover', (tester) async {
    await pump(tester, CardStatus.adoptable, pet: _longNamePet, width: 182, height: 268);
    expect(tester.getSize(find.byType(Opacity)).height, greaterThan(120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing dims the cover, other states do not', (tester) async {
    // Test missing state
    await pump(tester, CardStatus.missing);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.35);

    // Test adoptable state
    await pump(tester, CardStatus.adoptable);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1.0);
  });
}
