import GraphcodeKit
import SwiftUI

/// The new-loop form's agent menu (design 6a), grouped by what opens when the loop does:
/// Chat (Nod, with its engine and model) or Terminal (the CLIs). A backend that can't host
/// the chosen loop type stays listed but greyed, with the missing capability beside it,
/// because "why can't I use Pi for this?" is answered by the row, not by its absence.
struct RunsAsAgentMenu: View {
  @Binding var backend: CLISessionBackendKind
  @Binding var modelTier: ModelTier?
  let loopType: LoopType
  var nodSettings: NodSettings = SettingsModel.shared.settings.nod
  /// Read once by the form rather than here: a Keychain query per redraw of the form
  /// would be a query per keystroke in its text fields.
  var nodSignedIn: Bool

  var body: some View {
    Menu {
      ForEach(AgentMenuSection.sections(for: loopType), id: \.surface) { section in
        Section(section.title) {
          ForEach(section.entries, id: \.backend) { entry in
            if entry.backend == .nod {
              nodItems(entry)
            } else {
              Button {
                backend = entry.backend
              } label: {
                Text(entry.label)
                if let note = entry.note { Text(note) }
              }
              .disabled(!entry.isEnabled)
            }
          }
        }
      }
    } label: {
      Text(
        AgentMenuSection.label(
          backend: backend, tier: modelTier, loopType: loopType, nod: nodSettings))
    }
  }

  @ViewBuilder
  private func nodItems(_ entry: AgentMenuSection.Entry) -> some View {
    Button {
      backend = .nod
    } label: {
      Text(entry.label)
      Text(nodSettings.engine.displayName + (nodSignedIn ? " ✓" : " · not signed in"))
    }
    .disabled(!entry.isEnabled)
    Menu("Model") {
      Picker("Model", selection: $modelTier) {
        Text("Default · \(nodSettings.resolvedModel(for: loopType).displayName)")
          .tag(ModelTier?.none)
        ForEach(ModelTier.allCases, id: \.self) { tier in
          Text(NodModelCatalog.model(for: tier, engine: nodSettings.engine).displayName)
            .tag(ModelTier?.some(tier))
        }
      }
      .pickerStyle(.inline)
    }
    .disabled(!entry.isEnabled)
  }
}

/// The menu's content as plain values, so the grouping and greying are checked without
/// drawing a menu.
struct AgentMenuSection: Equatable {
  struct Entry: Equatable {
    let backend: CLISessionBackendKind
    let isEnabled: Bool
    /// The capability that's missing for this loop type, e.g. "no sub-agents".
    let note: String?

    var label: String { backend.displayName }
  }

  let surface: AgentSurface
  let entries: [Entry]

  var title: String {
    switch surface {
    case .chat: "Chat"
    case .terminal: "Terminal"
    }
  }

  static func sections(for loopType: LoopType) -> [AgentMenuSection] {
    AgentSurface.allCases.map { surface in
      AgentMenuSection(
        surface: surface,
        entries: CLISessionBackendKind.settingsOrder
          .filter { $0.surface == surface }
          .map { backend in
            Entry(
              backend: backend, isEnabled: backend.canHost(loopType),
              note: backend.canHost(loopType) ? nil : missingNote(backend, loopType))
          })
    }
  }

  static func missingNote(_ backend: CLISessionBackendKind, _ loopType: LoopType) -> String {
    guard backend.isSpiked else { return "not available yet" }
    switch loopType {
    case .goalBased: return "no goal mode"
    case .timeBased: return "no recurrence"
    case .composite: return "no sub-agents"
    case .sketch, .turnBased: return "can't host this type"
    }
  }

  /// "Nod · Sonnet" for Nod, whose model is part of the choice; the CLI's name otherwise.
  static func label(
    backend: CLISessionBackendKind, tier: ModelTier?, loopType: LoopType, nod: NodSettings
  ) -> String {
    guard backend == .nod else { return backend.displayName }
    return "Nod · " + nod.resolvedModel(for: loopType, tier: tier).displayName
  }
}
