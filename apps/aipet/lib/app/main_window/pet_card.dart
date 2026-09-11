import 'package:flutter/material.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import 'theme.dart';

/// One pet in the plaza / 我的 grid, in one of the five states of spec 5.
class PetCard extends StatelessWidget {
  const PetCard({super.key, required this.pet, required this.status, required this.onAdopt});

  final Pet pet;
  final CardStatus status;
  final VoidCallback onAdopt;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(14)),
                child: Opacity(
                  opacity: status == CardStatus.missing ? 0.35 : 1,
                  child: Image.file(
                    pet.coverFile,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Icon(Icons.pets, size: 48, color: AppColors.textMuted),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(pet.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppColors.text)),
            Text(pet.blurb,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: _button()),
          ],
        ),
      ),
    );
  }

  Widget _button() => switch (status) {
        CardStatus.adoptable => FilledButton(onPressed: onAdopt, child: const Text('带它回家')),
        CardStatus.switchable => FilledButton.tonal(onPressed: onAdopt, child: const Text('换它陪我')),
        CardStatus.companion => const FilledButton.tonal(onPressed: null, child: Text('陪伴中')),
        CardStatus.preparing => const FilledButton.tonal(
            onPressed: null,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('正在准备…'),
            ]),
          ),
        CardStatus.missing => const FilledButton.tonal(onPressed: null, child: Text('素材缺失')),
      };
}
