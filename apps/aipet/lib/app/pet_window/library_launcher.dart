import 'package:desktop_multi_window/desktop_multi_window.dart';

/// Arguments string that makes an engine the main window (Global Constraints).
const kMainWindowArgs = 'main_window';

/// Opens the main window, re-creating it if the user's × destroyed it --
/// whichever of hide/destroy Task 1 (C7) observed, this handles both.
class LibraryLauncher {
  WindowController? _main;

  Future<bool> isOpen() async =>
      _main != null && (await WindowController.getAll()).any((w) => w.windowId == _main!.windowId);

  Future<void> open() async {
    if (!await isOpen()) {
      _main = await WindowController.create(WindowConfiguration(arguments: kMainWindowArgs, hiddenAtLaunch: false));
    }
    await _main!.show();
  }
}
