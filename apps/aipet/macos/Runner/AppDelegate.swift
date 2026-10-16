import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Hiding the pet or closing the library must not quit; the app quits
  // through its own menus (windowManager.destroy).
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
