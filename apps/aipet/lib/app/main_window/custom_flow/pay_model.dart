import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/custom_order.dart';
import '../../../services/custom_service.dart';

/// The server's code for a missing or rejected token.
const _authCode = 1003;
const _loginAgain = '登录已过期，请重新登录';

/// The WeChat QR and its order: asks every [pollEvery] whether it is paid,
/// stops when paid, expired, signed out or disposed (custom order spec 3,
/// step 4). Time left counts down by ticks, not by the wall clock: widget
/// tests run on fake time, and DateTime.now() does not follow it.
class PayModel extends ChangeNotifier {
  PayModel({
    required CustomService service,
    required this.requestId,
    required this.planCode,
    required PayOrder order,
    this.pollEvery = const Duration(seconds: 2),
  })
      // ignore: prefer_initializing_formals
      : _service = service,
        _order = order,
        _left = order.expiresIn;

  final CustomService _service;
  final int requestId;
  final String planCode;
  final Duration pollEvery;

  PayOrder _order;
  Duration _left;
  Timer? _timer;
  bool _paid = false;
  bool _expired = false;
  bool _asking = false;
  bool _refreshing = false;
  bool _disposed = false;
  String? _message;

  PayOrder get order => _order;
  bool get paid => _paid;
  bool get expired => _expired;
  String? get message => _message;
  Duration get left => _left.isNegative ? Duration.zero : _left;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(pollEvery, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_disposed || _paid || _expired) return;
    _left -= pollEvery;
    if (_left <= Duration.zero) {
      _expire();
      return;
    }
    notifyListeners(); // the countdown
    if (_asking) return;
    _asking = true;
    final asked = _order.orderNo;
    try {
      final s = await _service.status(asked);
      if (_disposed || asked != _order.orderNo) return; // a newer QR took over
      if (s == PayStatus.paid) {
        _paid = true;
        _timer?.cancel();
        notifyListeners();
      } else if (s == PayStatus.expired || s == PayStatus.failed) {
        _expire();
      }
    } on CustomFailure catch (f) {
      if (f.code == _authCode && !_disposed) {
        // Polling on would only fail the same way until the QR expires.
        _timer?.cancel();
        _message = _loginAgain;
        notifyListeners();
      }
      // Any other missed poll is not an answer; the next tick asks again.
    } finally {
      _asking = false;
    }
  }

  void _expire() {
    _expired = true;
    _timer?.cancel();
    notifyListeners();
  }

  /// A fresh QR after expiry (the server makes a new order).
  Future<void> refresh() async {
    if (_refreshing || _disposed) return;
    _refreshing = true;
    _message = null;
    notifyListeners();
    try {
      final o = await _service.order(requestId, planCode);
      if (_disposed) return;
      _order = o;
      _left = o.expiresIn;
      _expired = false;
      start();
    } on CustomFailure catch (f) {
      _message = f.code == _authCode ? _loginAgain : f.message;
    } finally {
      _refreshing = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
