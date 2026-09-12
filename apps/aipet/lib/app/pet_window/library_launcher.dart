import 'package:desktop_multi_window/desktop_multi_window.dart';

/// Arguments string that makes an engine the main window (Global Constraints).
const kMainWindowArgs = 'main_window';

/// Opens the main window, re-creating it if the user's × destroyed it --
/// whichever of hide/destroy Task 1 (C7) observed, this handles both.
class LibraryLauncher {
  /// The defaults are the desktop_multi_window calls; tests pass fakes.
  LibraryLauncher({
    this._create = _createMainWindow,
    this._listOpenWindowIds = _openWindowIds,
    this._show = _showWindow,
    this._hide = _hideWindow,
  });

  final Future<String> Function() _create;
  final Future<List<String>> Function() _listOpenWindowIds;
  final Future<void> Function(String windowId) _show;
  final Future<void> Function(String windowId) _hide;
  String? _mainId;
  Future<void>? _opening;

  static Future<String> _createMainWindow() async =>
      (await WindowController.create(WindowConfiguration(arguments: kMainWindowArgs, hiddenAtLaunch: false)))
          .windowId;

  static Future<List<String>> _openWindowIds() async =>
      [for (final w in await WindowController.getAll()) w.windowId];

  static Future<void> _showWindow(String windowId) => WindowController.fromWindowId(windowId).show();

  static Future<void> _hideWindow(String windowId) => WindowController.fromWindowId(windowId).hide();

  Future<bool> isOpen() async => _mainId != null && (await _listOpenWindowIds()).contains(_mainId);

  /// tray_manager reports every click, so a double-click calls this twice at
  /// once. Both share one attempt: a second create would make a second main
  /// window, and the 'aipet/pet' channel only pairs two engines.
  Future<void> open() =>
      // Block body on purpose: an arrow would return the cleared field's old
      // value -- this very future -- and whenComplete would wait on itself.
      _opening ??= _open().whenComplete(() {
        _opening = null;
      });

  Future<void> _open() async {
    if (!await isOpen()) _mainId = await _create();
    await _show(_mainId!);
  }

  /// Takes the library off the screen while quitting (AppExit).
  Future<void> hideIfOpen() async {
    if (await isOpen()) await _hide(_mainId!);
  }
}
