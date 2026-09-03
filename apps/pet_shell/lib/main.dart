import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:window_manager/window_manager.dart';
import 'package:alpha_video/alpha_video.dart';

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
  AlphaVideoController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _boot();
  }

  @override
  void dispose() {
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
  @override
  void onWindowClose() async {
    final c = _controller;
    if (c != null) {
      await c.dispose();
    }
    await windowManager.destroy();
  }

  Future<void> _boot() async {
    // 开发期素材：环境变量 AIPET_DEV_CLIP 指向一个绿幕 mp4
    final src = Platform.environment['AIPET_DEV_CLIP'];
    if (src == null || !File(src).existsSync()) {
      setState(() => _error = '设置 AIPET_DEV_CLIP 指向一个绿幕 mp4');
      return;
    }
    final dst = '${Directory.systemTemp.path}\\pet_shell_dev.aipmat';
    final code =
        await AlphaVideo.prepare(source: src, destination: dst, targetEdge: 720);
    if (code != 0) {
      setState(() => _error = '抠像失败，错误码 $code');
      return;
    }

    final AlphaVideoController c;
    try {
      c = await AlphaVideoController.open(dst);
    } on PlatformException catch (e) {
      setState(() => _error = '打开 .aipmat 失败：${e.code} ${e.message}');
      return;
    }

    // Assign the controller as soon as open() succeeds -- before calling
    // play() -- rather than after. open() is what creates the native Clip,
    // starts its ticker thread, and registers its texture; if play() were to
    // throw before _controller got assigned, nothing would hold a reference
    // to `c` any more and onWindowClose's `final c = _controller;` would see
    // null and skip disposal, leaking the ticker thread and the registered
    // texture for the rest of the process's life. Assigning here means
    // teardown can always find and dispose the clip, even if play() fails.
    setState(() => _controller = c);

    try {
      await c.play(loop: true);
    } on PlatformException catch (e) {
      setState(() => _error = '播放失败：${e.code} ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: GestureDetector(
          onPanStart: (_) => windowManager.startDragging(),
          child: Center(
            child: _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12))
                : _controller == null
                    ? const SizedBox.shrink()
                    : AlphaVideoView(controller: _controller!),
          ),
        ),
      ),
    );
  }
}
