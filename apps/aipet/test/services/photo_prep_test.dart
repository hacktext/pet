import 'dart:typed_data';

import 'package:aipet/services/photo_prep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('a big PNG comes back as a JPEG no longer than 2048 on its long side', () {
    final png = img.encodePng(img.Image(width: 3000, height: 1000));
    final out = img.decodeJpg(prepPhoto(png))!;
    expect(out.width, 2048);
    expect(out.height, closeTo(683, 1));
  });

  test('a small photo keeps its size', () {
    final out = img.decodeJpg(prepPhoto(img.encodeJpg(img.Image(width: 800, height: 600))))!;
    expect((out.width, out.height), (800, 600));
  });

  test('bytes that are not an image are PhotoPrepError', () {
    expect(() => prepPhoto([1, 2, 3, 4]), throwsA(isA<PhotoPrepError>()));
  });

  test('garbage that looks like a JPEG or PNG header is still only PhotoPrepError', () {
    final jpegHead = [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 9, 9, 9, 9, 9, 9];
    final pngHead = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 7, 7];
    for (final bytes in [jpegHead, pngHead, List<int>.generate(500, (i) => (i * 37) % 256), <int>[]]) {
      expect(() => prepPhoto(bytes), throwsA(isA<PhotoPrepError>()));
    }
  });

  test('prepPhotoInBackground gives the same result off the calling isolate', () async {
    final png = img.encodePng(img.Image(width: 2500, height: 2500));
    final out = img.decodeJpg(Uint8List.fromList(await prepPhotoInBackground(png)))!;
    expect((out.width, out.height), (2048, 2048));
  });
}
