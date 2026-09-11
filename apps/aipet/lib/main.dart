import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';

import 'app/main_window/main_window_entry.dart';
import 'app/pet_window/library_launcher.dart';
import 'app/pet_window/pet_window_app.dart';

/// One process, two engines (spec 3.1): the primary engine is the pet window;
/// an engine created with kMainWindowArgs is the main window.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final self = await WindowController.fromCurrentEngine();
  if (self.arguments == kMainWindowArgs) {
    await runMainWindow();
  } else {
    await runPetWindow();
  }
}
