import 'package:aipet/app/main_window/custom_flow/custom_deps.dart';
import 'package:aipet/app/main_window/custom_flow/custom_form_model.dart';
import 'package:aipet/app/main_window/custom_flow/custom_form_page.dart';
import 'package:aipet/domain/custom_order.dart';
import 'package:aipet/domain/library_state.dart';
import 'package:aipet/services/api_client.dart';
import 'package:aipet/services/custom_service.dart';
import 'package:aipet/services/oss_uploader.dart';
import 'package:aipet/services/photo_prep.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_http.dart';
import '../support/fake_oss.dart';

void main() {
  late FakeHttp http;
  late FakeOss oss;
  late List<PickedFile> picks;
  late CustomDeps deps;
  var ticketSeq = 0;

  setUp(() {
    http = FakeHttp();
    oss = FakeOss();
    picks = [];
    ticketSeq = 0;
    http.reply = (r) {
      if (r.url.path == '/api/aipet/custom/upload-tickets') {
        final n = r.json['count']! as int;
        return FakeHttp.ok([
          for (var i = 0; i < n; i++)
            {'key': 'k${++ticketSeq}', 'url': 'https://b.oss', 'fields': {'key': 'k$ticketSeq'}}
        ]);
      }
      if (r.url.path == '/api/aipet/custom/requests') {
        return FakeHttp.ok({'id': 5, 'name': r.json['name'], 'species': r.json['species'], 'status': 'draft'});
      }
      return FakeHttp.ok(null);
    };
    deps = CustomDeps(
      service: CustomService(ApiClient(http, baseUrl: 'https://x', token: () => 't')),
      uploader: OssUploader(oss),
      pick: () async => picks,
      prep: (b) async => b.first == 0 ? throw const PhotoPrepError() : b,
    );
  });

  CustomFormModel model() => CustomFormModel(deps);

  test('name: trimmed, 1–8 characters, an emoji counts as one', () {
    final m = model();
    m.setName('   ');
    expect(m.nameLength, 0);
    expect(m.canSubmit, isFalse);
    m.setName('一二三四五六七八九');
    expect(m.nameLength, 9);
    expect(m.nameError, '名字最多 8 个字');
    m.setName('豆豆🐶');
    expect(m.nameLength, 3);
    expect(m.nameError, isNull);
  });

  test('photos: at most 3 even from a bigger pick; unreadable ones are left out with a message', () async {
    final m = model();
    picks = [for (var i = 1; i <= 5; i++) PickedFile('p$i.jpg', [i])];
    await m.addPhotos();
    expect(m.photos.map((p) => p.name), ['p1.jpg', 'p2.jpg', 'p3.jpg']);
    expect(m.message, '最多 3 张照片');
    m.removePhoto(0);
    picks = [const PickedFile('bad.jpg', [0])];
    await m.addPhotos();
    expect(m.photos, hasLength(2));
    expect(m.message, '无法读取图片：bad.jpg');
  });

  test('switching group picks its first real sub-category', () {
    final m = model();
    expect(m.category, Category.cat);
    m.setGroup(Group.people);
    expect(m.category, Category.girl);
    m.setCategory(Category.anime);
    expect(m.category.species!.name, 'anime');
  });

  test('submit uploads every photo then creates the request', () async {
    final m = model()..setName(' 豆豆 ');
    picks = [const PickedFile('a.jpg', [1]), const PickedFile('b.jpg', [2])];
    await m.addPhotos();
    final r = await m.submit();
    expect(r!.id, 5);
    expect(oss.posts.map((p) => p.$2['key']), ['k1', 'k2']);
    expect(http.to('/api/aipet/custom/requests').single.json,
        {'name': '豆豆', 'species': 'cat', 'photo_keys': ['k1', 'k2']});
  });

  test('a failed upload is retried alone; photos already up are not sent again', () async {
    final m = model()..setName('豆豆');
    picks = [const PickedFile('a.jpg', [1]), const PickedFile('b.jpg', [2]), const PickedFile('c.jpg', [3])];
    await m.addPhotos();
    oss.reply = (_, f) => f['key'] == 'k2' ? 500 : 204;
    expect(await m.submit(), isNull);
    expect(m.message, '第 2 张上传失败，请重试');
    expect(m.photos[1].failed, isTrue);
    expect(m.busy, isFalse);
    oss.reply = (_, _) => 204;
    final r = await m.submit();
    expect(r, isNotNull);
    expect(http.to('/api/aipet/custom/upload-tickets').map((s) => s.json['count']), [3, 2]);
    expect(http.to('/api/aipet/custom/requests').single.json['photo_keys'], ['k1', 'k4', 'k5']);
  });

  test('server refusals land where they belong; 401 says to sign in again', () async {
    final m = model()..setName('豆豆');
    picks = [const PickedFile('a.jpg', [1])];
    await m.addPhotos();
    http.reply = (r) => r.url.path.endsWith('upload-tickets')
        ? FakeHttp.ok([{'key': 'k', 'url': 'https://b', 'fields': {'key': 'k'}}])
        : FakeHttp.fail(5010, '名字需要 1–8 个字', {'field': 'name'});
    expect(await m.submit(), isNull);
    expect(m.nameError, '名字需要 1–8 个字');
    http.reply = (_) => FakeHttp.fail(1003, 'x', null, 401);
    expect(await m.submit(), isNull);
    expect(m.message, '登录已过期，请重新登录');
  });

  test('a 5010 on species is shown under the category', () async {
    final m = model()..setName('豆豆');
    picks = [const PickedFile('a.jpg', [1])];
    await m.addPhotos();
    http.reply = (r) => r.url.path.endsWith('upload-tickets')
        ? FakeHttp.ok([{'key': 'k', 'url': 'https://b', 'fields': {'key': 'k'}}])
        : FakeHttp.fail(5010, '暂不支持该类别', {'field': 'species'});
    expect(await m.submit(), isNull);
    expect(m.categoryError, '暂不支持该类别');
    m.setCategory(Category.dog);
    expect(m.categoryError, isNull);
  });

  testWidgets('page: counter, chips, disabled button until ready, submitted callback', (tester) async {
    // Tall enough that the ListView builds 下一步 too.
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    CustomRequestInfo? done;
    picks = [const PickedFile('a.jpg', [1])];
    await tester.pumpWidget(MaterialApp(home: CustomFormPage(deps: deps, onSubmitted: (_, r) => done = r)));
    expect(find.text('定制你的专属宠物'), findsOneWidget);
    expect(find.text('0/8'), findsOneWidget);
    for (final t in ['宠物', '人物', '猫猫', '狗狗', '其他宠物', '点击上传照片']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    FilledButton next() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '下一步'));
    expect(next().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '豆豆');
    await tester.tap(find.text('点击上传照片'));
    await tester.pumpAndSettle();
    expect(find.text('2/8'), findsOneWidget);
    expect(next().onPressed, isNotNull);
    await tester.tap(find.text('人物'));
    await tester.pump();
    expect(find.text('女生'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '下一步'));
    await tester.pumpAndSettle();
    expect(done!.species.name, 'girl');
  });
}
