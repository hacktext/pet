import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:alpha_video/alpha_video.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../domain/pet_size.dart';
import '../../domain/walker.dart';
import '../../services/account_store.dart';
import '../../services/api_client.dart';
import '../../services/app_paths.dart';
import '../../services/device_identity.dart';
import '../../services/custom_downloader.dart';
import '../../services/file_download.dart';
import '../../services/hud_bridge.dart';
import '../../services/matte_cache.dart';
import '../../services/pet_library.dart';
import '../../services/pet_size_store.dart';
import '../../services/settings_store.dart';
import '../../services/stats_store.dart';
import '../../services/sync_service.dart';
import '../../services/telemetry_queue.dart';
import '../../services/voice_player.dart';
import '../../services/voice_store.dart';
import '../../services/window_bridge.dart';
import '../hud_window/hud_window_entry.dart';
import 'account_keeper.dart';
import 'app_exit.dart';
import 'clip_player.dart';
import 'close_policy.dart';
import 'companion.dart';
import 'library_launcher.dart';
import 'pet_dragger.dart';
import 'pet_menu.dart';
import 'pet_sync_local.dart';
import 'pet_window_controller.dart';
import 'stats_keeper.dart';
import 'walk_driver.dart';
import 'window_mover.dart';

/// The pet window's title; what NativeWindow finds it by (spec 3.1).
const kPetTitle = 'aipet pet';

/// Primary engine: builds the services, boots, and opens the library on a
/// first run (spec 3.3).
Future<void> runPetWindow() async {
  final appData = appDataRoot();
  final sizes = PetSizeStore(appData);
  final size = sizes.load();

  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: Size.square(size.edge),
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      title: kPetTitle,
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

  // The web platform (spec 2026-10-02 8): usage events, the account and sync.
  // All of it is asynchronous and best effort -- offline, the app behaves
  // exactly as it did without it.
  final device = DeviceIdentity(appData);
  late final AccountKeeper account;
  late final SyncService sync;
  final api = ApiClient(IoHttpTransport(), token: () => account.token, onUnauthorized: () => account.expired());
  final telemetry = TelemetryQueue(appData, send: (events) => api.events(device.id, events));

  final cache = MatteCache(
    root: matteCacheRoot(appData),
    prepare: ({required source, required destination}) =>
        AlphaVideo.prepare(source: source, destination: destination, targetEdge: kMatteTargetEdge),
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
    onAdopted: (id, firstTime) => telemetry.track(firstTime ? 'pet_adopt' : 'pet_switch', petId: id),
  );

  // Delivered custom pets (generation spec 6.1). This window is the only
  // writer of pets/; the library only asks it to look.
  final downloads = CustomDownloader(
    api: api,
    transport: IoDownloadTransport(),
    petsRoot: customPetsRoot(appData),
    signedIn: () => account.signedIn,
    onInstalled: (ready) async {
      // Must not throw: the pets are installed, and a throw here would leave
      // them unannounced. Each step is guarded so one failure spares the other.
      try {
        controller.rescan();
      } catch (e) {
        developer.log('rescan after install failed: $e', name: 'aipet.custom');
      }
      try {
        await bridge.pushReady([for (final d in ready) ReadyPet(petId: d.petId, name: d.name)]);
      } catch (e) {
        developer.log('announcing ready pets failed: $e', name: 'aipet.custom');
      }
    },
  );

  final mover = DesktopWindowMover(kPetTitle);
  final stats = StatsKeeper(StatsStore(appData), onSaved: () => sync.statsChanged());
  final voices = VoiceStore(appData);
  final walker = WalkDriver(mover, facing: () => controller.currentPet?.walkFacing ?? Facing.right);
  final companion = Companion(
    pets: controller,
    stats: stats,
    walker: walker,
    mover: mover,
    hudTransport: WindowChannelTransport(kHudChannel),
    voices: voices,
    voicePlayer: platformVoicePlayer(),
    onInteract: (id, kind) => telemetry.track('interact', petId: id, props: {'kind': kind}),
    onVoiceChosen: (id, voice) {
      telemetry.track('voice_change', petId: id, props: {'voice': voice});
      sync.voiceChanged();
    },
  );
  final syncLocal = PetSyncLocal(pets: controller, stats: stats, voices: voices);
  sync = SyncService(
    appData,
    api: api,
    local: syncLocal,
    signedIn: () => account.signedIn,
    settingsFile: SettingsStore(appData).file,
    voiceFile: File('${appData.path}${Platform.pathSeparator}voice.json'),
  );
  account = AccountKeeper(
    store: AccountStore(appData),
    api: api,
    sync: sync,
    track: telemetry.track,
    deviceId: device.id,
    deviceName: _deviceName(),
    push: (v) => bridge.pushAccount(v),
    onSynced: () => unawaited(downloads.run()),
  );
  // Below the account: both calls carry its token when there is one, which
  // binds this device (and its events) to the user on the server.
  unawaited(api.hello(deviceId: device.id, os: _osName(), appVersion: kAppVersion));
  telemetry.track('app_start', props: {'version': kAppVersion});
  telemetry.start();
  final heartbeat = Timer.periodic(const Duration(minutes: 10), (_) => telemetry.track('heartbeat'));
  final statsTicker = Timer.periodic(const Duration(minutes: 1), (_) {
    stats.tick();
    unawaited(account.tick());
  });

  final quit = AppExit(
    // Off the screen first: the native teardown after destroy() takes seconds.
    hide: [companion.shutdown, windowManager.hide, launcher.hideIfOpen],
    // Clips are torn down before the engine (pet_shell's I-7 lesson).
    release: [
      player.dispose,
      trayManager.destroy,
      () async {
        statsTicker.cancel();
        heartbeat.cancel();
        telemetry.dispose(); // unsent events wait in telemetry.jsonl for the next launch
      },
    ],
    destroy: windowManager.destroy, // ends the process, sub-window engine included
  ).quit;

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
    account: account,
    onRefreshCustom: downloads.run,
  )..start();

  runApp(PetWindowApp(
    controller: controller,
    player: player,
    launcher: launcher,
    onQuit: quit,
    companion: companion,
    walker: walker,
    dragger: platformDragger(mover),
    mover: mover,
    sizes: sizes,
    initialSize: size,
  ));
  // The panel engine, created once and kept hidden; without it the pet
  // window works as before (spec 2026-09-19 E 4). The two engines are
  // independent, so this goes before boot(): a cold first run mattes its clip
  // in there, up to kPrepareTimeout, and the pet window is on screen and
  // hoverable the whole time.
  unawaited(WindowController.create(WindowConfiguration(arguments: kHudWindowArgs, hiddenAtLaunch: true))
      .then<void>((_) {}, onError: (Object e) => developer.log('panel window failed: $e', name: 'aipet.hud')));
  await controller.boot();
  // After boot: loading settings.json is not the user changing them.
  syncLocal.watchSettings(sync.settingsChanged);
  account.start();
  unawaited(downloads.run()); // after boot: a pet installed now is scanned on top of boot's list
  if (controller.currentPet == null) await launcher.open();
}

/// For device/hello, e.g. `Windows "Windows 11 Pro" 10.0 (Build 26200)` or
/// `macOS Version 15.1 (Build 24B83)`.
String _osName() => '${_platformName()} ${Platform.operatingSystemVersion}';

String _platformName() => Platform.isMacOS ? 'macOS' : 'Windows';

/// The token's name on the server: this computer's name.
String _deviceName() {
  try {
    return Platform.localHostname;
  } catch (_) {
    return _platformName();
  }
}

class PetWindowApp extends StatefulWidget {
  const PetWindowApp({
    super.key,
    required this.controller,
    required this.player,
    required this.launcher,
    required this.onQuit,
    required this.companion,
    required this.walker,
    required this.dragger,
    required this.mover,
    required this.sizes,
    required this.initialSize,
  });

  final PetWindowController controller;
  final AlphaClipPlayer player;
  final LibraryLauncher launcher;
  final Future<void> Function() onQuit;
  final Companion companion;
  final WalkDriver walker;
  final WindowDragger dragger;
  final WindowMover mover;
  final PetSizeStore sizes;
  final PetSize initialSize;

  @override
  State<PetWindowApp> createState() => _PetWindowAppState();
}

class _PetWindowAppState extends State<PetWindowApp> with TrayListener, WindowListener {
  bool? _visible;
  late PetSize _size = widget.initialSize;

  /// Where the pet is drawn inside its window while the window has grown to
  /// make room for the menu; null when the window is the pet.
  Offset? _inset;

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
    // The menu bar wants a PNG; the Windows tray an .ico.
    await trayManager.setIcon(Platform.isMacOS ? 'assets/tray.png' : 'assets/tray.ico');
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
    final pet = await _growForMenu();
    if (!ctx.mounted) return;
    final PetMenuPick? pick;
    try {
      pick = await showPetMenu(
        ctx,
        at: at + (_inset ?? Offset.zero),
        actions: c.currentPet?.actions ?? const [],
        currentAction: c.currentAction,
        voices: widget.companion.availableVoices,
        currentVoice: widget.companion.currentVoice,
        currentSize: _size,
      );
    } finally {
      // Back to the pet's own rectangle before anything picked runs: a walk
      // or a resize starts from the window's bounds.
      if (pet != null) _place(pet, inset: null);
    }
    switch (pick) {
      case null:
        return;
      case PetMenuOpenLibrary():
        await widget.launcher.open();
      case PetMenuQuit():
        await widget.onQuit();
      case PetMenuAction(:final action):
        await widget.companion.userAction(action);
      case PetMenuVoice(:final voice):
        widget.companion.chooseVoice(voice);
      case PetMenuSize(:final size):
        await _resize(size);
    }
  }

  /// A pet smaller than the menu's room gets a window of [kPetMenuRoom] while
  /// the menu is up, with the pet drawn where it was; returns the pet's own
  /// rectangle to go back to, or null when the window was left alone.
  Future<Rect?> _growForMenu() async {
    if (_size.edge >= kPetMenuRoom) return null;
    try {
      // First: a walk would slide the grown window as if it were the pet.
      widget.walker.stop();
      final pet = await widget.mover.bounds();
      final room = menuRoomFor(pet, await widget.mover.workArea(pet));
      if (!mounted) return null;
      _place(room, inset: pet.topLeft - room.topLeft);
      return pet;
    } catch (e) {
      // The menu still opens, only cramped into the pet's own window.
      developer.log('making room for the menu failed: $e', name: 'aipet.pet_window');
      return null;
    }
  }

  /// The pet's new size, its feet where they were; remembered for next time.
  Future<void> _resize(PetSize size) async {
    if (size == _size) return;
    try {
      widget.walker.stop(); // a walk keeps the width it started with
      final pet = await widget.mover.bounds();
      if (!mounted) return;
      _size = size;
      _place(resizedPet(pet, size), inset: null);
      widget.sizes.save(size);
    } catch (e) {
      developer.log('resizing the pet failed: $e', name: 'aipet.pet_window');
    }
  }

  /// The window to [window] with the pet drawn at [inset] inside it. The
  /// state first, then the window, in one go: the frame drawn for the new
  /// size already has the pet where it belongs.
  void _place(Rect window, {required Offset? inset}) {
    setState(() => _inset = inset);
    widget.mover.setBounds(window);
  }

  /// The pet fills its window, or sits at [_inset] while the window has
  /// grown for the menu.
  Widget _petAt(Widget pet) {
    final inset = _inset;
    if (inset == null) return pet;
    return Positioned(left: inset.dx, top: inset.dy, width: _size.edge, height: _size.edge, child: pet);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          // Builder: showMenu needs a context below MaterialApp (Navigator, Overlay).
          body: Builder(
            builder: (ctx) => MouseRegion(
              onEnter: (_) => widget.companion.petEnter(),
              onExit: (_) => widget.companion.petExit(),
              child: GestureDetector(
                onPanStart: (_) async {
                  widget.companion.dragStarted();
                  try {
                    // Windows follows the cursor ourselves, not startDragging(): see PetDragger.
                    await widget.dragger.drag();
                  } catch (e) {
                    // The callback returns void, so a throw here would land
                    // nowhere as an uncaught async error; the drag still ends.
                    developer.log('drag failed: $e', name: 'aipet.pet_window');
                  } finally {
                    widget.companion.dragEnded();
                  }
                },
                onSecondaryTapUp: (d) => _showMenu(ctx, d.globalPosition),
                // expand: the Stack is the window. Sized by its children, it
                // would shrink to the empty error slot, taking the pet with it.
                child: Stack(alignment: Alignment.center, fit: StackFit.expand, children: [
                  _petAt(ListenableBuilder(
                    listenable: widget.walker,
                    builder: (_, child) => Transform.flip(flipX: widget.walker.mirrored, child: child),
                    child: ValueListenableBuilder<AlphaVideoController?>(
                      valueListenable: widget.player.controller,
                      builder: (_, vc, _) => vc == null ? const SizedBox.shrink() : AlphaVideoView(controller: vc),
                    ),
                  )),
                  ListenableBuilder(
                    listenable: widget.controller,
                    builder: (_, _) {
                      final e = widget.controller.error;
                      if (e == null) return const SizedBox.shrink();
                      return Positioned(
                        bottom: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration:
                              BoxDecoration(color: const Color(0xCC3D2B1F), borderRadius: BorderRadius.circular(10)),
                          child: Text(e, style: const TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                      );
                    },
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}
