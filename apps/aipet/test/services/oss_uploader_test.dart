import 'dart:convert';

import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_oss.dart';

void main() {
  test('multipart: the fields in order, then the file last', () {
    final body = latin1.decode(buildMultipart('BB', {'key': 'k/1.jpg', 'policy': 'P'},
        fileField: 'file', filename: 'a.jpg', contentType: 'image/jpeg', bytes: [1, 2, 3]));
    expect(body.indexOf('name="key"'), lessThan(body.indexOf('name="policy"')));
    expect(body.indexOf('name="policy"'), lessThan(body.indexOf('name="file"')));
    expect(body, contains('--BB\r\nContent-Disposition: form-data; name="key"\r\n\r\nk/1.jpg\r\n'));
    expect(body, contains('name="file"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\n\x01\x02\x03\r\n'));
    expect(body, endsWith('--BB--\r\n'));
  });

  const ticket = UploadTicket(
      key: 'aipet/custom/1/u.jpg',
      url: 'https://b.oss-cn.aliyuncs.com',
      fields: {'key': 'aipet/custom/1/u.jpg', 'policy': 'P'});

  test('posts the ticket fields to the ticket url; 204 is success', () async {
    final oss = FakeOss();
    await OssUploader(oss).upload(ticket, [9, 9]);
    final (url, fields, size) = oss.posts.single;
    expect(url.toString(), 'https://b.oss-cn.aliyuncs.com');
    expect(fields, ticket.fields);
    expect(size, 2);
  });

  test('a refusal or a network failure is OssUploadFailed', () async {
    final oss = FakeOss()..reply = (_, _) => 403;
    await expectLater(OssUploader(oss).upload(ticket, [1]),
        throwsA(isA<OssUploadFailed>().having((e) => e.status, 'status', 403)));
    oss.reply = (_, _) => throw Exception('down');
    await expectLater(OssUploader(oss).upload(ticket, [1]),
        throwsA(isA<OssUploadFailed>().having((e) => e.status, 'status', -1)));
  });
}
