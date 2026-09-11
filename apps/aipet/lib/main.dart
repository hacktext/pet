// Task 1 prototype: exercises the multi-window assumptions spec 3.4 lists.
// Replaced wholesale in Task 15. Every finding goes to %TEMP%\aipet_proto.log
// as "[proto] C<n> ..." so the run needs no mouse.
import 'dart:io';

import 'package:alpha_video/alpha_video.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const kMainWindowArgs = 'main_window';
const kChannel = WindowMethodChannel('aipet/pet');
final bool kAutorun = Platform.environment['AIPET_PROTO_AUTORUN'] == '1';

void protoLog(String line) {
  debugPrint('[proto] $line');
  File('${Directory.systemTemp.path}${Platform.pathSeparator}aipet_proto.log')
      .writeAsStringSync('[proto] $line\n', mode: FileMode.append, flush: true);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await WindowController.fromCurrentEngine();
  protoLog('engine windowId=${self.windowId} arguments="${self.arguments}"');
  if (self.arguments == kMainWindowArgs) {
    await _setUpMainWindowChrome();
    runApp(const ProtoMainWindow());
    return;
  }
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(360, 360),
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.setAsFrameless();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setHasShadow(false);
      await windowManager.setPreventClose(true);
      await windowManager.show();
    },
  );
  runApp(const ProtoPetWindow());
}

// C6: does window_manager, called from the sub window's own engine, act on
// the sub window (and not on the pet window)? ASCII title so tools can find it.
Future<void> _setUpMainWindowChrome() async {
  try {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(420, 740), center: true, title: 'aipet proto main'),
      () async => windowManager.show(),
    );
    protoLog('C6 window_manager in sub window: no exception');
  } catch (e) {
    protoLog('C6 window_manager in sub window threw: $e');
  }
}

class ProtoPetWindow extends StatefulWidget {
  const ProtoPetWindow({super.key});
  @override
  State<ProtoPetWindow> createState() => _ProtoPetWindowState();
}

class _ProtoPetWindowState extends State<ProtoPetWindow> with TrayListener, WindowListener {
  AlphaVideoController? _clip;
  WindowController? _main;

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    kChannel.setMethodCallHandler((call) async {
      protoLog('pet got ${call.method}');
      return call.method == 'ping' ? 'pong-from-pet' : null;
    });
    _start();
  }

  Future<void> _start() async {
    final src = '${Directory.current.path}\\..\\..\\native\\testdata\\green_box.mp4';
    final dst = '${Directory.systemTemp.path}\\aipet_proto.aipmat';
    await AlphaVideo.prepare(source: src, destination: dst, targetEdge: 320);
    final c = await AlphaVideoController.open(dst);
    setState(() => _clip = c);
    await c.play(loop: true);
    try {
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: '打开宠物库'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
      protoLog('C2 tray icon + menu set');
    } catch (e) {
      protoLog('C2 tray FAILED: $e');
    }
    if (kAutorun) _autorun();
  }

  Future<List<String>> _ids() async =>
      (await WindowController.getAll()).map((w) => w.windowId).toList();

  Future<void> _openLibrary() async {
    final before = await _ids();
    final alive = _main != null && before.contains(_main!.windowId);
    if (alive) {
      await _main!.show();
      protoLog('C7 re-showed existing main window ${_main!.windowId}');
      return;
    }
    _main = await WindowController.create(
        WindowConfiguration(arguments: kMainWindowArgs, hiddenAtLaunch: false));
    await _main!.show();
    protoLog('C3 created main window ${_main!.windowId} (windows now ${await _ids()})');
  }

  Future<void> _pingMain(String tag) async {
    try {
      final r = await kChannel.invokeMethod<String>('ping').timeout(const Duration(seconds: 3));
      protoLog('$tag pet->main: $r');
    } catch (e) {
      protoLog('$tag pet->main FAILED: $e');
    }
  }

  Future<void> _autorun() async {
    Future<void> at(int s) => Future<void>.delayed(Duration(seconds: s));
    await at(1);
    protoLog('C1 frame after 1s = ${await _clip?.currentFrame()}');
    await _openLibrary();
    await at(3);
    await _pingMain('C5');
    protoLog('C7 windows before external WM_CLOSE: ${await _ids()}');
    await at(8); // tools step 5 posts WM_CLOSE to "aipet proto main" in this gap
    protoLog('C7 windows after external WM_CLOSE: ${await _ids()}');
    await _openLibrary();
    await at(3);
    await _pingMain('C7-reopen');
    await windowManager.hide();
    protoLog('C8 pet window hidden');
    await at(1);
    await _pingMain('C8');
    await windowManager.show();
    await at(1);
    protoLog('C9 quitting');
    await _quit();
  }

  Future<void> _quit() async {
    try {
      await _clip?.dispose();
      await trayManager.destroy();
    } finally {
      await windowManager.destroy();
    }
  }

  @override
  void onTrayIconMouseDown() => _openLibrary();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'open') _openLibrary();
    if (menuItem.key == 'quit') _quit();
  }

  @override
  void onWindowClose() => _quit();

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: GestureDetector(
            onPanStart: (_) => windowManager.startDragging(),
            child: Center(child: _clip == null ? const SizedBox.shrink() : AlphaVideoView(controller: _clip!)),
          ),
        ),
      );
}

class ProtoMainWindow extends StatefulWidget {
  const ProtoMainWindow({super.key});
  @override
  State<ProtoMainWindow> createState() => _ProtoMainWindowState();
}

class _ProtoMainWindowState extends State<ProtoMainWindow> {
  final _lines = <String>[];

  void _add(String s) {
    protoLog(s);
    if (mounted) setState(() => _lines.add(s));
  }

  @override
  void initState() {
    super.initState();
    kChannel.setMethodCallHandler((call) async {
      _add('main got ${call.method}');
      return call.method == 'ping' ? 'pong-from-main' : null;
    });
    if (kAutorun) Future<void>.delayed(const Duration(seconds: 1), _pingPet);
  }

  Future<void> _pingPet() async {
    try {
      final r = await kChannel.invokeMethod<String>('ping').timeout(const Duration(seconds: 3));
      _add('C4 main->pet: $r');
    } catch (e) {
      _add('C4 main->pet FAILED: $e');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('aipet proto main')),
          body: ListView(children: [
            ElevatedButton(onPressed: _pingPet, child: const Text('Ping pet window')),
            for (final l in _lines) Text(l),
          ]),
        ),
      );
}
