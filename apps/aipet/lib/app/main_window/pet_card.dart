import 'package:flutter/material.dart';

import '../../domain/library_state.dart';
import '../../domain/pet.dart';
import 'theme.dart';

/// Height of the voice line a speaking character's card adds.
const double kVoiceLineHeight = 30;

/// One pet in the plaza / 我的 grid, in one of the five states of spec 5:
/// its photo, name, tags and one button; a character that speaks also gets a
/// voice line (静音 until a voice is chosen).
class PetCard extends StatelessWidget {
  const PetCard(
      {super.key, required this.pet, required this.status, required this.onAdopt, this.voice, this.onVoice});

  final Pet pet;
  final CardStatus status;
  final VoidCallback onAdopt;

  /// The voice it speaks in; null for 静音.
  final String? voice;

  /// A voice picked on the card, null for 静音; null hides the line.
  final ValueChanged<String?>? onVoice;

  bool get _speaks => pet.voices.isNotEmpty && onVoice != null;

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
              if (_speaks) SizedBox(height: kVoiceLineHeight, child: _voiceLine()),
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

  static const _off = '';

  Widget _voiceLine() {
    final name = [for (final v in pet.voices) if (v.id == voice) v.name].firstOrNull;
    return Align(
      alignment: Alignment.bottomLeft,
      child: PopupMenuButton<String>(
        key: Key('voice-${pet.id}'),
        tooltip: '声音',
        position: PopupMenuPosition.under,
        onSelected: (v) => onVoice!(v == _off ? null : v),
        itemBuilder: (_) => [
          CheckedPopupMenuItem(value: _off, checked: name == null, child: const Text('静音')),
          for (final v in pet.voices) CheckedPopupMenuItem(value: v.id, checked: v.id == voice, child: Text(v.name)),
        ],
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(name == null ? Icons.volume_off_outlined : Icons.volume_up_outlined,
              size: 16, color: name == null ? AppColors.textMuted : AppColors.orange),
          const SizedBox(width: 4),
          Text('声音：${name ?? '静音'}',
              style: TextStyle(fontSize: 12, color: name == null ? AppColors.textMuted : AppColors.text)),
          const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.textMuted),
        ]),
      ),
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
