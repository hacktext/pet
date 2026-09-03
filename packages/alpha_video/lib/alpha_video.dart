import 'package:flutter/services.dart';

export 'src/alpha_video_controller.dart';
export 'src/alpha_video_view.dart';

class AlphaVideo {
  static const MethodChannel _channel = MethodChannel('aipet.alpha_video/methods');

  static Future<int> abiVersion() async =>
      await _channel.invokeMethod<int>('abiVersion') ?? 0;

  // Throws PlatformException (code "prepare_failed") if the native side
  // reports a nonzero pet_matte_prepare() result -- the plugin surfaces
  // that as MethodChannel.Error rather than a bare int, so callers can no
  // longer forget to check a return code and mistake a failure (e.g. a
  // mid-stream decode error whose cache must not be trusted) for success.
  static Future<int> prepare({
    required String source,
    required String destination,
    int targetEdge = 720,
  }) async {
    final code = await _channel.invokeMethod<int>('prepare', {
      'source': source,
      'destination': destination,
      'targetEdge': targetEdge,
    });
    return code ?? 0;
  }
}
