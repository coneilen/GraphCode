import Foundation

/// The wire contract between NodRuntime (the `graphcode-nod` process) and graphcode —
/// NodRuntime/PROTOCOL.md is the prose version and must change with this file.
///
/// Every event and command is one JSON object on one line, discriminated by `type`, with
/// the payload's fields flattened beside it. Flattened rather than nested so the
/// TypeScript side can declare the same shapes as a plain discriminated union.
public enum NodProtocol {
  /// Bumped only for a change an older reader would misread. Additive fields and new
  /// event types do not bump it: readers decode unknown types as `.unknown` instead.
  public static let version = 1
}

// MARK: - Shared vocabulary

public enum NodEngine: String, Codable, CaseIterable, Sendable {
  case claudeAgentSDK = "claude"
  case copilotSDK = "copilot"

  public var displayName: String {
    switch self {
    case .claudeAgentSDK: return "Claude Agent SDK"
    case .copilotSDK: return "GitHub Copilot SDK"
    }
  }
}

/// Return queues (waits for the turn to end); ⌘Return steers (lands at the next tool
/// boundary without interrupting).
public enum NodDelivery: String, Codable, Sendable {
  case queue
  case steer
}

public enum NodTurnOrigin: String, Codable, Sendable {
  case user
  case queue
  case steer
  case handoff
  case mail
  case timer
  case goalCheck
}

public struct NodAttachment: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case file
    case image
    /// Another loop's transcript, summarised to its beats and final state.
    case loopTranscript
  }

  public var kind: Kind
  /// A path for `.file`/`.image`, a node id for `.loopTranscript`.
  public var reference: String
  public var label: String?

  public init(kind: Kind, reference: String, label: String? = nil) {
    self.kind = kind
    self.reference = reference
    self.label = label
  }
}

public struct NodGoalClause: Codable, Equatable, Sendable {
  public var text: String
  public var met: Bool
  public var evidence: String?

  public init(text: String, met: Bool, evidence: String? = nil) {
    self.text = text
    self.met = met
    self.evidence = evidence
  }
}

public struct NodPlanStep: Codable, Equatable, Sendable {
  public enum Size: String, Codable, Sendable {
    case small, medium, large
  }

  public var id: String
  public var text: String
  public var files: [String]
  public var size: Size?
  /// Set once a human has rewritten the step, so Nod treats it as theirs.
  public var editedByHuman: Bool
  /// The step that verifies the others. Run as Composite makes it the composite's check
  /// rather than a child loop.
  public var doneCheck: Bool

  public init(
    id: String, text: String, files: [String] = [], size: Size? = nil,
    editedByHuman: Bool = false, doneCheck: Bool = false
  ) {
    self.id = id
    self.text = text
    self.files = files
    self.size = size
    self.editedByHuman = editedByHuman
    self.doneCheck = doneCheck
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    text = try container.decode(String.self, forKey: .text)
    files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
    size = try? container.decodeIfPresent(Size.self, forKey: .size)
    editedByHuman = try container.decodeIfPresent(Bool.self, forKey: .editedByHuman) ?? false
    doneCheck = try container.decodeIfPresent(Bool.self, forKey: .doneCheck) ?? false
  }
}

/// What a loop inherits from the loop it came from — a composite child from the planning
/// conversation, a fork from the message it branched at. Written as JSON by the app before
/// the loop is created (`LoopLineage.briefPath`); the launcher passes `--inherit <path>` on
/// a fresh start, never on a resume, and the runtime sends it as turn 1 with origin
/// `handoff`.
public struct NodBrief: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case compositeChild
    case fork
  }

  /// Where a fork branches: the parent's engine conversation, cut after `messageID`.
  public struct ForkPoint: Codable, Equatable, Sendable {
    public var conversationID: String?
    public var messageID: String

    public init(conversationID: String? = nil, messageID: String) {
      self.conversationID = conversationID
      self.messageID = messageID
    }
  }

  public var v: Int
  public var kind: Kind
  public var fromNodeID: UUID
  public var text: String
  public var attachments: [NodAttachment]
  public var fork: ForkPoint?

  public init(
    kind: Kind, fromNodeID: UUID, text: String, attachments: [NodAttachment] = [],
    fork: ForkPoint? = nil
  ) {
    self.v = NodProtocol.version
    self.kind = kind
    self.fromNodeID = fromNodeID
    self.text = text
    self.attachments = attachments
    self.fork = fork
  }
}

public enum NodPermissionKind: String, Codable, Sendable {
  case shell
  case network
  case editOutsideWorktree
  case messageLoop
  case mcpTool
}

public enum NodPermissionDecision: String, Codable, Sendable {
  case allowOnce
  case alwaysAllow
  case deny
}

public enum NodHunkDecision: String, Codable, Sendable {
  case accept
  case reject
  /// Sent back with a note rather than accepted or rejected outright.
  case comment
}

public enum NodToolStatus: String, Codable, Sendable {
  case running
  case ok
  case error
}

public enum NodFailureKind: String, Codable, Sendable {
  case signInExpired
  case contextFull
  case spendCap
  /// An unattended loop hit a permission it could not ask about.
  case permissionUnavailable
  case engineError
}

// MARK: - Events (runtime → graphcode)

public enum NodEvent: Equatable, Sendable {
  public struct SessionStarted: Codable, Equatable, Sendable {
    public var engine: NodEngine
    public var model: String
    /// The engine's own conversation id — what `--resume` takes.
    public var conversationID: String
    public var resumed: Bool
  }

  public struct TurnStarted: Codable, Equatable, Sendable {
    public var turn: Int
    public var origin: NodTurnOrigin
  }

  public struct UserMessage: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var delivery: NodDelivery
    public var attachments: [NodAttachment]
    /// The loop it came from, for mail and handoffs.
    public var fromNodeID: UUID?
  }

  /// Streamed: `delta` texts with one `messageID` concatenate; `final` closes it.
  public struct AssistantText: Codable, Equatable, Sendable {
    public var turn: Int
    public var messageID: String
    public var delta: String
    public var final: Bool
  }

  public struct ToolCall: Codable, Equatable, Sendable {
    public var turn: Int
    public var callID: String
    public var tool: String
    /// The one-line card title, e.g. `Search "UsageGate"`.
    public var title: String
  }

  public struct ToolResult: Codable, Equatable, Sendable {
    public var callID: String
    public var status: NodToolStatus
    /// e.g. `6 hits in 4 files`, `exit 0`.
    public var summary: String
    public var output: String?
    public var durationMs: Int?
  }

  /// An edit Nod wants to make. Staged, not written: it lands in the loop's worktree only
  /// when accepted — or arrives already accepted in Auto mode.
  public struct HunkStaged: Codable, Equatable, Sendable {
    public var turn: Int
    public var hunkID: String
    public var file: String
    public var header: String
    /// Unified diff of this hunk alone.
    public var diff: String
    public var added: Int
    public var removed: Int
    public var autoAccepted: Bool
  }

  public struct HunkResolved: Codable, Equatable, Sendable {
    public var hunkID: String
    public var decision: NodHunkDecision
    public var note: String?
  }

  public struct PermissionAsked: Codable, Equatable, Sendable {
    public var askID: String
    public var kind: NodPermissionKind
    /// What would run, e.g. `swift package resolve`.
    public var subject: String
    public var reason: String
    /// Allowlisted or read-only asks may be answered from the canvas card; anything else
    /// opens the chat so the human sees what led to it.
    public var answerableFromCard: Bool
  }

  public struct PermissionResolved: Codable, Equatable, Sendable {
    public var askID: String
    public var decision: NodPermissionDecision
  }

  public struct GoalCheck: Codable, Equatable, Sendable {
    public var turn: Int
    public var evaluatorModel: String
    public var clauses: [NodGoalClause]
    public var met: Bool
  }

  public struct TurnEnded: Codable, Equatable, Sendable {
    public var turn: Int
    public var filesChanged: Int
    public var added: Int
    public var removed: Int
    /// One line for the turn ledger and the summary rail.
    public var summary: String?
  }

  public struct Usage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double?
    /// Copilot bills premium requests instead of dollars.
    public var premiumRequests: Int?
    /// 0…1 of the model's context window in use.
    public var contextUsed: Double
  }

  public struct PlanProposed: Codable, Equatable, Sendable {
    public var planID: String
    public var title: String
    public var steps: [NodPlanStep]
  }

  /// A reply Nod drafted to another loop's question; sent only when a human approves it
  /// (the default "Draft for me" messaging permission).
  public struct MailDraft: Codable, Equatable, Sendable {
    public var draftID: String
    public var toNodeID: UUID
    public var inReplyTo: String?
    public var text: String
  }

  public struct Compacted: Codable, Equatable, Sendable {
    public var fromTurn: Int
    public var throughTurn: Int
  }

  /// The live line on the canvas card, e.g. `Running swift test · turn 4`.
  public struct Activity: Codable, Equatable, Sendable {
    public var line: String
  }

  public struct Failure: Codable, Equatable, Sendable {
    public var kind: NodFailureKind
    public var message: String
  }

  case sessionStarted(SessionStarted)
  case turnStarted(TurnStarted)
  case userMessage(UserMessage)
  case assistantText(AssistantText)
  case toolCall(ToolCall)
  case toolResult(ToolResult)
  case hunkStaged(HunkStaged)
  case hunkResolved(HunkResolved)
  case permissionAsked(PermissionAsked)
  case permissionResolved(PermissionResolved)
  case goalCheck(GoalCheck)
  case turnEnded(TurnEnded)
  case usage(Usage)
  case planProposed(PlanProposed)
  case mailDraft(MailDraft)
  case compacted(Compacted)
  case activity(Activity)
  case failure(Failure)
  /// A type this build does not know. Kept rather than thrown, so a newer runtime never
  /// breaks an older app's reader.
  case unknown(String)
}

/// One line of `events.jsonl`.
public struct NodEventRecord: Equatable, Sendable {
  public var seq: Int
  public var at: Date
  public var event: NodEvent

  public init(seq: Int, at: Date, event: NodEvent) {
    self.seq = seq
    self.at = at
    self.event = event
  }
}

// MARK: - Commands (graphcode → runtime)

public enum NodCommand: Equatable, Sendable {
  public struct Send: Codable, Equatable, Sendable {
    public var text: String
    public var delivery: NodDelivery
    public var attachments: [NodAttachment]

    public init(text: String, delivery: NodDelivery = .queue, attachments: [NodAttachment] = []) {
      self.text = text
      self.delivery = delivery
      self.attachments = attachments
    }
  }

  public struct ResolveHunk: Codable, Equatable, Sendable {
    public var hunkID: String
    public var decision: NodHunkDecision
    public var note: String?

    public init(hunkID: String, decision: NodHunkDecision, note: String? = nil) {
      self.hunkID = hunkID
      self.decision = decision
      self.note = note
    }
  }

  public struct ResolvePermission: Codable, Equatable, Sendable {
    public var askID: String
    public var decision: NodPermissionDecision

    public init(askID: String, decision: NodPermissionDecision) {
      self.askID = askID
      self.decision = decision
    }
  }

  public struct RunPlan: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
      case here
      case composite
    }

    public var planID: String
    public var steps: [NodPlanStep]
    public var mode: Mode

    public init(planID: String, steps: [NodPlanStep], mode: Mode) {
      self.planID = planID
      self.steps = steps
      self.mode = mode
    }
  }

  public struct Fork: Codable, Equatable, Sendable {
    public var messageID: String

    public init(messageID: String) {
      self.messageID = messageID
    }
  }

  public struct SendDraft: Codable, Equatable, Sendable {
    public var draftID: String
    /// The text as sent, which may differ from the draft if the human edited it.
    public var text: String

    public init(draftID: String, text: String) {
      self.draftID = draftID
      self.text = text
    }
  }

  public struct SetModel: Codable, Equatable, Sendable {
    public var model: String

    public init(model: String) {
      self.model = model
    }
  }

  case send(Send)
  case stop
  case resolveHunk(ResolveHunk)
  case resolvePermission(ResolvePermission)
  case runPlan(RunPlan)
  case fork(Fork)
  case sendDraft(SendDraft)
  case compact
  case setModel(SetModel)
  case markGoalDone
}

// MARK: - Coding

private struct NodTypeKey: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }

  static let type = NodTypeKey(stringValue: "type")
  static let seq = NodTypeKey(stringValue: "seq")
  static let at = NodTypeKey(stringValue: "at")
  static let v = NodTypeKey(stringValue: "v")
}

extension NodEvent: Codable {
  public var type: String {
    switch self {
    case .sessionStarted: return "sessionStarted"
    case .turnStarted: return "turnStarted"
    case .userMessage: return "userMessage"
    case .assistantText: return "assistantText"
    case .toolCall: return "toolCall"
    case .toolResult: return "toolResult"
    case .hunkStaged: return "hunkStaged"
    case .hunkResolved: return "hunkResolved"
    case .permissionAsked: return "permissionAsked"
    case .permissionResolved: return "permissionResolved"
    case .goalCheck: return "goalCheck"
    case .turnEnded: return "turnEnded"
    case .usage: return "usage"
    case .planProposed: return "planProposed"
    case .mailDraft: return "mailDraft"
    case .compacted: return "compacted"
    case .activity: return "activity"
    case .failure: return "failure"
    case .unknown(let type): return type
    }
  }

  public init(from decoder: Decoder) throws {
    let type = try decoder.container(keyedBy: NodTypeKey.self).decode(String.self, forKey: .type)
    switch type {
    case "sessionStarted": self = .sessionStarted(try .init(from: decoder))
    case "turnStarted": self = .turnStarted(try .init(from: decoder))
    case "userMessage": self = .userMessage(try .init(from: decoder))
    case "assistantText": self = .assistantText(try .init(from: decoder))
    case "toolCall": self = .toolCall(try .init(from: decoder))
    case "toolResult": self = .toolResult(try .init(from: decoder))
    case "hunkStaged": self = .hunkStaged(try .init(from: decoder))
    case "hunkResolved": self = .hunkResolved(try .init(from: decoder))
    case "permissionAsked": self = .permissionAsked(try .init(from: decoder))
    case "permissionResolved": self = .permissionResolved(try .init(from: decoder))
    case "goalCheck": self = .goalCheck(try .init(from: decoder))
    case "turnEnded": self = .turnEnded(try .init(from: decoder))
    case "usage": self = .usage(try .init(from: decoder))
    case "planProposed": self = .planProposed(try .init(from: decoder))
    case "mailDraft": self = .mailDraft(try .init(from: decoder))
    case "compacted": self = .compacted(try .init(from: decoder))
    case "activity": self = .activity(try .init(from: decoder))
    case "failure": self = .failure(try .init(from: decoder))
    default: self = .unknown(type)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: NodTypeKey.self)
    try container.encode(type, forKey: .type)
    switch self {
    case .sessionStarted(let payload): try payload.encode(to: encoder)
    case .turnStarted(let payload): try payload.encode(to: encoder)
    case .userMessage(let payload): try payload.encode(to: encoder)
    case .assistantText(let payload): try payload.encode(to: encoder)
    case .toolCall(let payload): try payload.encode(to: encoder)
    case .toolResult(let payload): try payload.encode(to: encoder)
    case .hunkStaged(let payload): try payload.encode(to: encoder)
    case .hunkResolved(let payload): try payload.encode(to: encoder)
    case .permissionAsked(let payload): try payload.encode(to: encoder)
    case .permissionResolved(let payload): try payload.encode(to: encoder)
    case .goalCheck(let payload): try payload.encode(to: encoder)
    case .turnEnded(let payload): try payload.encode(to: encoder)
    case .usage(let payload): try payload.encode(to: encoder)
    case .planProposed(let payload): try payload.encode(to: encoder)
    case .mailDraft(let payload): try payload.encode(to: encoder)
    case .compacted(let payload): try payload.encode(to: encoder)
    case .activity(let payload): try payload.encode(to: encoder)
    case .failure(let payload): try payload.encode(to: encoder)
    case .unknown: break
    }
  }
}

extension NodEventRecord: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: NodTypeKey.self)
    seq = try container.decode(Int.self, forKey: .seq)
    at = try container.decode(Date.self, forKey: .at)
    event = try NodEvent(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: NodTypeKey.self)
    try container.encode(NodProtocol.version, forKey: .v)
    try container.encode(seq, forKey: .seq)
    try container.encode(at, forKey: .at)
    try event.encode(to: encoder)
  }
}

extension NodCommand: Codable {
  public var type: String {
    switch self {
    case .send: return "send"
    case .stop: return "stop"
    case .resolveHunk: return "resolveHunk"
    case .resolvePermission: return "resolvePermission"
    case .runPlan: return "runPlan"
    case .fork: return "fork"
    case .sendDraft: return "sendDraft"
    case .compact: return "compact"
    case .setModel: return "setModel"
    case .markGoalDone: return "markGoalDone"
    }
  }

  public init(from decoder: Decoder) throws {
    let type = try decoder.container(keyedBy: NodTypeKey.self).decode(String.self, forKey: .type)
    switch type {
    case "send": self = .send(try .init(from: decoder))
    case "stop": self = .stop
    case "resolveHunk": self = .resolveHunk(try .init(from: decoder))
    case "resolvePermission": self = .resolvePermission(try .init(from: decoder))
    case "runPlan": self = .runPlan(try .init(from: decoder))
    case "fork": self = .fork(try .init(from: decoder))
    case "sendDraft": self = .sendDraft(try .init(from: decoder))
    case "compact": self = .compact
    case "setModel": self = .setModel(try .init(from: decoder))
    case "markGoalDone": self = .markGoalDone
    default:
      throw DecodingError.dataCorruptedError(
        forKey: NodTypeKey.type, in: try decoder.container(keyedBy: NodTypeKey.self),
        debugDescription: "unknown Nod command \(type)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: NodTypeKey.self)
    try container.encode(type, forKey: .type)
    switch self {
    case .send(let payload): try payload.encode(to: encoder)
    case .resolveHunk(let payload): try payload.encode(to: encoder)
    case .resolvePermission(let payload): try payload.encode(to: encoder)
    case .runPlan(let payload): try payload.encode(to: encoder)
    case .fork(let payload): try payload.encode(to: encoder)
    case .sendDraft(let payload): try payload.encode(to: encoder)
    case .setModel(let payload): try payload.encode(to: encoder)
    case .stop, .compact, .markGoalDone: break
    }
  }
}

extension NodProtocol {
  /// ISO-8601 dates, sorted keys — the encoding both sides agree on.
  public static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  public static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  /// Parses `events.jsonl`, skipping lines that are not records — a torn final line from a
  /// runtime killed mid-write is expected, not an error.
  public static func records(fromJSONLines data: Data) -> [NodEventRecord] {
    let decoder = makeDecoder()
    return data.split(separator: UInt8(ascii: "\n")).compactMap {
      try? decoder.decode(NodEventRecord.self, from: Data($0))
    }
  }
}
