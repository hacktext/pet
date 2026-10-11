import 'dart:async';

import 'package:aipet/services/oss_uploader.dart';

/// OSS as the tests see it: records each post; [reply] gives the HTTP status
/// (throwing is a network failure).
class FakeOss implements MultipartTransport {
  final posts = <(Uri, Map<String, String>, int)>[];
  FutureOr<int> Function(Uri url, Map<String, String> fields) reply = (_, _) => 204;

  @override
  Future<int> post(Uri url, Map<String, String> fields, {required String filename, required List<int> bytes}) async {
    posts.add((url, Map.of(fields), bytes.length));
    return reply(url, fields);
  }
}
