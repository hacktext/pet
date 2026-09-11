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

void main() {
  Future<List<int>> pump(WidgetTester tester, CardStatus status) async {
    final taps = <int>[];
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 200, height: 300, child: PetCard(pet: _pet, status: status, onAdopt: () => taps.add(1))),
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

  testWidgets('preparing shows a spinner', (tester) async {
    await pump(tester, CardStatus.preparing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  test('palette matches the spec', () {
    expect(AppColors.page, const Color(0xFFFFF8F0));
    expect(AppColors.card, const Color(0xFFFFFFFF));
    expect(AppColors.accent, const Color(0xFFF08A3C));
    expect(AppColors.accentSoft, const Color(0xFFFDEBD9));
    expect(AppColors.text, const Color(0xFF3D2B1F));
    expect(AppColors.textMuted, const Color(0xFF8A6E5A));
    expect(buildAppTheme().scaffoldBackgroundColor, AppColors.page);
  });
}
