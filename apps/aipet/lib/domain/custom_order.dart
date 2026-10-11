import 'library_state.dart';
import 'pet.dart';

/// A custom pet's progress (generation spec 3, revising custom order spec 2):
/// draft and pending_payment both read as 待支付.
enum CustomStatus {
  draft('draft', '待支付'),
  pendingPayment('pending_payment', '待支付'),
  paid('paid', '待生成'),
  generating('generating', '生成中'),
  review('review', '审核中'),
  delivered('delivered', '已完成'),
  failed('failed', '生成失败'),
  refunded('refunded', '已退款');

  const CustomStatus(this.wire, this.label);
  final String wire;
  final String label;

  static CustomStatus? fromWire(Object? s) => {for (final v in values) v.wire: v}[s];

  bool get awaitingPayment => this == draft || this == pendingPayment;

  /// Paid and not finished: the server will move it on (待生成, 生成中, 审核中),
  /// so a page showing it is worth asking again.
  bool get inProgress => this == paid || this == generating || this == review;
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
    this.petId,
    this.stage,
    this.stageDone,
    this.stageTotal,
    this.failReason,
  });

  final int id;
  final String name;
  final Species species;
  final CustomStatus status;
  final String? planCode, planName, orderNo, coverUrl;
  final int? priceCents;

  /// `custom-<id>`: the folder under pets/ it is delivered into; null until
  /// the server set up its generation.
  final String? petId;

  /// The latest progress while generating: which step, and n of m.
  final String? stage;
  final int? stageDone, stageTotal;

  /// Failed only. For support; the list does not show it.
  final String? failReason;

  /// What 我的定制 says (generation spec 6.2). The worker counts within a
  /// step (refs 1/3, then video 1/7), so the count is shown with the step's
  /// name -- a bare n/m would seem to go backwards when the step changes.
  String get statusText {
    final total = stageTotal ?? 0;
    final done = (stageDone ?? 0).clamp(0, total);
    return switch (status) {
      CustomStatus.generating when total > 0 && stage == 'refs' => '生成中（参考图 $done/$total）',
      CustomStatus.generating when total > 0 && stage == 'video' => '生成中（动作 $done/$total）',
      CustomStatus.failed => '生成失败（我们会联系你处理或退款）',
      _ => status.label,
    };
  }

  static CustomRequestInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], name = j['name'];
    final species = Species.values.asNameMap()[j['species']];
    final status = CustomStatus.fromWire(j['status']);
    if (id is! int || name is! String || species == null || status == null) return null;
    String? s(String k) => j[k] is String ? j[k] as String : null;
    int? n(String k) => j[k] is int ? j[k] as int : null;
    final petId = s('pet_id');
    return CustomRequestInfo(
      id: id,
      name: name,
      species: species,
      status: status,
      planCode: s('plan_code'),
      planName: s('plan_name'),
      priceCents: n('price_cents'),
      orderNo: s('order_no'),
      coverUrl: s('cover_url'),
      petId: petId != null && isCustomPetId(petId) ? petId : null,
      stage: s('stage'),
      stageDone: n('stage_done'),
      stageTotal: n('stage_total'),
      failReason: s('fail_reason'),
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

final _petIdPattern = RegExp(r'^custom-[a-z0-9-]{1,57}$');

/// A path segment of a delivered file: no leading dot (so no `.`, `..` or
/// hidden files), no trailing dot (Windows strips it), no slashes, colons or
/// other characters Windows minds.
final _segmentPattern = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]*(?<!\.)$');
final _reservedName = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$');
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// A folder name under pets/ that a delivered pet may use: `custom-` and the
/// rest of an id (at most 64 characters), never a dot-folder or a built-in's id.
bool isCustomPetId(String id) => _petIdPattern.hasMatch(id);

/// `stand.mp4`, `voices/a/stand-1.wav`: relative, forward slashes, and nothing
/// that could step outside the pet folder, name a Windows device, or collide
/// with the downloader's `.part` files.
bool isSafeAssetPath(String path) {
  if (path.isEmpty || path.length > 200) return false;
  if (path.toLowerCase().endsWith('.part')) return false;
  final segments = path.split('/');
  if (!segments.every(_segmentPattern.hasMatch)) return false;
  // `con.txt` is the console too: the device name is what precedes the first dot.
  return !segments.any((s) => _reservedName.hasMatch(s.toLowerCase().split('.').first));
}

/// One delivered custom pet (`GET custom/deliveries`; delivered_at is not used).
class CustomDelivery {
  const CustomDelivery({required this.id, required this.petId, required this.name});

  final int id;
  final String petId;
  final String name;

  static CustomDelivery? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], petId = j['pet_id'], name = j['name'];
    if (id is! int || petId is! String || !isCustomPetId(petId) || name is! String) return null;
    return CustomDelivery(id: id, petId: petId, name: name);
  }

  static List<CustomDelivery> listFrom(Object? data) =>
      [for (final j in (data is List ? data : const [])) ?CustomDelivery.fromJson(j)];
}

/// One file of a delivered pet: where it goes inside the pet folder, and how
/// to tell it arrived whole.
class CustomAsset {
  const CustomAsset({required this.path, required this.bytes, required this.sha256, required this.url});

  final String path;
  final int bytes;

  /// Lower-case hex.
  final String sha256;

  /// A signed GET, good for 30 minutes.
  final String url;

  static CustomAsset? fromJson(Object? j) {
    if (j is! Map) return null;
    final path = j['path'], bytes = j['bytes'], hash = j['sha256'], url = j['url'];
    if (path is! String || !isSafeAssetPath(path)) return null;
    if (bytes is! int || bytes < 0 || hash is! String || url is! String) return null;
    final h = hash.toLowerCase();
    if (!_sha256Pattern.hasMatch(h)) return null;
    final u = Uri.tryParse(url);
    if (u == null || (u.scheme != 'https' && u.scheme != 'http') || u.host.isEmpty) return null;
    return CustomAsset(path: path, bytes: bytes, sha256: h, url: url);
  }
}

/// `GET custom/requests/:id/assets`. All or nothing: a manifest with one
/// unusable file, two files that are the same file on Windows, or no
/// pet.json would install a broken pet.
class CustomAssets {
  const CustomAssets({required this.petId, required this.files});

  final String petId;
  final List<CustomAsset> files;

  static CustomAssets? fromJson(Object? j) {
    if (j is! Map) return null;
    final petId = j['pet_id'], raw = j['files'];
    if (petId is! String || !isCustomPetId(petId) || raw is! List || raw.isEmpty) return null;
    final files = <CustomAsset>[];
    for (final r in raw) {
      final f = CustomAsset.fromJson(r);
      if (f == null) return null;
      files.add(f);
    }
    final paths = {for (final f in files) f.path.toLowerCase()};
    if (paths.length != files.length || !paths.contains('pet.json')) return null;
    // A file `a` and a file `a/b` cannot both exist: `a` would be a folder.
    for (final p in paths) {
      final segments = p.split('/');
      for (var i = 1; i < segments.length; i++) {
        if (paths.contains(segments.take(i).join('/'))) return null;
      }
    }
    return CustomAssets(petId: petId, files: List.unmodifiable(files));
  }
}
