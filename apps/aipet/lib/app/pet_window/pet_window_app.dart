import 'dart:async';

import 'package:alpha_video/alpha_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/pet.dart';
import '../../services/app_paths.dart';
import '../../services/matte_cache.dart';
import '../../services/pet_library.dart';
import '../../services/settings_store.dart';
import '../../services/window_bridge.dart';
import 'clip_player.dart';
import 'close_policy.dart';
import 'library_launcher.dart';
import 'pet_window_controller.dart';

/// Primary engine: builds the services, boots, and opens the library on a
/// first run (spec 3.3).
Future<void> runPetWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(360, 360),
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'aipet pet',
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setHasShadow(false);
      // WM_CLOSE -> onWindowClose -> quit, so clips are torn down before the
      // engine (pet_shell's I-7 lesson). Shown only once there is a pet.
      await windowManager.setPreventClose(true);
    },
  );

  final appData = appDataRoot();
  final cache = MatteCache(
    root: matteCacheRoot(appData),
    prepare: ({required source, required destination}) =>
        AlphaVideo.prepare(source: source, destination: destination, targetEdge: 720),
  );
  final player = AlphaClipPlayer();
  final launcher = LibraryLauncher();
  late final PetWindowBridge bridge;
  final controller = PetWindowController(
    library: PetLibrary(builtinRoot: builtinPetsRoot(), customRoot: customPetsRoot(appData)),
    settings: SettingsStore(appData),
    ensure: cache.ensure,
    player: player,
    push: (s) => bridge.pushState(s),
  );

  var quitting = false;
  Future<void> quit() async {
    if (quitting) return;
    quitting = true;
    try {
      await player.dispose();
      await trayManager.destroy();
    } finally {
      await windowManager.destroy(); // ends the process, sub-window engine included
    }
  }

  final closePolicy = ClosePolicy(
    state: () => controller.state,
    hasPet: () => controller.currentPet != null,
    changes: controller,
    quit: quit,
    reopenLibrary: launcher.open,
  );
  bridge = PetWindowBridge(
    WindowChannelTransport(),
    state: () => controller.state,
    onAdopt: controller.adopt,
    onMainWindowClosing: closePolicy.libraryClosing,
    onQuit: quit,
  )..start();

  runApp(PetWindowApp(controller: controller, player: player, launcher: launcher, onQuit: quit));
  await controller.boot();
  if (controller.currentPet == null) await launcher.open();
}

class PetWindowApp extends StatefulWidget {
  const PetWindowApp({
    super.key,
    required this.controller,
    required this.player,
    required this.launcher,
    required this.onQuit,
  });

  final PetWindowController controller;
  final AlphaClipPlayer player;
  final LibraryLauncher launcher;
  final Future<void> Function() onQuit;

  @override
  State<PetWindowApp> createState() => _PetWindowAppState();
}

class _PetWindowAppState extends State<PetWindowApp> with TrayListener, WindowListener {
  bool? _visible;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    widget.controller.addListener(_syncVisibility);
    // runApp() defers mounting this State to a later event-loop turn, but
    // controller.boot() runs synchronously up to its first notifyListeners()
    // -- for a fresh, no-pet run that call fires before this listener is
    // registered, so the starting state would otherwise never reach us. Sync
    // once after the first frame so we pick up whatever boot() already
    // decided.
    SchedulerBinding.instance.addPostFrameCallback((_) => _syncVisibility());
    unawaited(_setUpTray());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncVisibility);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _setUpTray() async {
    await trayManager.setIcon('assets/tray.ico');
    await trayManager.setToolTip('aipet');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: '打开宠物库'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
  }

  void _syncVisibility() {
    final want = widget.controller.currentPet != null;
    if (want == _visible) return;
    _visible = want;
    unawaited(want ? windowManager.show() : windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() => widget.launcher.open();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') widget.launcher.open();
    if (menuItem.key == 'quit') widget.onQuit();
  }

  @override
  void onWindowClose() => widget.onQuit();

  Future<void> _showMenu(BuildContext ctx, Offset at) async {
    final c = widget.controller;
    final pet = c.currentPet;
    final overlay = Overlay.of(ctx).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        if (pet != null) ...[
          for (final a in pet.actions)
            CheckedPopupMenuItem<String>(
                value: 'action:$a', checked: a == c.currentAction, height: 36, child: Text(labelFor(a))),
          const PopupMenuDivider(),
        ],
        const PopupMenuItem<String>(value: 'open', height: 36, child: Text('打开宠物库')),
        const PopupMenuItem<String>(value: 'quit', height: 36, child: Text('退出')),
      ],
    );
    if (choice == null) return;
    if (choice == 'open') return widget.launcher.open();
    if (choice == 'quit') return widget.onQuit();
    await c.playAction(choice.substring('action:'.length));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          // Builder: showMenu needs a context below MaterialApp (Navigator, Overlay).
          body: Builder(
            builder: (ctx) => GestureDetector(
              onPanStart: (_) => windowManager.startDragging(),
              onSecondaryTapUp: (d) => _showMenu(ctx, d.globalPosition),
              child: Stack(alignment: Alignment.center, children: [
                ValueListenableBuilder<AlphaVideoController?>(
                  valueListenable: widget.player.controller,
                  builder: (_, vc, _) => vc == null ? const SizedBox.shrink() : AlphaVideoView(controller: vc),
                ),
                ListenableBuilder(
                  listenable: widget.controller,
                  builder: (_, _) {
                    final e = widget.controller.error;
                    if (e == null) return const SizedBox.shrink();
                    return Positioned(
                      bottom: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: const Color(0xCC3D2B1F), borderRadius: BorderRadius.circular(10)),
                        child: Text(e, style: const TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    );
                  },
                ),
              ]),
            ),
          ),
        ),
      );
}
