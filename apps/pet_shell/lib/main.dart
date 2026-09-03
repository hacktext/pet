import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
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
  //
  // The marker file is deliberately part of the shipped close path (not a
  // scratch hack): it is the only way to confirm, after the process has
  // already exited, that this handler actually ran end-to-end rather than
  // being skipped or racing app shutdown.
  @override
  void onWindowClose() async {
    final marker =
        File('${Directory.systemTemp.path}\\pet_shell_dispose_marker.txt');
    await marker.writeAsString(
      'onWindowClose fired at ${DateTime.now().toIso8601String()}\n',
      mode: FileMode.append,
      flush: true,
    );
    final c = _controller;
    if (c != null) {
      await c.dispose();
      await marker.writeAsString(
        'controller.dispose() completed at ${DateTime.now().toIso8601String()}\n',
        mode: FileMode.append,
        flush: true,
      );
    }
    await windowManager.destroy();
  }

  // Boot-timing log: measures the brief's "launch to first visible frame"
  // wall clock. Compared against the OS process-creation time (read back
  // separately via `Get-Process`), the "first frame painted" line below
  // gives the actual end-to-end latency instead of an eyeballed estimate.
  Future<void> _log(String msg) => File(
          '${Directory.systemTemp.path}\\pet_shell_boot_marker.txt')
      .writeAsString('$msg at ${DateTime.now().toIso8601String()}\n',
          mode: FileMode.append, flush: true);

  Future<void> _boot() async {
    await _log('_boot() entered');
    // 开发期素材：环境变量 AIPET_DEV_CLIP 指向一个绿幕 mp4
    final src = Platform.environment['AIPET_DEV_CLIP'];
    if (src == null || !File(src).existsSync()) {
      setState(() => _error = '设置 AIPET_DEV_CLIP 指向一个绿幕 mp4');
      return;
    }
    final dst = '${Directory.systemTemp.path}\\pet_shell_dev.aipmat';
    await _log('prepare() started');
    final code =
        await AlphaVideo.prepare(source: src, destination: dst, targetEdge: 720);
    await _log('prepare() finished code=$code');
    if (code != 0) {
      setState(() => _error = '抠像失败，错误码 $code');
      return;
    }
    final c = await AlphaVideoController.open(dst);
    await _log('open() finished');
    await c.play(loop: true);
    await _log('play() called');
    setState(() => _controller = c);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_log('first frame with controller painted'));
    });
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
