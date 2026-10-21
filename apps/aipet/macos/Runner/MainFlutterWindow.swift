import Cocoa
import FlutterMacOS
import ServiceManagement
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Every engine (pet window, library, status panel) draws on a clear
    // window; the pet and the panel rely on it, the library paints its own
    // opaque background.
    MainFlutterWindow.makeTransparent(self, flutterViewController)
    RegisterGeneratedPlugins(registry: flutterViewController)
    NativeWindowChannel.register(with: flutterViewController.engine.binaryMessenger)
    // Only the pet window's engine (this one) touches 开机启动.
    LaunchAtStartupChannel.register(with: flutterViewController.engine.binaryMessenger)

    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
      NativeWindowChannel.register(with: controller.engine.binaryMessenger)
      controller.backgroundColor = .clear
      // The controller is not in its window yet when this runs.
      DispatchQueue.main.async {
        if let window = controller.view.window { MainFlutterWindow.makeTransparent(window, controller) }
      }
    }

    super.awakeFromNib()
  }

  static func makeTransparent(_ window: NSWindow, _ controller: FlutterViewController) {
    window.isOpaque = false
    window.backgroundColor = .clear
    controller.backgroundColor = .clear
  }
}

/// The aipet/native_window channel (lib/services/native_window.dart,
/// MacWindow): moves and shows windows without activating the app, the
/// counterpart of SetWindowPos(SWP_NOACTIVATE) on Windows. Dart speaks
/// logical pixels with the origin at the primary screen's top-left; AppKit's
/// origin is the primary screen's bottom-left, so y is flipped here.
enum NativeWindowChannel {
  private static var channels: [FlutterMethodChannel] = []

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "aipet/native_window", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      // Click-through (lib/app/pet_window/click_through.dart): where the
      // cursor is over the window, and whether the window lets the mouse by.
      if call.method == "cursor" || call.method == "setIgnoresMouse" {
        guard let args = call.arguments as? [String: Any], let title = args["title"] as? String,
          let window = NSApp.windows.first(where: { $0.title == title })
        else {
          result(FlutterError(code: "no_window", message: "no window with that title", details: nil))
          return
        }
        if call.method == "setIgnoresMouse" {
          window.ignoresMouseEvents = (args["ignore"] as? Bool) ?? false
          result(nil)
          return
        }
        // AppKit's y runs up from the screen's bottom; the window's own top-left is the origin here.
        let mouse = NSEvent.mouseLocation
        let f = window.frame
        result(["x": mouse.x - f.minX, "y": f.maxY - mouse.y, "width": f.width, "height": f.height])
        return
      }
      guard let args = call.arguments as? [String: Any],
        let title = args["title"] as? String,
        let x = (args["x"] as? NSNumber)?.doubleValue,
        let y = (args["y"] as? NSNumber)?.doubleValue
      else {
        result(FlutterError(code: "bad_args", message: "title, x and y are required", details: nil))
        return
      }
      guard let window = NSApp.windows.first(where: { $0.title == title }) else {
        result(FlutterError(code: "no_window", message: "no window titled \(title)", details: nil))
        return
      }
      let top = NSScreen.screens.first?.frame.maxY ?? 0
      switch call.method {
      case "moveTo":
        window.setFrameOrigin(NSPoint(x: x, y: top - y - window.frame.height))
      case "setRect":
        guard let w = (args["width"] as? NSNumber)?.doubleValue,
          let h = (args["height"] as? NSNumber)?.doubleValue
        else {
          result(FlutterError(code: "bad_args", message: "width and height are required", details: nil))
          return
        }
        window.setFrame(NSRect(x: x, y: top - y - h, width: w, height: h), display: true)
      case "showAt":
        window.setFrameOrigin(NSPoint(x: x, y: top - y - window.frame.height))
        window.level = .floating
        window.orderFrontRegardless()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }
    channels.append(channel)
  }
}

/// The launch_at_startup package's macOS channel (lib/services/autostart.dart),
/// backed by SMAppService instead of the LaunchAtLogin package it suggests.
/// macOS 12 has no SMAppService: it reports off and ignores changes, which
/// Autostart already tolerates.
enum LaunchAtStartupChannel {
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "launch_at_startup", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "launchAtStartupIsEnabled":
        if #available(macOS 13.0, *) {
          result(SMAppService.mainApp.status == .enabled)
        } else {
          result(false)
        }
      case "launchAtStartupSetEnabled":
        guard let enabled = (call.arguments as? [String: Any])?["setEnabledValue"] as? Bool else {
          result(FlutterError(code: "bad_args", message: "setEnabledValue is required", details: nil))
          return
        }
        guard #available(macOS 13.0, *) else {
          result(nil)
          return
        }
        do {
          let service = SMAppService.mainApp
          if enabled, service.status != .enabled {
            try service.register()
          } else if !enabled, service.status == .enabled {
            try service.unregister()
          }
          result(nil)
        } catch {
          result(FlutterError(code: "login_item", message: error.localizedDescription, details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }
}
