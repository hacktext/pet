import 'dart:io';

import 'package:aipet/app/main_window/pet_card.dart';
import 'package:aipet/app/main_window/theme.dart';
import 'package:aipet/domain/library_state.dart';
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
    // The 2026-10-19 library redesign: warm off-white, ink-black actions.
    expect(AppColors.page, const Color(0xFFF7F5F2));
    expect(AppColors.card, const Color(0xFFFFFFFF));
    expect(AppColors.accent, const Color(0xFF333333));
    expect(AppColors.accentSoft, const Color(0xFFEFEBE6));
    expect(AppColors.text, const Color(0xFF333333));
    expect(AppColors.textMuted, const Color(0xFF8A847E));
    expect(buildAppTheme().scaffoldBackgroundColor, AppColors.page);
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
