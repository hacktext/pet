import 'package:flutter/material.dart';

import '../../../domain/custom_order.dart';
import '../theme.dart';
import 'custom_deps.dart';
import 'plan_model.dart';

/// 选择宠物版本: plan cards, payment method, 创建宠物.
class PlanPage extends StatefulWidget {
  const PlanPage({
    super.key,
    required this.deps,
    required this.request,
    required this.onOrder,
    this.onAlreadyPaid,
  });

  final CustomDeps deps;
  final CustomRequestInfo request;
  final void Function(BuildContext context, CustomPlan plan, PayOrder order)
  onOrder;

  /// The server says the request is paid already: carry on as if it just was.
  final void Function(BuildContext context)? onAlreadyPaid;

  @override
  State<PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  late final PlanModel _m = PlanModel(widget.deps.service, widget.request)
    ..load();

  @override
  void dispose() {
    _m.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final plan = _m.selected;
    final o = await _m.createOrder();
    if (!mounted) return;
    if (o != null && plan != null) {
      widget.onOrder(context, plan, o);
    } else if (_m.alreadyPaid) {
      widget.onAlreadyPaid?.call(context);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: AppColors.page),
    body: ListenableBuilder(
      listenable: _m,
      builder: (context, _) => Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                const Text(
                  '选择宠物版本',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const Text(
                  '选择合适的陪伴方式',
                  style: TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: 12),
                if (_m.loading && _m.plans.isEmpty)
                  const Center(child: CircularProgressIndicator()),
                if (!_m.loading && _m.plans.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        Text(
                          _m.message ?? '暂无可选套餐',
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _m.load,
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                for (final p in _m.plans)
                  _PlanCard(
                    plan: p,
                    selected: _m.selected?.code == p.code,
                    onTap: () => _m.select(p.code),
                  ),
              ],
            ),
          ),
          _Footer(model: _m, onCreate: _create),
        ],
      ),
    ),
  );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.selected,
    required this.onTap,
  });

  final CustomPlan plan;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pro = plan.icon == 'pro';
    final tint = pro ? const Color(0xFF5B5BD6) : AppColors.accent;
    Widget chip(String t, {bool strong = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: strong ? AppColors.warmSoft : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        t,
        style: TextStyle(
          fontSize: 12,
          fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppColors.accent : Colors.black12,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: tint.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      pro ? Icons.workspace_premium : Icons.pets,
                      color: tint,
                      size: 36,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                plan.name,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (plan.badge != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: tint,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  plan.badge!,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        Text(
                          plan.subtitle,
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final t in plan.tags) chip(t),
                            chip('${plan.featureCount} 项功能'),
                            chip('还原度${plan.fidelity}%', strong: true),
                            chip('${plan.revisions}次修改机会'),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        plan.priceText,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: tint,
                        ),
                      ),
                      Text(
                        plan.validText,
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: selected ? AppColors.accent : Colors.black26,
                        size: 28,
                      ),
                    ],
                  ),
                ],
              ),
              if (plan.features.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '包含功能：${plan.features.join(' · ')}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.model, required this.onCreate});

  final PlanModel model;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final p = model.selected;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      color: AppColors.card,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p != null)
            Row(
              children: [
                const Icon(
                  Icons.check_circle,
                  color: AppColors.accent,
                  size: 20,
                ),
                const SizedBox(width: 6),
                Text(
                  '已选 ${p.name}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  p.priceText,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.accent,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(child: _WeChatOption()),
              const SizedBox(width: 8),
              const Expanded(
                child: OutlinedButton(
                  onPressed: null,
                  child: Text('支付宝（即将上线）'),
                ),
              ),
            ],
          ),
          if (model.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                model.message!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: p == null || model.busy ? null : onCreate,
              child: Text(
                model.busy ? '正在创建订单…' : '创建宠物',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one payment method on offer: shown selected, not a button.
class _WeChatOption extends StatelessWidget {
  const _WeChatOption();

  @override
  Widget build(BuildContext context) => Semantics(
    label: '微信支付，已选择',
    excludeSemantics: true,
    child: Container(
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.accent, width: 2),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble, color: Color(0xFF07C160), size: 18),
          SizedBox(width: 6),
          Text('微信支付'),
          SizedBox(width: 6),
          Icon(Icons.check, color: AppColors.accent, size: 18),
        ],
      ),
    ),
  );
}
