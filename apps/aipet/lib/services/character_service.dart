import '../domain/custom_order.dart';
import '../domain/paid_character.dart';
import 'api_client.dart';
import 'custom_service.dart';

/// The server's code for ordering a character that does not exist or is off sale.
const kCharacterUnavailableCode = 5015;

/// The server's code for ordering a character the account already owns.
const kCharacterOwnedCode = 5016;

/// The paid-character endpoints as typed calls; every failure is a
/// [CustomFailure] (same mapping as [CustomService], `code` kept).
class CharacterService {
  CharacterService(this._api, {void Function()? onLoginExpired}) : _onLoginExpired = onLoginExpired ?? _nothing;

  final ApiClient _api;
  final void Function() _onLoginExpired;

  static void _nothing() {}

  Future<List<PaidCharacter>> catalog() async => paidCatalogFrom(_data(await _api.characters()));

  /// What the account owns: each owned character as a catalog item (delisted
  /// ones too, so a buyer keeps seeing them) and every owned code -- an item
  /// this app cannot show (say, an unknown species) is still owned.
  Future<({List<PaidCharacter> items, Set<String> codes})> owned() async {
    final d = _data(await _api.ownedCharacters());
    final codes = <String>{
      if (d is List)
        for (final c in d)
          if (c is Map && c['code'] is String) c['code'] as String else if (c is String) c, // a bare code: older server
    };
    return (items: paidCatalogFrom(d), codes: codes);
  }

  Future<PayOrder> order(String code) async =>
      PayOrder.fromJson(_data(await _api.characterOrder(code))) ?? (throw const CustomFailure('服务暂时不可用，请稍后再试'));

  Future<PayStatus> status(String orderNo) async {
    final d = _data(await _api.characterOrderStatus(orderNo));
    return PayStatus.fromWire(d is Map ? d['status'] : null);
  }

  Future<CustomAssets> assets(String code) async {
    final r = await _api.characterAssets(code);
    // Not owned is a bare 403 with no envelope, which the client reports as offline.
    if (r is ApiOffline && r.reason == 'HTTP 403') throw const CustomFailure('还没有解锁这个人物', code: 403);
    return CustomAssets.fromJson(_data(r)) ?? (throw const CustomFailure('服务暂时不可用，请稍后再试'));
  }

  Object? _data(ApiResult r) => switch (r) {
        ApiOk(:final data) => data,
        ApiError(:final code, :final message) => throw _failure(code, message),
        ApiOffline() => throw CustomFailure(r.message),
      };

  CustomFailure _failure(int code, String message) {
    if (code == kLoginExpiredCode) _onLoginExpired();
    return CustomFailure(message, code: code);
  }
}
