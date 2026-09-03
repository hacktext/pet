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

  Future<int> currentFrame() async =>
      await channel.invokeMethod<int>('currentFrame', {'textureId': textureId}) ?? 0;
}
