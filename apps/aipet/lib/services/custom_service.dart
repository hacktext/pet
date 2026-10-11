import '../domain/custom_order.dart';
import 'api_client.dart';

/// Why a custom-pet call did not work, in words to show; [code] and [field]
/// when the server said no (5010 carries the offending field).
class CustomFailure implements Exception {
  const CustomFailure(this.message, {this.code, this.field});

  final String message;
  final int? code;
  final String? field;

  @override
  String toString() => 'CustomFailure($code, $field, $message)';
}

/// The custom-pet endpoints as typed calls; every failure is a [CustomFailure].
class CustomService {
  CustomService(this._api);

  final ApiClient _api;

  Future<List<CustomPlan>> plans() async =>
      [for (final j in _list(await _api.customPlans())) ?CustomPlan.fromJson(j)];

  Future<List<UploadTicket>> tickets(int count) async {
    final t = [for (final j in _list(await _api.uploadTickets(count))) ?UploadTicket.fromJson(j)];
    if (t.length != count) throw const CustomFailure('服务暂时不可用，请稍后再试');
    return t;
  }

  Future<CustomRequestInfo> create(
          {required String name, required String species, required List<String> photoKeys}) async =>
      CustomRequestInfo.fromJson(
              _data(await _api.createCustomRequest(name: name, species: species, photoKeys: photoKeys))) ??
          (throw const CustomFailure('服务暂时不可用，请稍后再试'));

  Future<PayOrder> order(int requestId, String planCode) async =>
      PayOrder.fromJson(_data(await _api.customOrder(requestId, planCode))) ??
      (throw const CustomFailure('服务暂时不可用，请稍后再试'));

  Future<PayStatus> status(String orderNo) async {
    final d = _data(await _api.customOrderStatus(orderNo));
    return PayStatus.fromWire(d is Map ? d['status'] : null);
  }

  Future<List<CustomRequestInfo>> list() async =>
      [for (final j in _list(await _api.customRequests())) ?CustomRequestInfo.fromJson(j)];

  Object? _data(ApiResult r) => switch (r) {
        ApiOk(:final data) => data,
        ApiError(:final code, :final message, :final data) => throw CustomFailure(message,
            code: code, field: data is Map && data['field'] is String ? data['field'] as String : null),
        ApiOffline() => throw CustomFailure(r.message),
      };

  List<Object?> _list(ApiResult r) {
    final d = _data(r);
    return d is List ? d : const [];
  }
}
