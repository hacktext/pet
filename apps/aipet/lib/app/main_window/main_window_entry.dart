import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/account_store.dart';
import '../../services/api_client.dart';
import '../../services/app_paths.dart';
import '../../services/custom_service.dart';
import '../../services/oss_uploader.dart';
import '../../services/pet_library.dart';
import '../../services/window_bridge.dart';
import 'custom_flow/custom_deps.dart';
import 'main_window_app.dart';
import 'main_window_model.dart';

Future<void> runMainWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(size: Size(1200, 760), minimumSize: Size(960, 640), center: true, title: 'aipet'),
    () async {
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
    },
  );
  late final MainWindowModel model;
  model = MainWindowModel(
    library: PetLibrary(builtinRoot: builtinPetsRoot(), customRoot: customPetsRoot(appDataRoot())),
    bridge: MainWindowBridge(WindowChannelTransport()),
    custom: CustomDeps(
      service: CustomService(
        // Read-only: the pet window is account.json's one writer.
        ApiClient(IoHttpTransport(), token: AccountStore(appDataRoot()).readToken),
        onLoginExpired: () => model.loginExpired(),
      ),
      uploader: OssUploader(IoMultipartTransport()),
      pick: pickPhotosFromDisk,
    ),
  );
  windowManager.addListener(_CloseToHide(model));
  runApp(MainWindowApp(model: model));
  await model.start();
}

/// × hides the library instead of destroying it; the pet window first gets
/// the chance to end the app when nobody is on the desktop (spec 3.3). Also
/// tells the model whether anyone can see it (我的定制 refreshes only then).
class _CloseToHide with WindowListener {
  _CloseToHide(this.model);

  final MainWindowModel model;

  @override
  void onWindowClose() async {
    model.setVisible(false);
    await model.closing();
    await windowManager.hide();
  }

  @override
  void onWindowFocus() => model.setVisible(true);

  @override
  void onWindowMinimize() => model.setVisible(false);

  @override
  void onWindowRestore() => model.setVisible(true);
}
