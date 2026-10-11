import 'package:flutter/foundation.dart';

import '../../../domain/custom_order.dart';
import '../../../services/custom_service.dart';

/// 选择宠物版本 (custom order spec 3, step 3).
class PlanModel extends ChangeNotifier {
  PlanModel(this._service, this.request);

  final CustomService _service;
  final CustomRequestInfo request;

  List<CustomPlan> _plans = const [];
  String? _selected;
  bool _loading = false;
  bool _busy = false;
  String? _message;
  bool _disposed = false;

  List<CustomPlan> get plans => _plans;
  CustomPlan? get selected => _plans.where((p) => p.code == _selected).firstOrNull;
  bool get loading => _loading;
  bool get busy => _busy;
  String? get message => _message;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    try {
      _plans = await _service.plans();
      if (selected == null) _selected = _plans.firstOrNull?.code;
    } on CustomFailure catch (f) {
      _message = f.message;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void select(String code) {
    if (_busy) return;
    _selected = code;
    notifyListeners();
  }

  Future<PayOrder?> createOrder() async {
    final plan = selected;
    if (plan == null || _busy) return null;
    _busy = true;
    _message = null;
    notifyListeners();
    try {
      return await _service.order(request.id, plan.code);
    } on CustomFailure catch (f) {
      _message = f.message;
      // Stay busy while the list reloads so a second tap cannot order a stale plan.
      if (f.code == 5013) await load();
      return null;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
