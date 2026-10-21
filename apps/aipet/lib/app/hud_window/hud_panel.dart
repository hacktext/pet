import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/hud_layout.dart';
import '../../domain/pet.dart';
import '../../services/hud_bridge.dart';

/// The status panel (spec 2026-09-19 E 3.5), after the competitor's: name and
/// status, companion days and today's count, three numbers, then the pet's
/// buttons: one row of up to four, else a grid four wide (two rows fit; more
/// scroll with the wheel).
class HudPanel extends StatelessWidget {
  const HudPanel({super.key, required this.view, required this.onAction, required this.onClose});

  final HudView view;
  final void Function(String key) onAction;
  final VoidCallback onClose;

  /// The panel's own wording for the animal buttons; any other action reads
  /// as in the right-click menu.
  static const _labels = {'stand': '站立', 'walk': '行走', 'feed': '喂食', 'play': '玩耍'};
  static const _icons = {
    'stand': Icons.pets,
    'walk': Icons.directions_walk,
    'feed': Icons.rice_bowl,
    'play': Icons.sports_baseball,
    'act_coy': Icons.favorite,
    'dance': Icons.music_note,
    'talk': Icons.chat_bubble,
    'run': Icons.directions_run,
    'sleep': Icons.bedtime,
    'spin': Icons.autorenew,
    'lick_paw': Icons.clean_hands,
    'act_cute': Icons.emoji_emotions,
    'pet_head': Icons.front_hand,
  };
  static const _ink = Color(0xFF3D2B2B);
  static const _rose = Color(0xFFB2566B);
  static const _card = Color(0xFFFBEDEC);

  @override
  Widget build(BuildContext context) => Container(
        width: kHudSize.width,
        height: kHudSize.height,
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7F5),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFFF1D8D4)),
        ),
        child: Column(children: [
          Row(children: [
            _avatar(),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(view.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _ink)),
                Text(view.status, style: const TextStyle(fontSize: 12, color: _rose)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Text('陪伴 ${view.companionDays} 天', style: const TextStyle(fontSize: 12, color: _ink)),
                Text('今日互动 ${view.todayInteractions} 次', style: const TextStyle(fontSize: 11, color: _ink)),
              ]),
            ),
            IconButton(
              key: const Key('hud-close'),
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 20, color: _ink),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            _stat('亲密度', view.intimacy, const Color(0xFFF06292)),
            const SizedBox(width: 8),
            if (view.satiety case final satiety?) ...[
              _stat('饱食度', satiety, const Color(0xFFFFA726)),
              const SizedBox(width: 8),
            ],
            _stat('健康度', view.health, const Color(0xFF66BB6A)),
          ]),
          const SizedBox(height: 10),
          if (view.buttons.length <= 4)
            Row(children: [
              for (final (i, b) in view.buttons.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: _button(b)),
              ],
            ])
          else
            Expanded(
              child: GridView.count(
                key: const Key('hud-buttons'),
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.2,
                padding: EdgeInsets.zero,
                children: [for (final b in view.buttons) _button(b, compact: true)],
              ),
            ),
        ]),
      );

  Widget _avatar() => ClipOval(
        child: Container(
          width: 44,
          height: 44,
          color: _card,
          child: Image.file(File(view.cover),
              fit: BoxFit.cover, errorBuilder: (_, _, _) => const Icon(Icons.pets, color: _rose)),
        ),
      );

  Widget _stat(String label, int value, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(label, style: const TextStyle(fontSize: 12, color: _ink)),
              const Spacer(),
              Text('$value%', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: value / 100, minHeight: 5, color: color, backgroundColor: color.withValues(alpha: 0.18)),
            ),
          ]),
        ),
      );

  Widget _button(String key, {bool compact = false}) {
    final enabled = view.enabled.contains(key);
    final icon = Icon(_icons[key] ?? Icons.auto_awesome, size: compact ? 18 : 22, color: _rose);
    final label = Text(_labels[key] ?? labelFor(key),
        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: _ink));
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(compact ? 12 : 16),
        child: InkWell(
          key: Key('hud-button-$key'),
          borderRadius: BorderRadius.circular(compact ? 12 : 16),
          onTap: enabled ? () => onAction(key) : null,
          child: compact
              ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  icon,
                  const SizedBox(width: 4),
                  Flexible(child: label),
                ])
              : Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(children: [icon, const SizedBox(height: 2), label]),
                ),
        ),
      ),
    );
  }
}
