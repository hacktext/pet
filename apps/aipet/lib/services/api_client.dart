import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

/// The app's version as the server records it (pubspec `version`, without the
/// build number).
const kAppVersion = '1.0.2';

const kDefaultApiBase = 'https://aipei.pixpickai.com';

/// The server, from AIPET_API_BASE when set (e.g. `http://aipet.localhost:8000`
/// for a local pixpickweb-tp), without a trailing slash.
String apiBaseFrom(Map<String, String> env) {
  final v = (env['AIPET_API_BASE'] ?? '').trim();
  return (v.isEmpty ? kDefaultApiBase : v).replaceFirst(RegExp(r'/+$'), '');
}

/// A status and a body; anything that did not get that far throws.
class HttpReply {
  const HttpReply(this.status, this.body);

  final int status;
  final String body;
}

abstract class HttpTransport {
  Future<HttpReply> send(String method, Uri url, {Map<String, String> headers = const {}, String? body});
}

/// dart:io: asynchronous all the way, so a slow server never holds up the UI
/// isolate (it runs on the platform thread, HANDOFF pitfall 2).
class IoHttpTransport implements HttpTransport {
  IoHttpTransport({this.timeout = const Duration(seconds: 10)})
      : _client = HttpClient()..connectionTimeout = timeout;

  final Duration timeout;
  final HttpClient _client;

  @override
  Future<HttpReply> send(String method, Uri url, {Map<String, String> headers = const {}, String? body}) async {
    Future<HttpReply> run() async {
      final req = await _client.openUrl(method, url);
      headers.forEach(req.headers.set);
      if (body != null) {
        final bytes = utf8.encode(body);
        req.contentLength = bytes.length;
        req.add(bytes);
      }
      final res = await req.close();
      return HttpReply(res.statusCode, await res.transform(utf8.decoder).join());
    }

    return run().timeout(timeout);
  }

  void close() => _client.close(force: true);
}

/// What a call came back with: [ApiOk], [ApiError] (the server said no) or
/// [ApiOffline] (no usable answer at all). Every one has a message to show.
sealed class ApiResult {
  const ApiResult();

  String get message;
}

final class ApiOk extends ApiResult {
  const ApiOk(this.data);

  /// The envelope's `data`, as decoded JSON.
  final Object? data;

  @override
  String get message => '';
}

final class ApiError extends ApiResult {
  const ApiError(this.code, this.message, [this.data]);

  final int code;
  @override
  final String message;
  final Object? data;
}

final class ApiOffline extends ApiResult {
  const ApiOffline(this.reason);

  final String reason;

  @override
  // The server was reached but answered with an error page (reason 'HTTP n'):
  // telling the user to check their network would send them the wrong way.
  String get message => reason.startsWith('HTTP ') ? '服务器暂时出错，请稍后再试' : '网络连接失败，请稍后再试';
}

/// The aipet endpoints of pixpickweb-tp (web platform spec 4): every answer is
/// an envelope `{code, message, data}`, code 0 on success. Never throws.
class ApiClient {
  ApiClient(
    this._transport, {
    String? baseUrl,
    String? Function()? token,
    void Function()? onUnauthorized,
  })  : baseUrl = (baseUrl ?? apiBaseFrom(Platform.environment)).replaceFirst(RegExp(r'/+$'), ''),
        _token = token ?? (() => null),
        _onUnauthorized = onUnauthorized ?? (() {});

  final HttpTransport _transport;
  final String baseUrl;
  final String? Function() _token;
  final void Function() _onUnauthorized;

  Future<ApiResult> hello({required String deviceId, required String os, required String appVersion}) =>
      _call('POST', '/api/aipet/device/hello', {'device_id': deviceId, 'os': os, 'app_version': appVersion});

  Future<ApiResult> events(String deviceId, List<Map<String, Object?>> events) =>
      _call('POST', '/api/aipet/events', {'device_id': deviceId, 'events': events});

  Future<ApiResult> sendSms(String phone) => _call('POST', '/api/aipet/sms/send', {'phone': phone});

  Future<ApiResult> login(
          {required String phone, required String code, required String deviceId, required String deviceName}) =>
      _call('POST', '/api/aipet/auth/login',
          {'phone': phone, 'code': code, 'device_id': deviceId, 'device_name': deviceName});

  Future<ApiResult> logout() => _call('POST', '/api/aipet/auth/logout', const <String, Object?>{});

  Future<ApiResult> me() => _call('GET', '/api/aipet/me');

  Future<ApiResult> getSync() => _call('GET', '/api/aipet/sync');

  Future<ApiResult> putSync(int baseVersion, Map<String, Object?> doc) =>
      _call('PUT', '/api/aipet/sync', {'base_version': baseVersion, 'data': doc});

  // Custom pets (custom order spec 4.4); all need a token.

  Future<ApiResult> customPlans() => _call('GET', '/api/aipet/custom/plans');

  Future<ApiResult> uploadTickets(int count) =>
      _call('POST', '/api/aipet/custom/upload-tickets', {'count': count});

  Future<ApiResult> createCustomRequest(
          {required String name, required String species, required List<String> photoKeys}) =>
      _call('POST', '/api/aipet/custom/requests', {'name': name, 'species': species, 'photo_keys': photoKeys});

  Future<ApiResult> customOrder(int requestId, String planCode) =>
      _call('POST', '/api/aipet/custom/requests/$requestId/order', {'plan_code': planCode});

  Future<ApiResult> customOrderStatus(String orderNo) =>
      _call('GET', '/api/aipet/custom/orders/${Uri.encodeComponent(orderNo)}');

  Future<ApiResult> customRequests() => _call('GET', '/api/aipet/custom/requests');

  // Delivered custom pets (generation spec 4.6): the pet window's downloader.

  Future<ApiResult> customDeliveries() => _call('GET', '/api/aipet/custom/deliveries');

  Future<ApiResult> customAssets(int requestId) => _call('GET', '/api/aipet/custom/requests/$requestId/assets');

  Future<ApiResult> _call(String method, String path, [Object? body]) async {
    final HttpReply reply;
    String? token;
    try {
      token = _token();
      reply = await _transport.send(
        method,
        Uri.parse('$baseUrl$path'),
        headers: {
          'Accept': 'application/json',
          if (body != null) 'Content-Type': 'application/json; charset=utf-8',
          if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
        body: body == null ? null : jsonEncode(body),
      );
    } catch (e) {
      developer.log('$method $path failed: $e', name: 'aipet.api');
      return ApiOffline('$e');
    }

    Map<String, Object?>? envelope;
    try {
      final j = jsonDecode(reply.body);
      if (j is Map<String, Object?> && j['code'] is int) envelope = j;
    } catch (_) {}

    if (reply.status == 401) {
      // The token was revoked or expired: forget it, the user signs in again.
      if (token != null && token.isNotEmpty) _onUnauthorized();
      return ApiError((envelope?['code'] as int?) ?? 1003, '登录已过期，请重新登录');
    }
    if (reply.status == 429) return const ApiError(429, '操作太频繁，请稍后再试');
    if (envelope == null || reply.status >= 500) {
      developer.log('$method $path: HTTP ${reply.status}, no envelope', name: 'aipet.api');
      return ApiOffline('HTTP ${reply.status}');
    }
    final code = envelope['code']! as int;
    if (code == 0) return ApiOk(envelope['data']);
    final message = envelope['message'];
    return ApiError(code, message is String && message.isNotEmpty ? message : '请求失败（$code）', envelope['data']);
  }
}
