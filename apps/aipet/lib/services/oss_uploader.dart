import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../domain/custom_order.dart';

/// A multipart/form-data body: [fields] in their order, then the file —
/// OSS PostObject ignores every field after the file.
List<int> buildMultipart(String boundary, Map<String, String> fields,
    {required String fileField, required String filename, required String contentType, required List<int> bytes}) {
  final out = BytesBuilder(copy: false);
  void line(String s) => out.add(utf8.encode('$s\r\n'));
  fields.forEach((k, v) {
    line('--$boundary');
    line('Content-Disposition: form-data; name="$k"');
    line('');
    line(v);
  });
  line('--$boundary');
  line('Content-Disposition: form-data; name="$fileField"; filename="$filename"');
  line('Content-Type: $contentType');
  line('');
  out.add(bytes);
  line('');
  line('--$boundary--');
  return out.takeBytes();
}

/// POSTs a form with one JPEG named `file`; the HTTP status comes back,
/// a failure to get one throws.
abstract class MultipartTransport {
  Future<int> post(Uri url, Map<String, String> fields, {required String filename, required List<int> bytes});
}

class IoMultipartTransport implements MultipartTransport {
  IoMultipartTransport({this.timeout = const Duration(seconds: 60)})
      : _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  final Duration timeout;
  final HttpClient _client;

  @override
  Future<int> post(Uri url, Map<String, String> fields, {required String filename, required List<int> bytes}) async {
    final boundary = 'aipet${Random().nextInt(1 << 32)}${DateTime.now().microsecondsSinceEpoch}';
    final body = buildMultipart(boundary, fields,
        fileField: 'file', filename: filename, contentType: 'image/jpeg', bytes: bytes);
    Future<int> run() async {
      final req = await _client.postUrl(url);
      req.headers.contentType = ContentType('multipart', 'form-data', parameters: {'boundary': boundary});
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }

    return run().timeout(timeout);
  }
}

class OssUploadFailed implements Exception {
  const OssUploadFailed(this.status);

  /// The HTTP status OSS answered with; -1 when there was no answer.
  final int status;

  @override
  String toString() => 'OssUploadFailed($status)';
}

/// Sends one prepared JPEG to OSS with the ticket the server signed.
class OssUploader {
  OssUploader(this._transport);

  final MultipartTransport _transport;

  Future<void> upload(UploadTicket ticket, List<int> jpeg) async {
    final int status;
    try {
      status = await _transport.post(Uri.parse(ticket.url), ticket.fields, filename: 'photo.jpg', bytes: jpeg);
    } catch (_) {
      throw const OssUploadFailed(-1);
    }
    if (status < 200 || status >= 300) throw OssUploadFailed(status);
  }
}
