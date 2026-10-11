import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/custom_order.dart';
import '../../../services/custom_service.dart';

/// The server's code for a missing or rejected token.
const _authCode = 1003;

/// CUSTOM_ALREADY_PAID: ordering again for a request that is already paid.
const _alreadyPaidCode = 5011;
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
  bool _expiring = false; // the countdown ran out; the last status check is out
  bool _refreshing = false;
  bool _disposed = false;
  String? _message;

  PayOrder get order => _order;
  bool get paid => _paid;
  bool get expired => _expired;
  bool get refreshing => _refreshing;
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
    if (_disposed || _paid || _expired || _expiring) return;
    _left -= pollEvery;
    if (_left <= Duration.zero) {
      // One last look before giving up: someone who paid at the boundary
      // must not be shown 「二维码已过期」.
      _expiring = true;
      if (!_asking) await _poll();
      return;
    }
    notifyListeners(); // the countdown
    if (!_asking) await _poll();
  }

  Future<void> _poll() async {
    _asking = true;
    final asked = _order.orderNo;
    try {
      final s = await _service.status(asked);
      if (_disposed || asked != _order.orderNo) return; // a newer QR took over
      if (s == PayStatus.paid) {
        _expiring = false;
        _paid = true;
        _timer?.cancel();
        notifyListeners();
      } else if (s == PayStatus.refunded) {
        _expiring = false;
        _timer?.cancel();
        _message = '订单已退款';
        notifyListeners();
      } else if (s == PayStatus.expired || s == PayStatus.failed || _expiring) {
        _expire();
      }
    } on CustomFailure catch (f) {
      if (_disposed || asked != _order.orderNo) return;
      if (f.code == _authCode) {
        // Polling on would only fail the same way until the QR expires.
        _timer?.cancel();
        _expiring = false;
        _message = _loginAgain;
        notifyListeners();
      } else if (_expiring) {
        _expire();
      }
      // Any other missed poll is not an answer; the next tick asks again.
    } finally {
      _asking = false;
    }
  }

  void _expire() {
    _expiring = false;
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
      _expiring = false;
      _left = o.expiresIn;
      _expired = false;
      start();
    } on CustomFailure catch (f) {
      if (f.code == _alreadyPaidCode) {
        // The QR was paid after all (e.g. at the boundary); go on as paid.
        _paid = true;
        _expired = false;
        _timer?.cancel();
      } else {
        _message = f.code == _authCode ? _loginAgain : f.message;
      }
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
