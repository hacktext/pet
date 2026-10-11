import 'dart:async';
import 'dart:io';

import 'package:aipet/services/file_download.dart';

/// OSS, scripted: [serve] gives the bytes at a URL, or null for a refusal
/// (an expired or unknown signed URL: 403). [requested] records every call.
class FakeDownloads implements DownloadTransport {
  final requested = <String>[];
  List<int>? Function(Uri url) serve = (_) => null;

  /// While set and not completed, every download waits for it (a slow line).
  Completer<void>? gate;

  @override
  Future<void> download(Uri url, File into) async {
    requested.add(url.toString());
    final g = gate;
    if (g != null) await g.future;
    final bytes = serve(url);
    if (bytes == null) throw const DownloadFailed('HTTP 403');
    await into.writeAsBytes(bytes, flush: true);
  }
}
