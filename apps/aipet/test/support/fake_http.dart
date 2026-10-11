import 'dart:async';
import 'dart:convert';

import 'package:aipet/services/api_client.dart';

/// One request as the server would have seen it.
class SentRequest {
  SentRequest(this.method, this.url, this.headers, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;

  Map<String, Object?> get json => jsonDecode(body!) as Map<String, Object?>;
}

/// An in-memory server: [reply] answers each request; by default every call
/// gets `{code:0, data:null}`. Throwing from [reply] is a network failure.
class FakeHttp implements HttpTransport {
  final sent = <SentRequest>[];
  FutureOr<HttpReply> Function(SentRequest r) reply = (_) => ok(null);

  static HttpReply ok(Object? data) => HttpReply(200, jsonEncode({'code': 0, 'message': 'ok', 'data': data}));

  static HttpReply fail(int code, String message, [Object? data, int status = 200]) =>
      HttpReply(status, jsonEncode({'code': code, 'message': message, 'data': data}));

  /// The requests sent to [path] (e.g. `/api/aipet/events`).
  List<SentRequest> to(String path) => [for (final r in sent) if (r.url.path == path) r];

  @override
  Future<HttpReply> send(String method, Uri url, {Map<String, String> headers = const {}, String? body}) async {
    final r = SentRequest(method, url, Map.of(headers), body);
    sent.add(r);
    return reply(r);
  }
}
