import Foundation

/// How far a goal loop's evaluator says it has got — the card's progress bar.
public struct NodGoalProgress: Codable, Equatable, Sendable {
  public var met: Int
  public var total: Int

  public init(met: Int, total: Int) {
    self.met = met
    self.total = total
  }
}

/// What a Nod loop's canvas card shows beyond what every backend reports. Folded from the
/// event log by the daemon, so the card never reads `events.jsonl` itself.
public struct NodCardState: Codable, Equatable, Sendable {
  public var goalProgress: NodGoalProgress?
  /// The newest permission ask nobody has answered; `answerableFromCard` says whether the
  /// card may offer Allow once or must open the chat.
  public var pendingAsk: NodEvent.PermissionAsked?

  public init(goalProgress: NodGoalProgress? = nil, pendingAsk: NodEvent.PermissionAsked? = nil) {
    self.goalProgress = goalProgress
    self.pendingAsk = pendingAsk
  }
}

/// The one fold over `events.jsonl` every reading of a Nod session comes from: presence,
/// the live line, usage, the goal verdict and the card state. Only the current run
/// counts — a `sessionStarted` resets everything, because what an earlier process asked
/// or spent says nothing about the one running now.
public struct NodSessionFold: Equatable, Sendable {
  public private(set) var session: NodEvent.SessionStarted?
  /// What the turn boundaries say, before asks and failures are considered.
  public private(set) var turnPresence: Presence?
  public private(set) var openAsks: [NodEvent.PermissionAsked] = []
  /// Cleared by the next turn: a failure is a banner until Nod runs again.
  public private(set) var failure: NodEvent.Failure?
  public private(set) var activity: String?
  public private(set) var usage: NodEvent.Usage?
  public private(set) var usageAt: Date?
  public private(set) var goalCheck: NodEvent.GoalCheck?
  public private(set) var goalCheckAt: Date?
  public private(set) var lastSeq: Int?
  /// The tool call the live line came from, so its result can clear it. `nil` when the
  /// line came from an `activity` event, which stands until the turn ends.
  private var activityCallID: String?

  public init() {}

  public init(records: some Sequence<NodEventRecord>) {
    for record in records { apply(record) }
  }

  public mutating func apply(_ record: NodEventRecord) {
    lastSeq = record.seq
    switch record.event {
    case .sessionStarted(let started):
      self = NodSessionFold()
      lastSeq = record.seq
      session = started
      turnPresence = .idle
    case .turnStarted:
      turnPresence = .busy
      failure = nil
      setActivity(nil)
    case .toolCall(let call):
      turnPresence = .busy
      setActivity(call.title, callID: call.callID)
    case .toolResult(let result):
      if result.status != .running, activityCallID == result.callID { setActivity(nil) }
    case .activity(let line):
      setActivity(line.line)
    case .permissionAsked(let ask):
      openAsks.removeAll { $0.askID == ask.askID }
      openAsks.append(ask)
    case .permissionResolved(let resolved):
      openAsks.removeAll { $0.askID == resolved.askID }
    case .failure(let failure):
      self.failure = failure
    case .turnEnded:
      turnPresence = .idle
      setActivity(nil)
    case .usage(let usage):
      self.usage = usage
      usageAt = record.at
    case .goalCheck(let check):
      goalCheck = check
      goalCheckAt = record.at
    case .userMessage, .assistantText, .hunkStaged, .hunkResolved, .planProposed, .mailDraft,
      .compacted, .unknown:
      break
    }
  }

  private mutating func setActivity(_ line: String?, callID: String? = nil) {
    activity = line
    activityCallID = callID
  }

  /// Needs you while an ask is open or a failure stopped the run. A full context is not
  /// one: Nod compacts on its own and carries on.
  public var presence: Presence? {
    if !openAsks.isEmpty { return .awaitingInput }
    if let failure, failure.kind != .contextFull { return .awaitingInput }
    return turnPresence
  }

  /// The card's live line: what Nod is doing, or what it is waiting on.
  public var activityLine: String? {
    if let ask = openAsks.last { return "asks to run \(ask.subject)" }
    if let failure, failure.kind != .contextFull { return failure.message }
    return activity
  }

  public var usageSample: UsageSample? {
    guard let usage else { return nil }
    return UsageSample(
      inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, costUSD: usage.costUSD,
      reportedAt: usageAt)
  }

  public var goalVerdict: GoalVerdict? {
    guard let goalCheck, let progress = goalProgress else { return nil }
    return GoalVerdict(
      met: goalCheck.met, detail: "\(progress.met) of \(progress.total) clauses met",
      recordedAt: goalCheckAt)
  }

  public var goalProgress: NodGoalProgress? {
    guard let goalCheck else { return nil }
    return NodGoalProgress(
      met: goalCheck.clauses.filter(\.met).count, total: goalCheck.clauses.count)
  }

  public var cardState: NodCardState {
    NodCardState(goalProgress: goalProgress, pendingAsk: openAsks.last)
  }
}
