import AppKit
import GraphcodeKit
import SwiftUI
import Testing

@testable import graphcode

/// Draws Nod's setup, settings, agent menu and cards to PNGs under `.build/nod-renders`
/// for review, through `NSHostingView` because `ImageRenderer` blanks scrolling content.
/// Each render also has to come out non-blank, so a view that lays out to nothing fails.
@MainActor
@Suite struct NodSetupRenderTests {
  static let directory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: ".build/nod-renders")

  final class Box: @unchecked Sendable {
    var settings = NodSettings(shellAllowlist: ["swift test *", "make lint", "git status|diff|log"])
  }

  static func setupModel(
    engine: NodEngine, phase: NodSetupModel.CopilotPhase = .idle,
    credentials: NodCredentialStore = .inMemory()
  ) -> NodSetupModel {
    let box = Box()
    box.settings.engine = engine
    let model = NodSetupModel(
      credentials: credentials,
      deviceFlow: CopilotDeviceFlow(clientID: nil, transport: { _ in (Data(), 500) }),
      readSettings: { box.settings }, writeSettings: { box.settings = $0 }, openURL: { _ in },
      claudeCodeSignInFound: { false })
    model.copilotPhase = phase
    return model
  }

  @discardableResult
  static func render(_ view: some View, _ name: String, size: CGSize) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let host = NSHostingView(
      rootView: view.frame(width: size.width, height: size.height)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .environment(\.colorScheme, .dark))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let url = directory.appending(path: "\(name).png")
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    #expect(distinctColours(rep) > 3, "\(name) rendered blank")
    return url
  }

  static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
    var seen = Set<UInt32>()
    for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
      for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        seen.insert(
          UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8
            | UInt32(c.blueComponent * 255))
        if seen.count > 50 { return seen.count }
      }
    }
    return seen.count
  }

  @Test func setupSheets() throws {
    let claude = Self.setupModel(engine: .claudeAgentSDK)
    claude.showsAPIKeyField = true
    try Self.render(
      NodSetupView(model: claude), "5a-setup-claude", size: .init(width: 520, height: 470))

    let code = CopilotDeviceFlow.DeviceCode(
      deviceCode: "d", userCode: "8F2K-QW7D",
      verificationURL: URL(string: "https://github.com/login/device")!,
      expiresAt: Date().addingTimeInterval(852), interval: .seconds(5))
    try Self.render(
      NodSetupView(model: Self.setupModel(engine: .copilotSDK, phase: .waiting(code))),
      "5b-copilot-waiting", size: .init(width: 520, height: 500))

    let account = CopilotDeviceFlow.Account(
      login: "scgopi", plan: "business", modelCount: 7, premiumRequestsUsed: 212,
      premiumRequestsLimit: 300)
    try Self.render(
      NodSetupView(
        model: Self.setupModel(
          engine: .copilotSDK, phase: .signedIn(account),
          credentials: .inMemory([.githubCopilot: "gho_x"]))),
      "5b-copilot-signed-in", size: .init(width: 520, height: 450))
  }

  @Test func settingsPanes() throws {
    let setup = Self.setupModel(
      engine: .claudeAgentSDK,
      credentials: .inMemory([.anthropicAPIKey: "sk-ant-x", .githubCopilot: "gho_x"]))
    let box = Box()
    let servers: [NodMCPServer] = [
      .graphcode,
      NodMCPServer(name: "github", source: .project("graphcode"), needsSignIn: false),
      NodMCPServer(name: "sentry", source: .project("graphcode"), needsSignIn: true),
    ]
    let pane = NodSettingsPane(
      settings: Binding(get: { box.settings }, set: { box.settings = $0 }), setup: setup,
      mcpServers: servers)
    try Self.render(
      HStack(spacing: 0) {
        SettingsSidebarMock(selected: .agent(.nod)).frame(width: 170)
        Divider()
        pane
      },
      "7a-settings-nod", size: .init(width: 780, height: 1500))

    var general = GraphcodeSettings()
    try Self.render(
      HStack(spacing: 0) {
        SettingsSidebarMock(selected: .agent(.copilotCLI)).frame(width: 170)
        Divider()
        CLIAgentSettingsPane(
          backend: .copilotCLI,
          settings: Binding(get: { general }, set: { general = $0 }))
      },
      "7a-settings-copilot-cli", size: .init(width: 780, height: 420))
  }

  @Test func agentMenu() throws {
    try Self.render(
      AgentMenuMock(loopType: .composite), "6a-agent-menu-composite",
      size: .init(width: 300, height: 300))
    try Self.render(
      AgentMenuMock(loopType: .goalBased), "6a-agent-menu-goal",
      size: .init(width: 300, height: 300))
  }

  @Test func canvasCards() throws {
    let now = Date()
    let codex = LoopNode(
      title: "Billing UI", loopType: .turnBased, checkDescription: "diff reads clean",
      backend: .codex, activity: "working…", state: .running)
    let goal = LoopNode(
      title: "Monetization", loopType: .goalBased,
      goal: GoalSpec(summary: "every paid route enforces the cap"), backend: .nod,
      activity: "Running swift test · turn 4", state: .running)
    let ask = LoopNode(
      title: "Cap research", loopType: .sketch, backend: .nod,
      activity: "asks to run swift package resolve", state: .awaitingInput)
    let allowlisted = LoopNode(
      title: "Lint sweep", loopType: .sketch, backend: .nod,
      activity: "asks to run make lint", state: .awaitingInput)
    try Self.render(
      VStack(spacing: 14) {
        LoopCardView(node: codex, reason: nil, now: now, onPrimaryAction: {})
        LoopCardView(
          node: goal, reason: nil, now: now, onPrimaryAction: {},
          nod: NodCardDetail(goalMet: 1, goalTotal: 2))
        LoopCardView(
          node: ask, reason: .awaitingInput, now: now, onPrimaryAction: {},
          nod: NodCardDetail(
            ask: .init(
              askID: "a", kind: .network, subject: "swift package resolve",
              answerableFromCard: false)))
        LoopCardView(
          node: allowlisted, reason: .awaitingInput, now: now, onPrimaryAction: {},
          nod: NodCardDetail(
            ask: .init(askID: "b", kind: .shell, subject: "make lint", answerableFromCard: true)))
      }
      .padding(20),
      "6b-canvas-cards", size: .init(width: 300, height: 480))
  }
}

/// The settings sidebar as drawn, for the render only: `NavigationSplitView` draws nothing
/// in an offscreen host.
private struct SettingsSidebarMock: View {
  let selected: SettingsPane

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      row("General", .general)
      Text("Agents").font(.caption).foregroundStyle(.secondary).padding(.top, 8).padding(
        .leading, 8)
      ForEach(CLISessionBackendKind.settingsOrder, id: \.self) { row($0.displayName, .agent($0)) }
      row("Templates", .templates).padding(.top, 8)
      Spacer()
    }
    .padding(8)
  }

  private func row(_ title: String, _ pane: SettingsPane) -> some View {
    Text(title)
      .padding(.vertical, 4)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        pane == selected ? Color.accentColor.opacity(0.35) : .clear,
        in: RoundedRectangle(cornerRadius: 5))
  }
}

/// The open agent menu, drawn from the same `AgentMenuSection` values the real menu uses.
private struct AgentMenuMock: View {
  let loopType: LoopType

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(
        "Agent: \(AgentMenuSection.label(backend: .nod, tier: nil, loopType: loopType, nod: NodSettings())) ▾"
      )
      .font(.system(size: 12, weight: .semibold))
      .padding(.bottom, 6)
      ForEach(AgentMenuSection.sections(for: loopType), id: \.surface) { section in
        Text(section.title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
          .padding(.top, 4)
        ForEach(section.entries, id: \.backend) { entry in
          HStack {
            Text(entry.label)
            if entry.backend == .nod { Text("Claude Agent SDK ✓").foregroundStyle(.secondary) }
            Spacer()
            if let note = entry.note { Text(note).foregroundStyle(.secondary) }
          }
          .font(.system(size: 12))
          .opacity(entry.isEnabled ? 1 : 0.4)
          if entry.backend == .nod {
            HStack {
              Text("Model")
              Spacer()
              Text("\(NodSettings().resolvedModel(for: loopType).displayName) ▸")
            }
            .font(.system(size: 12))
            .opacity(entry.isEnabled ? 1 : 0.4)
          }
        }
      }
      Spacer()
    }
    .padding(12)
  }
}
