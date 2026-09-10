import 'dart:async';
import 'dart:io';

import 'package:alpha_video/alpha_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:window_manager/window_manager.dart';

import 'actions.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      // Intercept the native close request (WM_CLOSE) so we can run our own
      // teardown (AlphaVideoController.dispose -> stop+join the ticker thread
      // and unregister the texture) before the window, and with it the
      // Flutter engine's TextureRegistrar, goes away. See
      // _PetShellAppState.onWindowClose below.
      await windowManager.setPreventClose(true);
      await windowManager.show();
    },
  );

  runApp(const PetShellApp());
}

class PetShellApp extends StatefulWidget {
  const PetShellApp({super.key});
  @override
  State<PetShellApp> createState() => _PetShellAppState();
}

class _PetShellAppState extends State<PetShellApp> with WindowListener {
  static const _quit = '__quit__';

  AlphaVideoController? _controller;
  String? _error;
  List<PetAction> _actions = const [];
  String? _current; // action on screen
  String? _idle; // action one-shots hand back to
  bool _switching = false;
  Timer? _oneShotWatch;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _boot();
  }

  @override
  void dispose() {
    _oneShotWatch?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  // Fires on WM_CLOSE because main() called setPreventClose(true). This is
  // the "make sure dispose() runs on window close" fix carried forward from
  // Task 10's review: if the process exits with a clip still open, the
  // ticker thread and a live PixelBufferTexture callback race the engine's
  // own TextureRegistrar shutdown. Stopping the clip here, before we ever
  // call windowManager.destroy() (which posts WM_QUIT and ends the message
  // loop), keeps that from happening.
  //
  // setPreventClose(true) also means destroy() is the ONLY thing that lets
  // the X button (or Alt+F4) actually close this frameless, title-bar-less,
  // always-on-top window -- so destroy() must run even if dispose() throws
  // (e.g. a MissingPluginException after a hot restart, or a
  // PlatformException from the native side). Without the try/finally, an
  // async void handler that throws mid-await just stops, destroy() never
  // runs, and the window becomes closable only via Task Manager.
  @override
  void onWindowClose() async {
    _oneShotWatch?.cancel();
    final c = _controller;
    try {
      await c?.dispose();
    } finally {
      await windowManager.destroy();
    }
  }

  Future<void> _boot() async {
    // 开发期素材：AIPET_DEV_DIR 指向一个文件夹，每个动作一个 <动作名>.mp4
    // （spec 第 6 节的 M2 交付格式）；AIPET_DEV_CLIP 指向单个 mp4 的旧用法照旧可用。
    final env = Platform.environment;
    final dir = env['AIPET_DEV_DIR'];
    final clip = env['AIPET_DEV_CLIP'];
    var actions = const <PetAction>[];
    if (dir != null && Directory(dir).existsSync()) {
      actions = discoverActions(Directory(dir));
    } else if (clip != null && File(clip).existsSync()) {
      final a = actionFromFile(File(clip));
      if (a != null) actions = [a];
    }
    if (actions.isEmpty) {
      setState(() => _error = '设置 AIPET_DEV_DIR 指向一个放着 <动作名>.mp4 的文件夹');
      return;
    }
    _actions = actions;
    _idle = defaultActionKey(actions.map((a) => a.key));
    await _switchTo(_idle!);
  }

  Future<void> _switchTo(String key) async {
    final action = _actions.firstWhere((a) => a.key == key);
    if (_switching || (key == _current && action.loops)) return;
    _switching = true;
    _oneShotWatch?.cancel();
    try {
      final cacheDir = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}pet_shell_dev')
        ..createSync(recursive: true);
      final cache = File(cachePathFor(cacheDir.path, action.source, action.key));
      if (needsPrepare(action.source, cache)) {
        // Blocks the platform thread (~2.6 s release, HANDOFF 待办 2), but
        // only the first time a clip is used; later switches hit the cache.
        await AlphaVideo.prepare(
            source: action.source.path, destination: cache.path, targetEdge: 720);
      }
      final next = await AlphaVideoController.open(cache.path);
      final prev = _controller;
      // Hold the new controller in state before play(), for the same reason
      // the single-clip version did: onWindowClose must always be able to find
      // and dispose whatever clip open() created, even if play() throws.
      setState(() {
        _controller = next;
        _current = key;
        _error = null;
      });
      // Let the frame that swaps the Texture widget land before the old
      // texture is unregistered, so nothing ever draws a dead texture id.
      await SchedulerBinding.instance.endOfFrame;
      await prev?.dispose();
      await next.play(loop: action.loops);
      if (!action.loops) _watchOneShot(next);
    } on PlatformException catch (e) {
      setState(() => _error = '切换到「${action.label}」失败：${e.code} ${e.message}');
    } finally {
      _switching = false;
    }
  }

  // The plugin has no "finished" event and cannot replay a one-shot clip
  // (HANDOFF 待办 3), so poll the frame counter and hand back to the idle
  // loop on the last frame. Replaying a one-shot reopens its cache, which
  // starts from frame 0.
  void _watchOneShot(AlphaVideoController c) {
    _oneShotWatch = Timer.periodic(const Duration(milliseconds: 100), (t) async {
      if (!identical(_controller, c)) {
        t.cancel();
        return;
      }
      final int frame;
      try {
        frame = await c.currentFrame();
      } on PlatformException {
        t.cancel();
        return;
      }
      if (frame >= c.frameCount - 1 && identical(_controller, c)) {
        t.cancel();
        final idle = _idle;
        if (idle != null) await _switchTo(idle);
      }
    });
  }

  Future<void> _showMenu(BuildContext ctx, Offset at) async {
    if (_actions.isEmpty) return;
    final overlay = Overlay.of(ctx).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: ctx,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        for (final a in _actions)
          CheckedPopupMenuItem<String>(
            value: a.key,
            checked: a.key == _current,
            height: 36,
            child: Text(a.label),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(value: _quit, height: 36, child: Text('退出')),
      ],
    );
    if (choice == null) return;
    if (choice == _quit) {
      await windowManager.close(); // -> onWindowClose -> dispose -> destroy
      return;
    }
    await _switchTo(choice);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        // Builder: showMenu needs a context below MaterialApp (for its
        // Navigator and Overlay); this State's own context sits above it.
        body: Builder(
          builder: (ctx) => GestureDetector(
            onPanStart: (_) => windowManager.startDragging(),
            onSecondaryTapUp: (d) => _showMenu(ctx, d.globalPosition),
            child: Center(
              child: _error != null
                  ? Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12))
                  : _controller == null
                      ? const SizedBox.shrink()
                      : AlphaVideoView(controller: _controller!),
            ),
          ),
        ),
      ),
    );
  }
}
