import 'dart:io';

import 'package:aipet/services/file_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory tmp;
  late IoDownloadTransport t;
  final body = List<int>.generate(300000, (i) => i % 251);

  setUp(() async {
    // flutter_test's binding, once initialized, fakes every HttpClient with
    // 400s; these tests talk to a real loopback server.
    HttpOverrides.global = null;
    tmp = Directory.systemTemp.createTempSync('download_');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      try {
        switch (req.uri.path) {
          case '/ok':
            req.response.contentLength = body.length;
            req.response.add(body);
          case '/stall':
            req.response.add([1, 2, 3]);
            await req.response.flush();
            await Future<void>.delayed(const Duration(seconds: 2));
          default:
            req.response.statusCode = HttpStatus.forbidden;
            req.response.write('<Error>AccessDenied</Error>');
        }
        await req.response.close();
      } catch (_) {
        // The client gave up first; nothing to do.
      }
    });
    t = IoDownloadTransport(idleTimeout: const Duration(milliseconds: 300));
  });

  tearDown(() async {
    t.close();
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Uri at(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  test('a 200 is streamed into the file, replacing what was there', () async {
    final f = File('${tmp.path}\\a.bin')..writeAsStringSync('old and longer than nothing');
    await t.download(at('/ok'), f);
    expect(f.readAsBytesSync(), body);
  });

  test('anything but 200 (an expired signed URL is a 403) is DownloadFailed', () async {
    await expectLater(t.download(at('/expired'), File('${tmp.path}\\b.bin')),
        throwsA(isA<DownloadFailed>().having((e) => e.reason, 'reason', 'HTTP 403')));
  });

  test('a server that stops sending is DownloadFailed, not a hang, and the file is not left open', () async {
    final f = File('${tmp.path}\\c.bin');
    await expectLater(t.download(at('/stall'), f), throwsA(isA<DownloadFailed>()));
    f.deleteSync(); // fails on Windows if the sink were still open
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('nobody listening is DownloadFailed', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await expectLater(t.download(Uri.parse('http://127.0.0.1:$port/x'), File('${tmp.path}\\d.bin')),
        throwsA(isA<DownloadFailed>()));
  }, timeout: const Timeout(Duration(seconds: 20)));
}
