import 'package:flutter/services.dart';

export 'src/alpha_video_controller.dart';

class AlphaVideo {
  static const MethodChannel _channel = MethodChannel('aipet.alpha_video/methods');

  static Future<int> abiVersion() async =>
      await _channel.invokeMethod<int>('abiVersion') ?? 0;

  static Future<int> prepare({
    required String source,
    required String destination,
    int targetEdge = 720,
  }) async =>
      await _channel.invokeMethod<int>('prepare', {
        'source': source,
        'destination': destination,
        'targetEdge': targetEdge,
      }) ??
      -99;
}
