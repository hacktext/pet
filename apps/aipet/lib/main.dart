import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';

import 'app/hud_window/hud_window_entry.dart';
import 'app/main_window/main_window_entry.dart';
import 'app/pet_window/library_launcher.dart';
import 'app/pet_window/pet_window_app.dart';

/// One process, three engines: the primary engine is the pet window;
/// kMainWindowArgs is the library, kHudWindowArgs the status panel.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await WindowController.fromCurrentEngine();
  switch (self.arguments) {
    case kMainWindowArgs:
      await runMainWindow();
    case kHudWindowArgs:
      await runHudWindow();
    default:
      await runPetWindow();
  }
}
