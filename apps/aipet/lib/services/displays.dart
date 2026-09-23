import 'dart:developer' as developer;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';

/// Physical pixels per logical pixel of this engine's window (what
/// window_manager itself multiplies by).
double physicalScale() => PlatformDispatcher.instance.views.first.devicePixelRatio;

/// The work area (logical pixels, taskbar excluded) of the display holding
/// [window]'s centre; the primary display's if none does; null if unknown.
Future<Rect?> displayWorkArea(Rect window) async {
  try {
    Rect area(Display d) => (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);
    for (final d in await screenRetriever.getAllDisplays()) {
      if (area(d).contains(window.center)) return area(d);
    }
    return area(await screenRetriever.getPrimaryDisplay());
  } catch (e) {
    // Logged, not just swallowed: a null here reads the same whether no
    // display holds the window or the platform channel is broken, and this
    // is glue that can only be debugged on a real machine.
    developer.log('work area unavailable: $e', name: 'aipet.displays');
    return null;
  }
}
