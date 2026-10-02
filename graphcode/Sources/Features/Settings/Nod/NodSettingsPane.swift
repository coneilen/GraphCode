import GraphcodeKit
import SwiftUI

/// Settings › Agents › Nod (design 7a): engine and models, permissions, the shell
/// allowlist, the spend cap and MCP servers, all bound to `GraphcodeSettings.nod`. The
/// runtime reads the same file, so what this pane says is what Nod does.
struct NodSettingsPane: View {
  @Binding var settings: NodSettings
  @Bindable var setup: NodSetupModel
  var mcpServers: [NodMCPServer]

  @State private var newPattern = ""
  @State private var showsSetup = false

  var body: some View {
    Form {
      engineSection
      modelsSection
      permissionsSection
      allowlistSection
      spendSection
      mcpSection
    }
    .formStyle(.grouped)
    .sheet(isPresented: $showsSetup) {
      NodSetupView(model: setup) { showsSetup = false }
        .preferredColorScheme(.dark)
    }
  }

  private var engineSection: some View {
    Section {
      ForEach(NodEngine.allCases, id: \.self) { engine in
        HStack(spacing: 10) {
          Image(systemName: settings.engine == engine ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(settings.engine == engine ? Color.accentColor : .secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(engine.displayName)
            Text(NodModelCatalog.familySummary(for: engine))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if setup.isSignedIn(engine) {
            Text("signed in").font(.caption).foregroundStyle(NodSetupInk.ok)
            Button("Sign out") { setup.signOut(engine) }
          } else {
            Text("not signed in").font(.caption).foregroundStyle(.secondary)
            Button("Sign in…") {
              settings.switchEngine(to: engine)
              showsSetup = true
            }
          }
        }
        .contentShape(Rectangle())
        .onTapGesture { settings.switchEngine(to: engine) }
      }
    } header: {
      Text("Engine & models")
    } footer: {
      Text(
        "New loops use the selected engine. Existing loops keep the engine they started on."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var modelsSection: some View {
    Section {
      ForEach(LoopType.allCases, id: \.self) { loopType in
        Picker(loopType.displayName, selection: modelBinding(for: loopType)) {
          modelOptions
        }
      }
      Picker("Composite children", selection: childBinding) { modelOptions }
      Picker("Goal evaluator", selection: evaluatorBinding) { modelOptions }
    } header: {
      Text("Default model per loop type")
    } footer: {
      Text(
        "A model picked in the new-loop menu wins. The goal evaluator checks each clause of "
          + "a goal every time Nod tries to stop, so a fast model is usually enough."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var modelOptions: some View {
    ForEach(NodModelCatalog.models(for: settings.engine)) { model in
      Text(model.displayName).tag(model)
    }
  }

  private var permissionsSection: some View {
    Section {
      LabeledContent("Read files & search") { Text("Always").foregroundStyle(.secondary) }
      Picker("Edit files in the loop's worktree", selection: $settings.editsInWorktree) {
        ForEach(NodSettings.EditPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      Picker("Edit outside the worktree", selection: $settings.editsOutsideWorktree) {
        askOptions
      }
      Picker("Shell commands", selection: $settings.shell) { askOptions }
      Picker("Message other loops", selection: $settings.messagesOtherLoops) {
        ForEach(NodSettings.MessagePolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      Picker("Network", selection: $settings.network) { askOptions }
    } header: {
      Text("Permissions")
    } footer: {
      Text(settings.editsInWorktree.explanation)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var askOptions: some View {
    ForEach(NodSettings.Ask.allCases, id: \.self) { Text($0.displayName).tag($0) }
  }

  private var allowlistSection: some View {
    Section {
      ForEach(settings.shellAllowlist, id: \.self) { pattern in
        HStack {
          Text(pattern).font(.system(.body, design: .monospaced))
          Spacer()
          Button {
            settings.removeAllowlistPattern(pattern)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Remove \(pattern)")
        }
      }
      HStack {
        TextField("swift test *", text: $newPattern)
          .font(.system(.body, design: .monospaced))
          .onSubmit(addPattern)
        Button("Add", action: addPattern)
          .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    } header: {
      Text("Shell allowlist")
    } footer: {
      Text(
        "Commands matching a pattern run without asking, and their asks can be allowed from "
          + "the canvas card. Unattended types (Timed, and Composite children) can't stop to "
          + "ask. A command they'd have to ask about fails the run and shows up on the card. "
          + "It never waits silently."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var spendSection: some View {
    Section {
      LabeledContent("Cap per run") {
        HStack(spacing: 4) {
          Text("$")
          TextField(
            "", value: spendBinding, format: .number.precision(.fractionLength(2))
          )
          .frame(width: 70)
          .multilineTextAlignment(.trailing)
        }
      }
    } header: {
      Text("Spend cap")
    } footer: {
      Text(
        "Applies to Timed loops and Composite children; 0 is no cap. A loop that reaches it "
          + "stops and says so on its card. Copilot reports premium requests instead of "
          + "dollars and is capped by its plan."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var mcpSection: some View {
    Section {
      ForEach(mcpServers) { server in
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text(server.name)
            Text(Self.mcpDetail(server))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          switch server.source {
          case .builtIn:
            Text("always on").font(.caption).foregroundStyle(.secondary)
          case .project:
            if server.needsSignIn {
              Text("needs sign-in").font(.caption).foregroundStyle(NodSetupInk.warning)
              Button("Connect") {}
                .disabled(true)
                .help("Nod runs the server's sign-in the first time it starts in that project.")
            }
            Toggle("", isOn: mcpBinding(server.name))
              .labelsHidden()
              .toggleStyle(.switch)
              .controlSize(.small)
          }
        }
      }
    } header: {
      Text("MCP servers")
    } footer: {
      Text(
        "The graphcode server is how Nod sees the graph. It's read-only plus ask and handoff, "
          + "both gated by the permissions above."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  static func mcpDetail(_ server: NodMCPServer) -> String {
    switch server.source {
    case .builtIn: return "built in · siblings, edges, mailroom"
    case .project(let name): return "from .mcp.json · \(name)"
    }
  }

  private func addPattern() {
    if settings.addAllowlistPattern(newPattern) { newPattern = "" }
  }

  private func modelBinding(for loopType: LoopType) -> Binding<NodModel> {
    Binding(
      get: { settings.resolvedModel(for: loopType) },
      set: { settings.setModel($0, for: loopType) })
  }

  private var childBinding: Binding<NodModel> {
    Binding(
      get: { settings.resolvedCompositeChildModel },
      set: { settings.compositeChildModel = $0.id })
  }

  private var evaluatorBinding: Binding<NodModel> {
    Binding(
      get: { settings.resolvedGoalEvaluatorModel },
      set: { settings.goalEvaluatorModel = $0.id })
  }

  private var spendBinding: Binding<Double> {
    Binding(get: { settings.spendCapUSD }, set: { settings.setSpendCap($0) })
  }

  private func mcpBinding(_ name: String) -> Binding<Bool> {
    Binding(
      get: { !settings.disabledMCPServers.contains(name) },
      set: { isOn in
        settings.disabledMCPServers.removeAll { $0 == name }
        if !isOn { settings.disabledMCPServers.append(name) }
      })
  }
}

extension NodSettings.Ask {
  var displayName: String {
    switch self {
    case .always: "Always"
    case .ask: "Ask"
    case .never: "Never"
    }
  }
}

extension NodSettings.EditPolicy {
  var displayName: String {
    switch self {
    case .reviewHunks: "Review hunks"
    case .auto: "Auto"
    }
  }

  var explanation: String {
    switch self {
    case .reviewHunks:
      "Edits are staged, not written. A hunk lands in the loop's worktree only when you "
        + "accept it."
    case .auto:
      "Edits arrive already accepted and stay reviewable until the turn ends."
    }
  }
}

extension NodSettings.MessagePolicy {
  var displayName: String {
    switch self {
    case .draftForMe: "Draft for me"
    case .send: "Send"
    case .never: "Never"
    }
  }
}
