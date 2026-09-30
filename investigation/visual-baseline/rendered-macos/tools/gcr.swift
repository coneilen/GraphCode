// Capture/input helper used for the macOS reference captures in this directory. Not part of
// the app and not built by the Makefile. Build: swiftc -O gcr.swift -o gcr. Subcommands:
//   screens                          list NSScreens (frame, scale, colour space)
//   windows <pid>                    list on-screen windows of a pid (id, layer, bounds, title)
//   env                              appearance/accessibility/font-smoothing state
//   click x y [right]                post a mouse click at global point (top-left origin)
//   drag x1 y1 x2 y2                 post a left drag
//   move x y                         move the mouse pointer
//   key <keycode> [cmd|shift|opt|ctrl ...]  post a key press
//   type <text>                      type unicode text
//   sck <windowID> <out.png> <srgb|native>  ScreenCaptureKit single-window capture, no shadow
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
func fail(_ s: String) -> Never {
  FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
  exit(1)
}

func post(_ e: CGEvent?) {
  e?.post(tap: .cghidEventTap)
  usleep(30_000)
}

func mouse(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left) {
  post(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button))
}

switch args.count > 1 ? args[1] : "" {
case "screens":
  for s in NSScreen.screens {
    let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    print(
      "id=\(id ?? 0) name=\(s.localizedName) frame=\(s.frame) scale=\(s.backingScaleFactor) "
        + "colorSpace=\(s.colorSpace?.localizedName ?? "nil") main=\(s == NSScreen.main)")
    if let id { print("  cgBounds=\(CGDisplayBounds(CGDirectDisplayID(id.uint32Value)))") }
  }
case "windows":
  guard args.count > 2, let pid = Int(args[2]) else { fail("pid") }
  let list =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid {
    print(
      "id=\(w[kCGWindowNumber as String] ?? "") layer=\(w[kCGWindowLayer as String] ?? "") "
        + "bounds=\(w[kCGWindowBounds as String] ?? "") name=\(w[kCGWindowName as String] ?? "")"
        + " alpha=\(w[kCGWindowAlpha as String] ?? "")")
  }
case "env":
  let ws = NSWorkspace.shared
  print("increaseContrast=\(ws.accessibilityDisplayShouldIncreaseContrast)")
  print("reduceTransparency=\(ws.accessibilityDisplayShouldReduceTransparency)")
  print("reduceMotion=\(ws.accessibilityDisplayShouldReduceMotion)")
  print("differentiateWithoutColor=\(ws.accessibilityDisplayShouldDifferentiateWithoutColor)")
  print("invertColors=\(ws.accessibilityDisplayShouldInvertColors)")
  let app = NSApplication.shared
  print("systemAppearance(this process)=\(app.effectiveAppearance.name.rawValue)")
  let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
  print(
    String(
      format: "controlAccentColor(sRGB)=%.4f,%.4f,%.4f", accent.redComponent,
      accent.greenComponent, accent.blueComponent))
  let d = UserDefaults.standard
  for k in [
    "AppleInterfaceStyle", "AppleAccentColor", "AppleHighlightColor", "AppleReduceDesktopTinting",
    "AppleFontSmoothing", "AppleInterfaceStyleSwitchesAutomatically", "AppleShowScrollBars",
  ] {
    print("\(k)=\(d.object(forKey: k).map { "\($0)" } ?? "<unset>")")
  }
case "click":
  guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else { fail("x y") }
  let right = args.count > 4 && args[4] == "right"
  let p = CGPoint(x: x, y: y)
  mouse(.mouseMoved, p)
  usleep(150_000)
  mouse(right ? .rightMouseDown : .leftMouseDown, p, right ? .right : .left)
  usleep(120_000)
  mouse(right ? .rightMouseUp : .leftMouseUp, p, right ? .right : .left)
case "scroll":
  guard args.count > 4, let x = Double(args[2]), let y = Double(args[3]), let d = Int32(args[4]) else { fail("x y dy") }
  mouse(.mouseMoved, CGPoint(x: x, y: y))
  usleep(150_000)
  for _ in 0..<abs(d) { let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: d < 0 ? -1 : 1, wheel2: 0, wheel3: 0)!; e.location = CGPoint(x: x, y: y); e.post(tap: .cghidEventTap); usleep(20_000) }
case "move":
  guard args.count > 3, let x = Double(args[2]), let y = Double(args[3]) else { fail("x y") }
  mouse(.mouseMoved, CGPoint(x: x, y: y))
case "drag":
  guard args.count > 5, let x1 = Double(args[2]), let y1 = Double(args[3]),
    let x2 = Double(args[4]), let y2 = Double(args[5])
  else { fail("x1 y1 x2 y2") }
  let a = CGPoint(x: x1, y: y1)
  mouse(.mouseMoved, a)
  usleep(200_000)
  mouse(.leftMouseDown, a)
  usleep(200_000)
  for i in 1...30 {
    let t = Double(i) / 30
    mouse(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t))
  }
  usleep(200_000)
  mouse(.leftMouseUp, CGPoint(x: x2, y: y2))
case "key":
  guard args.count > 2, let code = UInt16(args[2]) else { fail("keycode") }
  var flags: CGEventFlags = []
  for m in args.dropFirst(3) {
    switch m {
    case "cmd": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "opt": flags.insert(.maskAlternate)
    case "ctrl": flags.insert(.maskControl)
    default: fail("modifier \(m)")
    }
  }
  let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
  down?.flags = flags
  post(down)
  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
  up?.flags = flags
  post(up)
case "type":
  guard args.count > 2 else { fail("text") }
  for scalar in args[2].utf16 {
    var c = scalar
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
    post(down)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
    up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
    post(up)
  }
case "sck":
  guard args.count > 4, let wid = UInt32(args[2]) else { fail("windowID out mode") }
  let out = URL(fileURLWithPath: args[3])
  let srgb = args[4] == "srgb"
  _ = NSApplication.shared
  let sem = DispatchSemaphore(value: 0)
  Task {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      guard let window = content.windows.first(where: { $0.windowID == wid }) else {
        fail("window \(wid) not shareable")
      }
      let filter = SCContentFilter(desktopIndependentWindow: window)
      let config = SCStreamConfiguration()
      let scale = CGFloat(filter.pointPixelScale)
      config.width = Int(filter.contentRect.width * scale)
      config.height = Int(filter.contentRect.height * scale)
      config.ignoreShadowsSingleWindow = true
      config.showsCursor = false
      config.captureResolution = .best
      config.pixelFormat = kCVPixelFormatType_32BGRA
      if srgb { config.colorSpaceName = CGColorSpace.sRGB }
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
      guard
        let dest = CGImageDestinationCreateWithURL(
          out as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { fail("dest") }
      CGImageDestinationAddImage(dest, image, nil)
      guard CGImageDestinationFinalize(dest) else { fail("finalize") }
      print(
        "captured \(image.width)x\(image.height) pointPixelScale=\(filter.pointPixelScale) "
          + "contentRect=\(filter.contentRect) "
          + "colorSpace=\(image.colorSpace?.name as String? ?? "nil")")
    } catch {
      fail("capture failed: \(error)")
    }
    sem.signal()
  }
  sem.wait()
case "sckapp":
  // sckapp <pid> <mainWindowID> <out.png> <srgb|native> <scale>
  // Display capture filtered to *only* this app's on-screen windows (so a context menu or
  // popover window is included, the desktop and every other app are not), with the
  // capture source rectangle set to the main window's frame.
  guard args.count > 6, let pid = Int32(args[2]), let wid = UInt32(args[3]),
    let scale = Double(args[6])
  else { fail("pid windowID out mode scale") }
  let out = URL(fileURLWithPath: args[4])
  let srgb = args[5] == "srgb"
  _ = NSApplication.shared
  let sem = DispatchSemaphore(value: 0)
  Task {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        true, onScreenWindowsOnly: true)
      guard let main = content.windows.first(where: { $0.windowID == wid }) else {
        fail("window \(wid) not shareable")
      }
      guard
        let display = content.displays.first(where: {
          $0.frame.contains(CGPoint(x: main.frame.midX, y: main.frame.midY))
        })
      else { fail("no display") }
      let topInset = args.count > 7 ? Double(args[7]) ?? 0 : 0
      let solo = args.count > 8 && args[8] == "solo"
      let appWindows = content.windows.filter {
        $0.owningApplication?.processID == pid
          && (!solo || $0.windowID == wid || $0.windowLayer > 0)
      }
      let filter = SCContentFilter(display: display, including: appWindows)
      let config = SCStreamConfiguration()
      let rect = CGRect(
        x: main.frame.minX - display.frame.minX,
        y: main.frame.minY - display.frame.minY + topInset,
        width: main.frame.width, height: main.frame.height - topInset)
      config.sourceRect = rect
      config.width = Int(rect.width * scale)
      config.height = Int(rect.height * scale)
      config.showsCursor = false
      config.captureResolution = .best
      config.pixelFormat = kCVPixelFormatType_32BGRA
      if srgb { config.colorSpaceName = CGColorSpace.sRGB }
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
      guard
        let dest = CGImageDestinationCreateWithURL(
          out as CFURL, UTType.png.identifier as CFString, 1, nil)
      else { fail("dest") }
      CGImageDestinationAddImage(dest, image, nil)
      guard CGImageDestinationFinalize(dest) else { fail("finalize") }
      print(
        "captured \(image.width)x\(image.height) display=\(display.displayID) "
          + "displayFrame=\(display.frame) windowFrame=\(main.frame) sourceRect=\(rect) "
          + "appWindows=\(appWindows.map { "\($0.windowID)@\($0.windowLayer)" }) "
          + "colorSpace=\(image.colorSpace?.name as String? ?? "nil")")
    } catch {
      fail("capture failed: \(error)")
    }
    sem.signal()
  }
  sem.wait()
default:
  fail("unknown subcommand")
}
