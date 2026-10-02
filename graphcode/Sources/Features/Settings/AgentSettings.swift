import GraphcodeKit
import SwiftUI

enum SettingsPane: Hashable {
  case general
  case agent(CLISessionBackendKind)
  case templates
}

extension CLISessionBackendKind {
  /// Nod first, then the CLIs in the order the design lists them.
  static let settingsOrder: [CLISessionBackendKind] = [
    .nod, .claudeCode, .codex, .copilotCLI, .openCode, .pi,
  ]
}

/// Settings › Agents › one CLI: what it may do without asking, and for Copilot the version
/// to launch. Each loop runs whether or not this window is open, so nobody is there to
/// answer a permission prompt.
struct CLIAgentSettingsPane: View {
  let backend: CLISessionBackendKind
  @Binding var settings: GraphcodeSettings

  var body: some View {
    Form {
      Section {
        permissionPicker
      } header: {
        Text("Permissions")
      } footer: {
        Text(
          "A loop runs whether or not this window is open, so nobody is there to answer a "
            + "permission prompt. A backend left on its own default waits at that prompt "
            + "while the graph reports the loop as running."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
      if backend == .copilotCLI {
        PreferredVersionsSettingsSection(settings: $settings)
      }
    }
    .formStyle(.grouped)
  }

  @ViewBuilder private var permissionPicker: some View {
    switch backend {
    case .claudeCode:
      picker($settings.claudePermissionMode, explanation: settings.claudePermissionMode.explanation)
      {
        $0.displayName
      }
    case .copilotCLI:
      picker($settings.copilotPermissions, explanation: settings.copilotPermissions.explanation) {
        $0.displayName
      }
    case .codex:
      picker($settings.codexApprovals, explanation: settings.codexApprovals.explanation) {
        $0.displayName
      }
    case .openCode:
      picker(
        $settings.openCodePermissions, explanation: settings.openCodePermissions.explanation
      ) { $0.displayName }
    case .pi:
      picker($settings.piProjectTrust, explanation: settings.piProjectTrust.explanation) {
        $0.displayName
      }
    case .nod:
      EmptyView()
    }
  }

  private func picker<Mode: CaseIterable & Hashable>(
    _ selection: Binding<Mode>, explanation: String, name: @escaping (Mode) -> String
  ) -> some View where Mode.AllCases: RandomAccessCollection {
    Group {
      Picker(backend.displayName, selection: selection) {
        ForEach(Array(Mode.allCases), id: \.self) { mode in
          Text(name(mode)).tag(mode)
        }
      }
      Text(explanation)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
