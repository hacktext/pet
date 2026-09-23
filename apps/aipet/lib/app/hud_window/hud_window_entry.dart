import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/hud_layout.dart';
import '../../services/displays.dart';
import '../../services/hud_bridge.dart';
import '../../services/native_window.dart';
import '../../services/window_bridge.dart';
import 'hud_panel.dart';

/// Arguments string that makes an engine the status panel.
const kHudWindowArgs = 'hud_window';
const kHudTitle = 'aipet hud';

/// The panel engine (spec 2026-09-19 E 3.1): created hidden by the pet
/// window, shown next to it WITHOUT taking focus (NativeWindow, never
/// windowManager.show), hidden again on request.
Future<void> runHudWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: kHudSize,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      title: kHudTitle,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setHasShadow(false);
      await windowManager.setResizable(false);
    },
  );
  final view = ValueNotifier<HudView?>(null);
  NativeWindow? native;
  final bridge = HudWindowBridge(
    WindowChannelTransport(kHudChannel),
    onShow: (pet, v) async {
      view.value = v;
      native ??= NativeWindow.find(kHudTitle);
      final work = await displayWorkArea(pet) ?? pet.inflate(kHudSize.longestSide);
      final p = hudPosition(pet, kHudSize, work);
      final s = physicalScale();
      native?.showAt((p.dx * s).round(), (p.dy * s).round());
    },
    onUpdate: (v) => view.value = v,
    onHide: () => windowManager.hide(),
  )..start();
  runApp(HudApp(view: view, bridge: bridge));
}

class HudApp extends StatelessWidget {
  const HudApp({super.key, required this.view, required this.bridge});

  final ValueNotifier<HudView?> view;
  final HudWindowBridge bridge;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: MouseRegion(
            onEnter: (_) => bridge.hover(true),
            onExit: (_) => bridge.hover(false),
            child: ValueListenableBuilder<HudView?>(
              valueListenable: view,
              builder: (_, v, _) => v == null
                  ? const SizedBox.shrink()
                  : HudPanel(view: v, onAction: bridge.action, onClose: bridge.close),
            ),
          ),
        ),
      );
}
