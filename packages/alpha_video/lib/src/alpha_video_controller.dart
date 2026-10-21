import 'package:flutter/services.dart';

const MethodChannel channel = MethodChannel('aipet.alpha_video/methods');

class AlphaVideoController {
  AlphaVideoController._(this.textureId, this.width, this.height, this.frameCount);

  final int textureId;
  final int width;
  final int height;
  final int frameCount;

  static Future<AlphaVideoController> open(String aipmatPath) async {
    final m = await channel.invokeMapMethod<String, dynamic>('open', {'path': aipmatPath});
    if (m == null) throw PlatformException(code: 'open_failed', message: aipmatPath);
    return AlphaVideoController._(
        m['textureId'] as int, m['width'] as int, m['height'] as int, m['frameCount'] as int);
  }

  Future<void> dispose() => channel.invokeMethod('dispose', {'textureId': textureId});

  Future<void> play({bool loop = true}) =>
      channel.invokeMethod('play', {'textureId': textureId, 'loop': loop});

  Future<void> pause() => channel.invokeMethod('pause', {'textureId': textureId});

  /// Whether the frame last drawn is opaque within [radius] (a fraction of
  /// the frame's width) of ([u], [v]), both 0..1 from the top-left. False
  /// before the first frame is drawn.
  Future<bool> opaqueAt(double u, double v, {double radius = 0}) async =>
      await channel.invokeMethod<bool>('opaqueAt', {'textureId': textureId, 'u': u, 'v': v, 'radius': radius}) ??
      false;

  Future<int> currentFrame() async =>
      await channel.invokeMethod<int>('currentFrame', {'textureId': textureId}) ?? 0;
}
