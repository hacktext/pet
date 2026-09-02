import 'package:flutter/services.dart';

class AlphaVideo {
  static const MethodChannel _channel = MethodChannel('aipet.alpha_video/methods');

  static Future<int> abiVersion() async {
    final v = await _channel.invokeMethod<int>('abiVersion');
    return v ?? 0;
  }
}
