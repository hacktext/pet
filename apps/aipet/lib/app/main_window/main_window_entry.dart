import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/app_paths.dart';
import '../../services/pet_library.dart';
import '../../services/window_bridge.dart';
import 'main_window_app.dart';
import 'main_window_model.dart';

Future<void> runMainWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(size: Size(420, 740), minimumSize: Size(420, 600), center: true, title: 'aipet'),
    () async {
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
    },
  );
  final model = MainWindowModel(
    library: PetLibrary(builtinRoot: builtinPetsRoot(), customRoot: customPetsRoot(appDataRoot())),
    bridge: MainWindowBridge(WindowChannelTransport()),
  );
  windowManager.addListener(_CloseToHide(model));
  runApp(MainWindowApp(model: model));
  await model.start();
}

/// × hides the library instead of destroying it; the pet window first gets
/// the chance to end the app when nobody is on the desktop (spec 3.3).
class _CloseToHide with WindowListener {
  _CloseToHide(this.model);

  final MainWindowModel model;

  @override
  void onWindowClose() async {
    await model.closing();
    await windowManager.hide();
  }
}
