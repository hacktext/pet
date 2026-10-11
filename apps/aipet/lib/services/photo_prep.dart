import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class PhotoPrepError implements Exception {
  const PhotoPrepError();

  @override
  String toString() => 'PhotoPrepError';
}

/// Any JPEG/PNG the user picked, upright, no longer than [maxSide] on its
/// long side, as a JPEG (custom order spec 3). Whatever the decoder throws on
/// a damaged file is a [PhotoPrepError].
Uint8List prepPhoto(List<int> bytes, {int maxSide = 2048, int quality = 88}) {
  try {
    final decoded = img.decodeImage(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    if (decoded == null) throw const PhotoPrepError();
    var image = img.bakeOrientation(decoded);
    if (image.width > maxSide || image.height > maxSide) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
          : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
    }
    return img.encodeJpg(image, quality: quality);
  } on PhotoPrepError {
    rethrow;
  } catch (_) {
    throw const PhotoPrepError();
  }
}

/// [prepPhoto] off the UI isolate, which shares the platform thread (HANDOFF
/// pitfall 2): decoding a 12 MP photo takes long enough to freeze the window.
Future<Uint8List> prepPhotoInBackground(List<int> bytes) => Isolate.run(() => prepPhoto(bytes));
