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

  test('only cats and dogs can be ordered for now (generation spec 2 / 9)', () {
    final m = model();
    expect(m.category, Category.cat);
    m.setGroup(Group.people);
    expect((m.group, m.category), (Group.pets, Category.cat));
    m.setCategory(Category.other);
    expect(m.category, Category.cat);
    m.setCategory(Category.girl);
    expect(m.category, Category.cat);
    m.setCategory(Category.dog);
    expect(m.category, Category.dog);
    expect(isGroupOpen(Group.pets), isTrue);
    expect(isGroupOpen(Group.people), isFalse);
    expect([for (final c in Category.values) if (isOpenForCustom(c)) c], [Category.dog, Category.cat]);
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

  test('two overlapping addPhotos never exceed 3; no submit while adding', () async {
    final m = model()..setName('豆豆');
    picks = [for (var i = 1; i <= 3; i++) PickedFile('p$i.jpg', [i])];
    final a = m.addPhotos();
    expect(m.busy, isTrue);
    expect(m.canSubmit, isFalse);
    final b = m.addPhotos();
    await Future.wait([a, b]);
    expect(m.photos, hasLength(3));
    expect(await (() async { m.removePhoto(0); return m.photos.length; })(), 2);
    picks = [for (var i = 4; i <= 6; i++) PickedFile('p$i.jpg', [i])];
    final c = m.addPhotos();
    expect(await m.submit(), isNull);
    expect(http.to('/api/aipet/custom/requests'), isEmpty);
    await c;
    expect(m.photos, hasLength(3));
  });

  test('a double submit without awaiting posts once', () async {
    final m = model()..setName('豆豆');
    picks = [const PickedFile('a.jpg', [1])];
    await m.addPhotos();
    final r = await Future.wait([m.submit(), m.submit()]);
    expect(r.where((e) => e != null), hasLength(1));
    expect(http.to('/api/aipet/custom/requests'), hasLength(1));
  });

  test('a picker that throws gives a message, not an error', () async {
    deps = CustomDeps(
        service: deps.service, uploader: deps.uploader, pick: () async => throw Exception('x'), prep: deps.prep);
    final m = model();
    await m.addPhotos();
    expect(m.message, '无法读取所选文件');
    expect(m.busy, isFalse);
  });

  test('a model disposed mid-add does not notify afterwards', () async {
    final m = model();
    picks = [const PickedFile('a.jpg', [1])];
    final f = m.addPhotos();
    m.dispose();
    await f;
  });

  testWidgets('page: counter, chips (人物 and 其他宠物 coming soon), disabled button until ready, submitted callback',
      (tester) async {
    // Tall enough that the ListView builds 下一步 too.
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    CustomRequestInfo? done;
    picks = [const PickedFile('a.jpg', [1])];
    await tester.pumpWidget(MaterialApp(home: CustomFormPage(deps: deps, onSubmitted: (_, r) => done = r)));
    expect(find.text('定制你的专属宠物'), findsOneWidget);
    expect(find.text('0/8'), findsOneWidget);
    for (final t in ['宠物', '人物', '猫咪', '狗狗', '其他宠物', '点击上传照片']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('即将开放'), findsNWidgets(2)); // on 人物 and on 其他宠物
    FilledButton next() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '下一步'));
    expect(next().onPressed, isNull);
    await tester.enterText(find.byType(TextField), '豆豆');
    await tester.tap(find.text('点击上传照片'));
    await tester.pumpAndSettle();
    expect(find.text('2/8'), findsOneWidget);
    expect(next().onPressed, isNotNull);
    await tester.tap(find.text('人物'), warnIfMissed: false);
    await tester.tap(find.text('其他宠物'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('女生'), findsNothing); // still on 宠物
    await tester.tap(find.text('狗狗'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '下一步'));
    await tester.pumpAndSettle();
    expect(done!.species.name, 'dog');
  });
}
