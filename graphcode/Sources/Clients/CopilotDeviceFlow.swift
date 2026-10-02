import Foundation

/// GitHub's OAuth device flow, for Nod's Copilot engine: ask for a code, show it, poll
/// until the person enters it at github.com/login/device, then read the account's
/// Copilot plan so the success state can say what the seat buys.
///
/// The token goes to the Keychain (`NodCredential.githubCopilot`). Every request goes
/// through `transport`, so tests replay GitHub's documented responses without a network.
struct CopilotDeviceFlow: Sendable {
  typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

  struct DeviceCode: Equatable, Sendable {
    var deviceCode: String
    var userCode: String
    var verificationURL: URL
    var expiresAt: Date
    var interval: Duration
  }

  struct Account: Equatable, Sendable {
    var login: String
    /// GitHub's plan word, e.g. `business`; `planName` is the display form.
    var plan: String?
    var modelCount: Int?
    var premiumRequestsUsed: Int?
    var premiumRequestsLimit: Int?

    var planName: String? {
      plan.map { "Copilot " + $0.replacingOccurrences(of: "_", with: " ").capitalized }
    }
  }

  enum Failure: Error, Equatable {
    /// This build carries no GitHub OAuth app client id.
    case notConfigured
    case expired
    case denied
    case unexpected(String)
  }

  var clientID: String?
  var transport: Transport
  var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  var now: @Sendable () -> Date = { Date() }

  static let scope = "read:user"

  static var bundledClientID: String? {
    (Bundle.main.object(forInfoDictionaryKey: "GraphCodeGitHubClientID") as? String)
      .flatMap { $0.isEmpty ? nil : $0 }
  }

  static let live = CopilotDeviceFlow(clientID: bundledClientID) { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  func requestCode() async throws -> DeviceCode {
    guard let clientID else { throw Failure.notConfigured }
    let json = try await post(
      "https://github.com/login/device/code", ["client_id": clientID, "scope": Self.scope])
    guard
      let deviceCode = json["device_code"] as? String,
      let userCode = json["user_code"] as? String,
      let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)),
      let expiresIn = json["expires_in"] as? Int
    else { throw Failure.unexpected(Self.describe(json)) }
    return DeviceCode(
      deviceCode: deviceCode, userCode: userCode, verificationURL: uri,
      expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
      interval: .seconds(json["interval"] as? Int ?? 5))
  }

  /// Polls until GitHub hands over a token, the code expires, or the person declines.
  /// `slow_down` adds five seconds to the interval, as GitHub asks.
  func pollForToken(_ code: DeviceCode) async throws -> String {
    guard let clientID else { throw Failure.notConfigured }
    var interval = code.interval
    while true {
      try await sleep(interval)
      guard now() < code.expiresAt else { throw Failure.expired }
      let json = try await post(
        "https://github.com/login/oauth/access_token",
        [
          "client_id": clientID, "device_code": code.deviceCode,
          "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
      if let token = json["access_token"] as? String { return token }
      switch json["error"] as? String {
      case "authorization_pending":
        continue
      case "slow_down":
        interval = .seconds(json["interval"] as? Int ?? Int(interval.components.seconds) + 5)
      case "expired_token":
        throw Failure.expired
      case "access_denied":
        throw Failure.denied
      default:
        throw Failure.unexpected(Self.describe(json))
      }
    }
  }

  /// The login, then the Copilot plan, premium requests and model count. Only the login
  /// is required: the plan endpoints are GitHub's internal ones and a missing answer
  /// leaves that line off the success state rather than failing a sign-in that worked.
  func account(token: String) async throws -> Account {
    let user = try await get("https://api.github.com/user", token: "token \(token)")
    guard let login = user["login"] as? String else {
      throw Failure.unexpected(Self.describe(user))
    }
    var account = Account(login: login)
    if let copilot = try? await get(
      "https://api.github.com/copilot_internal/user", token: "token \(token)")
    {
      account.plan = copilot["copilot_plan"] as? String
      if let premium = (copilot["quota_snapshots"] as? [String: Any])?["premium_interactions"]
        as? [String: Any],
        premium["unlimited"] as? Bool != true,
        let entitlement = premium["entitlement"] as? Int,
        let remaining = premium["remaining"] as? Int
      {
        account.premiumRequestsLimit = entitlement
        account.premiumRequestsUsed = max(0, entitlement - remaining)
      }
    }
    if let session = try? await get(
      "https://api.github.com/copilot_internal/v2/token", token: "token \(token)"),
      let sessionToken = session["token"] as? String,
      let models = try? await get(
        "https://api.githubcopilot.com/models", token: "Bearer \(sessionToken)"),
      let data = models["data"] as? [[String: Any]]
    {
      account.modelCount = data.filter { $0["model_picker_enabled"] as? Bool ?? true }.count
    }
    return account
  }

  private func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var components = URLComponents()
    components.queryItems = form.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
    return try await send(request)
  }

  private func get(_ url: String, token: String) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: url)!)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(token, forHTTPHeaderField: "Authorization")
    return try await send(request)
  }

  private func send(_ request: URLRequest) async throws -> [String: Any] {
    let (data, status) = try await transport(request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    // The device-flow errors arrive as 200s with an `error` field; anything else non-2xx
    // is a real failure.
    guard (200..<300).contains(status) || json["error"] != nil else {
      throw Failure.unexpected("HTTP \(status)")
    }
    return json
  }

  private static func describe(_ json: [String: Any]) -> String {
    (json["error_description"] as? String) ?? (json["error"] as? String) ?? "unexpected reply"
  }
}

/// Display helpers for the sign-in card, kept apart from the view so tests pin them.
enum CopilotSignInText {
  /// "14:12" — minutes and seconds until the code expires, never negative.
  static func countdown(until expiry: Date, now: Date) -> String {
    let remaining = max(0, Int(expiry.timeIntervalSince(now).rounded(.down)))
    return String(format: "%d:%02d", remaining / 60, remaining % 60)
  }

  /// "7 models available · premium requests 212 / 300 this month", leaving out what
  /// GitHub did not say.
  static func accountDetail(_ account: CopilotDeviceFlow.Account) -> String {
    var parts: [String] = []
    if let count = account.modelCount {
      parts.append("\(count) model\(count == 1 ? "" : "s") available")
    }
    if let used = account.premiumRequestsUsed, let limit = account.premiumRequestsLimit {
      parts.append("premium requests \(used) / \(limit) this month")
    }
    return parts.joined(separator: " · ")
  }
}
