import 'package:flutter/material.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import 'theme.dart';

/// One pet in the plaza / 我的 grid, in one of the five states of spec 5:
/// its photo, name, tags and one button.
class PetCard extends StatelessWidget {
  const PetCard({super.key, required this.pet, required this.status, required this.onAdopt});

  final Pet pet;
  final CardStatus status;
  final VoidCallback onAdopt;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.line),
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Opacity(opacity: status == CardStatus.missing ? 0.35 : 1, child: _photo()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pet.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.text)),
              const SizedBox(height: 6),
              SizedBox(height: 24, child: _tags()),
              const SizedBox(height: 10),
              SizedBox(width: double.infinity, height: 40, child: _button()),
              const SizedBox(height: 4),
            ]),
          ),
        ],
      ),
    );
  }

  /// The close-up photo when the pet has one; otherwise its cutout cover on
  /// a soft ground (custom pets).
  Widget _photo() {
    Widget fallback(_, _, _) => const Center(child: Icon(Icons.pets, size: 48, color: AppColors.textMuted));
    final card = pet.cardFile;
    if (card != null) {
      return SizedBox.expand(
          child: Image.file(card, fit: BoxFit.cover, cacheWidth: 640, errorBuilder: fallback));
    }
    return Container(
      color: AppColors.accentSoft,
      padding: const EdgeInsets.all(12),
      child: SizedBox.expand(child: Image.file(pet.coverFile, fit: BoxFit.contain, errorBuilder: fallback)),
    );
  }

  /// Its tags, or the blurb for a pet without any.
  Widget _tags() {
    if (pet.tags.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(pet.blurb,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
      );
    }
    return ClipRect(
      child: Wrap(spacing: 6, clipBehavior: Clip.hardEdge, children: [
        for (final t in pet.tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(12)),
            child: Text(t, style: const TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.3)),
          ),
      ]),
    );
  }

  Widget _button() {
    final it = pet.species.isCharacter ? 'TA' : '它';
    return switch (status) {
      CardStatus.adoptable => FilledButton(onPressed: onAdopt, child: Text('带$it回家')),
      CardStatus.switchable => FilledButton(onPressed: onAdopt, child: Text('换$it陪我')),
      CardStatus.companion => const FilledButton(onPressed: null, child: Text('陪伴中')),
      CardStatus.preparing => const FilledButton(
          onPressed: null,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('正在准备…'),
          ]),
        ),
      CardStatus.missing => const FilledButton(onPressed: null, child: Text('素材缺失')),
    };
  }
}
