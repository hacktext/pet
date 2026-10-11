import 'dart:async';
import 'dart:io';

/// Why a download did not produce the whole file: a status other than 200
/// (an expired signed URL is a 403), a connection that failed or went quiet.
class DownloadFailed implements Exception {
  const DownloadFailed(this.reason);

  final String reason;

  @override
  String toString() => 'DownloadFailed($reason)';
}

/// Fetches one URL into one file (generation spec 6.1). Tests pass a fake.
abstract class DownloadTransport {
  /// Creates or truncates [into]; throws [DownloadFailed] unless the whole
  /// body of a 200 was written.
  Future<void> download(Uri url, File into);
}

/// dart:io, streamed straight to disk: the body is never held in memory, and
/// nothing here blocks the UI isolate (it runs on the platform thread).
class IoDownloadTransport implements DownloadTransport {
  IoDownloadTransport({
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  }) : _client = HttpClient()..connectionTimeout = connectTimeout;

  final Duration connectTimeout;

  /// The longest wait for the headers or for the next piece of the body; a
  /// clip can take minutes on a slow line, so there is no overall limit.
  final Duration idleTimeout;
  final HttpClient _client;

  @override
  Future<void> download(Uri url, File into) async {
    IOSink? sink;
    try {
      final req = await _client.getUrl(url);
      final res = await req.close().timeout(idleTimeout);
      if (res.statusCode != HttpStatus.ok) {
        try {
          await res.drain<void>().timeout(idleTimeout);
        } catch (_) {}
        throw DownloadFailed('HTTP ${res.statusCode}');
      }
      final out = into.openWrite();
      sink = out;
      await out.addStream(res.timeout(idleTimeout));
      sink = null;
      await out.close();
      final expected = res.contentLength; // -1 when chunked or decompressed
      if (expected >= 0 && await into.length() != expected) throw const DownloadFailed('short body');
    } on DownloadFailed {
      rethrow;
    } catch (e) {
      throw DownloadFailed('$e');
    } finally {
      // An open sink would keep the file locked on Windows.
      try {
        await sink?.close();
      } catch (_) {}
    }
  }

  void close() => _client.close(force: true);
}
