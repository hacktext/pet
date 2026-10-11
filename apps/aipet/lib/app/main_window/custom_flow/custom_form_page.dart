import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../domain/custom_order.dart';
import '../../../domain/library_state.dart';
import '../theme.dart';
import 'custom_deps.dart';
import 'custom_form_model.dart';

/// 定制你的专属宠物: name, category, up to three photos, 下一步.
class CustomFormPage extends StatefulWidget {
  const CustomFormPage({super.key, required this.deps, required this.onSubmitted});

  final CustomDeps deps;
  final void Function(BuildContext context, CustomRequestInfo request) onSubmitted;

  @override
  State<CustomFormPage> createState() => _CustomFormPageState();
}

class _CustomFormPageState extends State<CustomFormPage> {
  late final CustomFormModel _m = CustomFormModel(widget.deps);
  final _name = TextEditingController();

  @override
  void dispose() {
    _m.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final r = await _m.submit();
    if (r != null && mounted) widget.onSubmitted(context, r);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('定制宠物'), centerTitle: true, backgroundColor: AppColors.page),
        body: ListenableBuilder(
          listenable: _m,
          builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
            const Text('定制你的专属宠物',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppColors.text)),
            const SizedBox(height: 6),
            const Text('上传名字与清晰照片，约1小时即可完成定制，完成后可在「我的」查看。',
                style: TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 16),
            _Card(children: [
              const _Heading(Icons.pets, '宠物名字'),
              TextField(
                controller: _name,
                enabled: !_m.busy,
                onChanged: _m.setName,
                decoration: InputDecoration(
                  hintText: '请输入名字（1–$kNameMax 个字）',
                  errorText: _m.nameError,
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Text('${_m.nameLength}/$kNameMax', style: const TextStyle(color: AppColors.textMuted)),
              ),
            ]),
            const SizedBox(height: 12),
            _Card(children: [
              const _Heading(Icons.category_outlined, '宠物类别'),
              Wrap(spacing: 8, children: [
                for (final g in Group.values)
                  ChoiceChip(
                    label: _SoonLabel(g.label, open: isGroupOpen(g)),
                    selected: _m.group == g,
                    selectedColor: AppColors.accentSoft,
                    onSelected: _m.busy || !isGroupOpen(g) ? null : (_) => _m.setGroup(g),
                  ),
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (final c in _m.group.categories)
                  if (c.species != null)
                    ChoiceChip(
                      label: _SoonLabel(c.label, open: isOpenForCustom(c)),
                      selected: _m.category == c,
                      selectedColor: AppColors.accentSoft,
                      onSelected: _m.busy || !isOpenForCustom(c) ? null : (_) => _m.setCategory(c),
                    ),
              ]),
              if (_m.categoryError != null) ...[
                const SizedBox(height: 6),
                Text(_m.categoryError!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ]),
            const SizedBox(height: 12),
            _Card(children: [
              const _Heading(Icons.add_a_photo_outlined, '上传宠物正面全身照'),
              _Photos(model: _m),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(16)),
                child: const Row(children: [
                  Icon(Icons.lightbulb_outline, color: AppColors.accent),
                  SizedBox(width: 8),
                  Expanded(child: Text('拍照小贴士：请选择正脸和全身照片，越清晰效果越好！')),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.accentSoft, borderRadius: BorderRadius.circular(24)),
              child: const Row(children: [
                Icon(Icons.alarm, color: AppColors.accent, size: 32),
                SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('预计1小时左右定制完成', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    Text('定制完成后即可在「我的定制」查看', style: TextStyle(color: AppColors.textMuted)),
                  ]),
                ),
              ]),
            ),
            if (_m.message != null) ...[
              const SizedBox(height: 12),
              Text(_m.message!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: _m.canSubmit ? _submit : null,
                child: Text(_m.progress ?? '下一步', style: const TextStyle(fontSize: 18)),
              ),
            ),
          ]),
        ),
      );
}

/// A chip's label, with 即将开放 after it when it cannot be picked yet.
class _SoonLabel extends StatelessWidget {
  const _SoonLabel(this.text, {required this.open});

  final String text;
  final bool open;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(text),
        if (!open) ...[
          const SizedBox(width: 4),
          const Text('即将开放', style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
        ],
      ]);
}

class _Photos extends StatelessWidget {
  const _Photos({required this.model});

  final CustomFormModel model;

  @override
  Widget build(BuildContext context) {
    final photos = model.photos;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (var i = 0; i < photos.length; i++)
        Stack(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                border: photos[i].failed ? Border.all(color: Colors.redAccent, width: 2) : null,
              ),
              child: Image.memory(
                Uint8List.fromList(photos[i].jpeg),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.image_outlined, size: 40, color: AppColors.textMuted),
              ),
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            child: IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.cancel, color: Colors.black54),
              onPressed: model.busy ? null : () => model.removePhoto(i),
            ),
          ),
        ]),
      if (photos.length < kMaxPhotos)
        InkWell(
          onTap: model.busy ? null : model.addPhotos,
          borderRadius: BorderRadius.circular(16),
          child: CustomPaint(
            painter: _DashedBorder(AppColors.textMuted.withValues(alpha: 0.5)),
            child: SizedBox(
              width: photos.isEmpty ? double.infinity : 100,
              height: photos.isEmpty ? 160 : 100,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.add_a_photo, size: 36, color: AppColors.accent),
                if (photos.isEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('点击上传照片', style: TextStyle(fontWeight: FontWeight.w700)),
                  const Text('最多 3 张正面清晰照片（JPG/PNG）',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
                ],
              ]),
            ),
          ),
        ),
    ]);
  }
}

/// A dashed rounded outline for the upload box.
class _DashedBorder extends CustomPainter {
  const _DashedBorder(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 10) {
        canvas.drawPath(m.extractPath(d, (d + 5).clamp(0, m.length)), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) => old.color != color;
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(24)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

class _Heading extends StatelessWidget {
  const _Heading(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(icon, color: AppColors.accent),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ]),
      );
}
