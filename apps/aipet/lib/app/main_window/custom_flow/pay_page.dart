import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../domain/custom_order.dart';
import '../theme.dart';
import 'custom_deps.dart';
import 'pay_model.dart';

/// 微信扫码支付: QR, amount, countdown; [onPaid] once the server says paid.
class PayPage extends StatefulWidget {
  const PayPage({
    super.key,
    required this.deps,
    required this.request,
    required this.plan,
    required this.order,
    required this.onPaid,
  });

  final CustomDeps deps;
  final CustomRequestInfo request;
  final CustomPlan plan;
  final PayOrder order;
  final void Function(BuildContext context) onPaid;

  @override
  State<PayPage> createState() => _PayPageState();
}

class _PayPageState extends State<PayPage> {
  late final PayModel _m = PayModel(
    service: widget.deps.service,
    requestId: widget.request.id,
    planCode: widget.plan.code,
    order: widget.order,
  )
    ..addListener(_onChange)
    ..start();
  var _reported = false;

  void _onChange() {
    if (_m.paid && !_reported && mounted) {
      _reported = true;
      widget.onPaid(context);
    }
  }

  @override
  void dispose() {
    _m
      ..removeListener(_onChange)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('微信支付'), centerTitle: true, backgroundColor: AppColors.page),
        body: ListenableBuilder(
          listenable: _m,
          builder: (context, _) {
            final left = _m.left;
            final mm = left.inMinutes.toString().padLeft(2, '0');
            final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
            return ListView(padding: const EdgeInsets.all(24), children: [
              Text('${widget.request.name} · ${widget.plan.name}',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(yuan(_m.order.amountCents),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w800, color: AppColors.accent)),
              const SizedBox(height: 16),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                  child: _m.expired
                      ? SizedBox(
                          width: 220,
                          height: 220,
                          child: Center(
                            child: TextButton(onPressed: _m.refresh, child: const Text('二维码已过期，点击刷新')),
                          ),
                        )
                      : QrImageView(data: _m.order.codeUrl, size: 220),
                ),
              ),
              const SizedBox(height: 12),
              const Text('请使用微信扫码支付', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700)),
              if (!_m.expired)
                Text('二维码 $mm:$ss 后过期', textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
              const SizedBox(height: 8),
              const Text('支付完成后会自动跳转；关闭本页也可以在「我的定制」里继续支付',
                  textAlign: TextAlign.center, style: TextStyle(color: AppColors.textMuted, fontSize: 12)),
              if (_m.message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_m.message!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
                ),
            ]);
          },
        ),
      );
}
