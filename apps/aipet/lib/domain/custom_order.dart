import 'library_state.dart';
import 'pet.dart';

/// A custom pet's progress (custom order spec 2): draft and pending_payment
/// both read as 待支付.
enum CustomStatus {
  draft('draft', '待支付'),
  pendingPayment('pending_payment', '待支付'),
  paid('paid', '待制作'),
  making('making', '制作中'),
  done('done', '已完成'),
  refunded('refunded', '已退款');

  const CustomStatus(this.wire, this.label);
  final String wire;
  final String label;

  static CustomStatus? fromWire(Object? s) => {for (final v in values) v.wire: v}[s];

  bool get awaitingPayment => this == draft || this == pendingPayment;
}

enum PayStatus {
  pending,
  paid,
  expired,
  failed,
  refunded;

  static PayStatus fromWire(Object? s) => values.asNameMap()[s] ?? pending;
}

/// ¥39 or ¥39.50.
String yuan(int cents) =>
    cents % 100 == 0 ? '¥${cents ~/ 100}' : '¥${(cents / 100).toStringAsFixed(2)}';

/// The plaza's sub-category name for [s].
String speciesLabel(Species s) => Category.values.firstWhere((c) => c.species == s).label;

List<String> _strings(Object? j) => [for (final v in (j is List ? j : const []) ) if (v is String) v];

class CustomPlan {
  const CustomPlan({
    required this.code,
    required this.name,
    required this.subtitle,
    required this.priceCents,
    required this.validDays,
    required this.tags,
    required this.features,
    required this.featureCount,
    required this.fidelity,
    required this.revisions,
    required this.badge,
    required this.icon,
  });

  final String code, name, subtitle, icon;
  final int priceCents, validDays, featureCount, fidelity, revisions;
  final List<String> tags, features;
  final String? badge;

  String get priceText => yuan(priceCents);

  String get validText => switch (validDays) {
        0 => '永久解锁',
        365 => '解锁一年',
        final d => '解锁 $d 天',
      };

  static CustomPlan? fromJson(Object? j) {
    if (j is! Map) return null;
    final code = j['code'], name = j['name'], price = j['price_cents'];
    if (code is! String || name is! String || price is! int) return null;
    int n(String k) => j[k] is int ? j[k] as int : 0;
    final badge = j['badge'];
    return CustomPlan(
      code: code,
      name: name,
      subtitle: j['subtitle'] is String ? j['subtitle'] as String : '',
      priceCents: price,
      validDays: n('valid_days'),
      tags: _strings(j['tags']),
      features: _strings(j['features']),
      featureCount: n('feature_count'),
      fidelity: n('fidelity'),
      revisions: n('revisions'),
      badge: badge is String && badge.isNotEmpty ? badge : null,
      icon: j['icon'] == 'pro' ? 'pro' : 'standard',
    );
  }
}

/// Where and how one photo may be posted to OSS (never the key secret).
class UploadTicket {
  const UploadTicket({required this.key, required this.url, required this.fields});

  final String key;
  final String url;

  /// The form fields in the order they are to be sent; the file goes last.
  final Map<String, String> fields;

  static UploadTicket? fromJson(Object? j) {
    if (j is! Map) return null;
    final key = j['key'], url = j['url'], fields = j['fields'];
    if (key is! String || url is! String || fields is! Map) return null;
    return UploadTicket(key: key, url: url, fields: {for (final e in fields.entries) '${e.key}': '${e.value}'});
  }
}

class CustomRequestInfo {
  const CustomRequestInfo({
    required this.id,
    required this.name,
    required this.species,
    required this.status,
    this.planCode,
    this.planName,
    this.priceCents,
    this.orderNo,
    this.coverUrl,
  });

  final int id;
  final String name;
  final Species species;
  final CustomStatus status;
  final String? planCode, planName, orderNo, coverUrl;
  final int? priceCents;

  static CustomRequestInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    final species = Species.values.asNameMap()[j['species']];
    final status = CustomStatus.fromWire(j['status']);
    if (id is! int || name is! String || species == null || status == null) return null;
    String? s(String k) => j[k] is String ? j[k] as String : null;
    return CustomRequestInfo(
      id: id,
      name: name,
      species: species,
      status: status,
      planCode: s('plan_code'),
      planName: s('plan_name'),
      priceCents: j['price_cents'] is int ? j['price_cents'] as int : null,
      orderNo: s('order_no'),
      coverUrl: s('cover_url'),
    );
  }
}

class PayOrder {
  const PayOrder({required this.orderNo, required this.amountCents, required this.codeUrl, required this.expiresIn});

  final String orderNo;
  final int amountCents;
  final String codeUrl;

  /// From when the reply arrived; the client never compares server clocks.
  final Duration expiresIn;

  static PayOrder? fromJson(Object? j) {
    if (j is! Map) return null;
    final no = j['order_no'], amount = j['amount_cents'], url = j['code_url'], secs = j['expires_in'];
    if (no is! String || amount is! int || url is! String || secs is! int) return null;
    return PayOrder(orderNo: no, amountCents: amount, codeUrl: url, expiresIn: Duration(seconds: secs));
  }
}
