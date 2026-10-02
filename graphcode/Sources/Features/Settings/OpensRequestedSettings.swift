import SwiftUI

/// Opens the Settings window when something outside it sets
/// `SettingsModel.requestedPane`. `openSettings` is only reachable from a view, and a
/// reducer that wants Settings › Agents › Nod has no view to call it from.
struct OpensRequestedSettings: ViewModifier {
  @Environment(\.openSettings) private var openSettings

  func body(content: Content) -> some View {
    content.onChange(of: SettingsModel.shared.requestedPane) { _, requested in
      if requested != nil { openSettings() }
    }
  }
}
