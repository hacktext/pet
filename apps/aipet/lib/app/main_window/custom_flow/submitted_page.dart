import 'package:flutter/material.dart';

import '../theme.dart';

class SubmittedPage extends StatelessWidget {
  const SubmittedPage({super.key, required this.onDone});

  final void Function(BuildContext context) onDone;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.check_circle, color: AppColors.accent, size: 72),
              const SizedBox(height: 16),
              const Text('定制已提交', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('预计 1 小时左右完成，完成后可在「我的定制」查看',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.textMuted)),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(onPressed: () => onDone(context), child: const Text('查看我的定制')),
              ),
            ]),
          ),
        ),
      );
}
