import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

@Suite struct NodModelCatalogTests {
  @Test func everyEngineOffersEveryTier() {
    for engine in NodEngine.allCases {
      for tier in ModelTier.allCases {
        #expect(NodModelCatalog.model(for: tier, engine: engine).tier == tier)
      }
    }
  }

  @Test func defaultsFollowTheDesignPerLoopType() {
    let settings = NodSettings()
    #expect(settings.resolvedModel(for: .sketch).displayName == "Sonnet")
    #expect(settings.resolvedModel(for: .goalBased).displayName == "Opus")
    #expect(settings.resolvedModel(for: .timeBased).displayName == "Haiku")
    #expect(settings.resolvedModel(for: .turnBased).displayName == "Sonnet")
    #expect(settings.resolvedModel(for: .composite).displayName == "Opus")
    #expect(settings.resolvedCompositeChildModel.displayName == "Sonnet")
    #expect(settings.resolvedGoalEvaluatorModel.displayName == "Haiku")
  }

  @Test func anExplicitTierBeatsTheStoredChoice() {
    var settings = NodSettings()
    settings.modelsByLoopType[LoopType.goalBased.rawValue] = "haiku"
    #expect(settings.resolvedModel(for: .goalBased).id == "haiku")
    #expect(settings.resolvedModel(for: .goalBased, tier: .standard).id == "sonnet")
  }

  @Test func aStaleStoredModelFallsBackToTheDefault() {
    var settings = NodSettings()
    settings.modelsByLoopType[LoopType.sketch.rawValue] = "claude-2"
    settings.goalEvaluatorModel = "gone"
    #expect(settings.resolvedModel(for: .sketch).id == "sonnet")
    #expect(settings.resolvedGoalEvaluatorModel.id == "haiku")
  }

  @Test func choosingTheDefaultClearsTheEntry() {
    var settings = NodSettings()
    settings.setModel(NodModelCatalog.model(for: .fast, engine: .claudeAgentSDK), for: .sketch)
    #expect(settings.modelsByLoopType == ["sketch": "haiku"])
    settings.setModel(NodModelCatalog.model(for: .standard, engine: .claudeAgentSDK), for: .sketch)
    #expect(settings.modelsByLoopType.isEmpty)
  }

  @Test func switchingEngineDropsModelsTheNewEngineCannotRun() {
    var settings = NodSettings(
      modelsByLoopType: ["sketch": "haiku"], compositeChildModel: "opus",
      goalEvaluatorModel: "haiku")
    settings.switchEngine(to: .copilotSDK)
    #expect(settings.engine == .copilotSDK)
    #expect(settings.modelsByLoopType.isEmpty)
    #expect(settings.compositeChildModel == nil)
    #expect(settings.goalEvaluatorModel == nil)
    #expect(settings.resolvedModel(for: .goalBased).family == .claude)
    #expect(settings.resolvedModel(for: .timeBased).id == "gpt-5.6-luna")
  }

  @Test func allowlistTrimsAndIgnoresDuplicates() {
    var settings = NodSettings()
    let added = settings.addAllowlistPattern("  swift test *  ")
    let duplicate = settings.addAllowlistPattern("swift test *")
    let blank = settings.addAllowlistPattern("   ")
    let second = settings.addAllowlistPattern("make lint")
    #expect(added && !duplicate && !blank && second)
    settings.removeAllowlistPattern("swift test *")
    #expect(settings.shellAllowlist == ["make lint"])
  }

  @Test func spendCapRejectsNonsense() {
    var settings = NodSettings()
    settings.setSpendCap(2.499)
    #expect(settings.spendCapUSD == 2.5)
    settings.setSpendCap(-1)
    #expect(settings.spendCapUSD == 0)
    settings.setSpendCap(.infinity)
    #expect(settings.spendCapUSD == 0)
  }

  @Test func nodSettingsRoundTripThroughGraphcodeSettings() throws {
    var settings = GraphcodeSettings()
    settings.nod.switchEngine(to: .copilotSDK)
    settings.nod.disabledMCPServers = ["sentry"]
    settings.nod.addAllowlistPattern("make lint")
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(GraphcodeSettings.self, from: data)
    #expect(decoded.nod == settings.nod)
  }

  @Test func olderSettingsWithoutTheNewFieldStillDecode() throws {
    let decoded = try JSONDecoder().decode(
      NodSettings.self, from: Data(#"{"engine":"copilot","spendCapUSD":5}"#.utf8))
    #expect(decoded.engine == .copilotSDK)
    #expect(decoded.spendCapUSD == 5)
    #expect(decoded.disabledMCPServers.isEmpty)
  }
}

@Suite struct NodCredentialStoreTests {
  @Test func inMemoryStoreTracksSignInPerEngine() throws {
    let store = NodCredentialStore.inMemory()
    #expect(!store.isSignedIn(.claudeAgentSDK))
    try store.write("sk-ant-api03-0123456789abcdef", .anthropicAPIKey)
    #expect(store.isSignedIn(.claudeAgentSDK))
    #expect(!store.isSignedIn(.copilotSDK))
    try store.write("gho_token", .githubCopilot)
    #expect(store.isSignedIn(.copilotSDK))
    try store.signOut(.claudeAgentSDK)
    #expect(!store.isSignedIn(.claudeAgentSDK))
    #expect(store.isSignedIn(.copilotSDK))
  }

  @Test func anEmptySecretIsNotASignIn() throws {
    let store = NodCredentialStore.inMemory([.githubCopilot: ""])
    #expect(!store.isSignedIn(.copilotSDK))
  }

  @Test func liveKeychainWritesReadsOverwritesAndDeletes() throws {
    let store = NodCredentialStore.keychain(service: "app.graphcode.nod.tests.\(UUID())")
    defer { try? store.delete(.anthropicAPIKey) }
    #expect(try store.read(.anthropicAPIKey) == nil)
    try store.write("sk-ant-first", .anthropicAPIKey)
    #expect(try store.read(.anthropicAPIKey) == "sk-ant-first")
    try store.write("sk-ant-second", .anthropicAPIKey)
    #expect(try store.read(.anthropicAPIKey) == "sk-ant-second")
    try store.delete(.anthropicAPIKey)
    #expect(try store.read(.anthropicAPIKey) == nil)
    try store.delete(.anthropicAPIKey)
  }

  @Test func liveStoreUsesNodsKeychainService() {
    #expect(NodSettings.keychainService == "app.graphcode.nod")
  }
}

@Suite struct NodClaudeSignInTests {
  @Test func subscriptionLoginStaysOffUntilAnthropicApprovesIt() {
    #expect(!NodClaudeSignIn.subscriptionLoginAllowed)
  }

  @Test func apiKeyIsTrimmedAndChecked() {
    #expect(
      NodClaudeSignIn.validateAPIKey("  sk-ant-api03-abcdefghijklmnop\n")
        == .success("sk-ant-api03-abcdefghijklmnop"))
    #expect(NodClaudeSignIn.validateAPIKey("   ") == .failure(.empty))
    #expect(NodClaudeSignIn.validateAPIKey("gho_abcdefghijklmnopqrstuvwxyz") == .failure(.notAnAnthropicKey))
    #expect(NodClaudeSignIn.validateAPIKey("sk-ant-short") == .failure(.notAnAnthropicKey))
  }

  @Test func claudeCodeSignInIsFoundByKeychainItemOrFile() throws {
    let home = FileManager.default.temporaryDirectory.appending(path: "nod-home-\(UUID())")
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(!NodClaudeSignIn.claudeCodeSignInFound(home: home) { _ in false })
    #expect(NodClaudeSignIn.claudeCodeSignInFound(home: home) { $0 == "Claude Code-credentials" })
    try FileManager.default.createDirectory(
      at: home.appending(path: ".claude"), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: home.appending(path: ".claude/.credentials.json"))
    #expect(NodClaudeSignIn.claudeCodeSignInFound(home: home) { _ in false })
  }
}

@Suite struct CopilotDeviceFlowTests {
  final class Script: @unchecked Sendable {
    var replies: [(String, Int, String)]
    var requests: [URLRequest] = []
    var sleeps: [Duration] = []
    let lock = NSLock()

    init(_ replies: [(String, Int, String)]) { self.replies = replies }

    func reply(to request: URLRequest) -> (Data, Int) {
      lock.withLock {
        requests.append(request)
        guard
          let index = replies.firstIndex(where: {
            request.url!.absoluteString.hasSuffix($0.0)
          })
        else { return (Data(), 404) }
        let reply = replies.remove(at: index)
        return (Data(reply.2.utf8), reply.1)
      }
    }

    func flow(clientID: String? = "Iv1.test", now: Date = Date(timeIntervalSince1970: 0))
      -> CopilotDeviceFlow
    {
      CopilotDeviceFlow(
        clientID: clientID,
        transport: { request in
          self.reply(to: request)
        },
        sleep: { duration in
          self.lock.withLock { self.sleeps.append(duration) }
        },
        now: { now })
    }
  }

  static let code = CopilotDeviceFlow.DeviceCode(
    deviceCode: "dev", userCode: "8F2K-QW7D",
    verificationURL: URL(string: "https://github.com/login/device")!,
    expiresAt: Date(timeIntervalSince1970: 900), interval: .seconds(5))

  @Test func requestsACodeWithTheClientIDAndScope() async throws {
    let script = Script([
      (
        "/login/device/code", 200,
        #"{"device_code":"dev","user_code":"8F2K-QW7D","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
      )
    ])
    let code = try await script.flow().requestCode()
    #expect(code == Self.code)
    let body = String(data: script.requests[0].httpBody!, encoding: .utf8)
    #expect(body == "client_id=Iv1.test&scope=read:user")
    #expect(script.requests[0].value(forHTTPHeaderField: "Accept") == "application/json")
  }

  @Test func withoutAClientIDItSaysSoInsteadOfCallingGitHub() async {
    let script = Script([])
    await #expect(throws: CopilotDeviceFlow.Failure.notConfigured) {
      try await script.flow(clientID: nil).requestCode()
    }
    #expect(script.requests.isEmpty)
  }

  @Test func pollsThroughPendingAndSlowDownToAToken() async throws {
    let script = Script([
      ("/login/oauth/access_token", 200, #"{"error":"authorization_pending"}"#),
      ("/login/oauth/access_token", 200, #"{"error":"slow_down","interval":10}"#),
      ("/login/oauth/access_token", 200, #"{"access_token":"gho_abc","token_type":"bearer"}"#),
    ])
    let token = try await script.flow().pollForToken(Self.code)
    #expect(token == "gho_abc")
    #expect(script.sleeps == [.seconds(5), .seconds(5), .seconds(10)])
    let body = String(data: script.requests[0].httpBody!, encoding: .utf8)!
    #expect(body.contains("grant_type=urn:ietf:params:oauth:grant-type:device_code"))
  }

  @Test func expiryAndDenialEndThePoll() async {
    let expired = Script([("/login/oauth/access_token", 200, #"{"error":"expired_token"}"#)])
    await #expect(throws: CopilotDeviceFlow.Failure.expired) {
      try await expired.flow().pollForToken(Self.code)
    }
    let denied = Script([("/login/oauth/access_token", 200, #"{"error":"access_denied"}"#)])
    await #expect(throws: CopilotDeviceFlow.Failure.denied) {
      try await denied.flow().pollForToken(Self.code)
    }
    let late = Script([])
    await #expect(throws: CopilotDeviceFlow.Failure.expired) {
      try await late.flow(now: Date(timeIntervalSince1970: 901)).pollForToken(Self.code)
    }
    #expect(late.requests.isEmpty)
  }

  @Test func readsTheAccountPlanPremiumRequestsAndModels() async throws {
    let script = Script([
      ("api.github.com/user", 200, #"{"login":"scgopi"}"#),
      (
        "/copilot_internal/user", 200,
        #"{"copilot_plan":"business","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":88,"unlimited":false}}}"#
      ),
      ("/copilot_internal/v2/token", 200, #"{"token":"tid=abc"}"#),
      (
        "/models", 200,
        #"{"data":[{"id":"a","model_picker_enabled":true},{"id":"b"},{"id":"c","model_picker_enabled":false}]}"#
      ),
    ])
    let account = try await script.flow().account(token: "gho_abc")
    #expect(
      account
        == .init(
          login: "scgopi", plan: "business", modelCount: 2, premiumRequestsUsed: 212,
          premiumRequestsLimit: 300))
    #expect(account.planName == "Copilot Business")
    #expect(script.requests[0].value(forHTTPHeaderField: "Authorization") == "token gho_abc")
    #expect(script.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tid=abc")
  }

  @Test func aMissingPlanStillSignsIn() async throws {
    let script = Script([("api.github.com/user", 200, #"{"login":"scgopi"}"#)])
    let account = try await script.flow().account(token: "gho_abc")
    #expect(account == .init(login: "scgopi"))
    #expect(CopilotSignInText.accountDetail(account) == "")
  }

  @Test func signInText() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(CopilotSignInText.countdown(until: Date(timeIntervalSince1970: 852), now: now) == "14:12")
    #expect(CopilotSignInText.countdown(until: Date(timeIntervalSince1970: -5), now: now) == "0:00")
    #expect(
      CopilotSignInText.accountDetail(
        .init(
          login: "scgopi", plan: "business", modelCount: 7, premiumRequestsUsed: 212,
          premiumRequestsLimit: 300))
        == "7 models available · premium requests 212 / 300 this month")
  }
}
