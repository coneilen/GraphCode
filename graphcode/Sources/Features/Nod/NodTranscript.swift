import Foundation
import GraphcodeKit

/// Nod's event log folded into what the chat pane draws: turns, each holding the prompt
/// that started it and the work cards it produced, plus the state that sits outside any
/// one turn — the latest goal check, usage, the queued messages, the live activity line
/// and whichever failure is showing.
///
/// Pure and replayable: the pane rebuilds it from `events.jsonl` on open, and applies the
/// same records one at a time as the tail delivers them, so a reopened loop and a live one
/// draw the same thing.
struct NodTranscript: Equatable {
  struct Session: Equatable {
    var engine: NodEngine
    var model: String
    var conversationID: String
  }

  struct Turn: Equatable, Identifiable {
    var number: Int
    var origin: NodTurnOrigin
    var startedAt: Date
    var prompt: NodEvent.UserMessage?
    var items: [Item] = []
    var ended: NodEvent.TurnEnded?
    var endedAt: Date?
    /// Closed by the next turn starting without ever writing `turnEnded` — the runtime was
    /// stopped or killed mid-turn.
    var wasInterrupted = false
    /// Folded into a "Compacted N turns" divider; the originals stay readable.
    var isCompacted = false

    var id: Int { number }
    var isRunning: Bool { ended == nil && !wasInterrupted }
  }

  enum Item: Equatable, Identifiable {
    case text(Message)
    /// A note steered into the running turn, picked up at the next tool boundary.
    case steer(NodEvent.UserMessage)
    case tool(ToolCard)
    case hunk(HunkCard)
    case permission(PermissionCard)
    case goalCheck(NodEvent.GoalCheck)
    case plan(NodEvent.PlanProposed)
    case mailDraft(NodEvent.MailDraft)

    var id: String {
      switch self {
      case .text(let message): return "text:\(message.id)"
      case .steer(let message): return "steer:\(message.id)"
      case .tool(let card): return "tool:\(card.call.callID)"
      case .hunk(let card): return "hunk:\(card.staged.hunkID)"
      case .permission(let card): return "ask:\(card.ask.askID)"
      case .goalCheck(let check): return "goal:\(check.turn)"
      case .plan(let plan): return "plan:\(plan.planID)"
      case .mailDraft(let draft): return "draft:\(draft.draftID)"
      }
    }
  }

  struct Message: Equatable {
    var id: String
    var text: String
    var isFinal: Bool
  }

  struct ToolCard: Equatable {
    var call: NodEvent.ToolCall
    var result: NodEvent.ToolResult?

    var status: NodToolStatus { result?.status ?? .running }
  }

  struct HunkCard: Equatable {
    var staged: NodEvent.HunkStaged
    var resolution: NodEvent.HunkResolved?

    var decision: NodHunkDecision? {
      resolution?.decision ?? (staged.autoAccepted ? .accept : nil)
    }
  }

  struct PermissionCard: Equatable {
    var ask: NodEvent.PermissionAsked
    var decision: NodPermissionDecision?
  }

  private(set) var session: Session?
  private(set) var turns: [Turn] = []
  /// Accepted with `delivery: queue` while a turn was running; each one starts a turn of
  /// its own once the current one ends.
  private(set) var queued: [NodEvent.UserMessage] = []
  private(set) var lastGoalCheck: NodEvent.GoalCheck?
  /// How many goal checks have run, for the header's "checked 2×".
  private(set) var goalCheckCount = 0
  private(set) var usage: NodEvent.Usage?
  /// Dollars or premium requests summed across every `usage` record — each one reports
  /// what a single model call cost, not a running total.
  private(set) var totalCostUSD: Double = 0
  private(set) var totalPremiumRequests = 0
  private(set) var activity: String?
  private(set) var failure: NodEvent.Failure?
  private(set) var lastSeq = 0

  var currentTurn: Turn? { turns.last.flatMap { $0.isRunning ? $0 : nil } }
  var isRunning: Bool { currentTurn != nil }

  /// The permission asks still waiting on a human — the loop is in Needs you while this
  /// is non-empty.
  var openAsks: [NodEvent.PermissionAsked] {
    turns.flatMap(\.items).compactMap {
      if case .permission(let card) = $0, card.decision == nil { return card.ask }
      return nil
    }
  }

  init() {}

  init(replaying records: [NodEventRecord]) {
    for record in records { apply(record) }
  }

  mutating func apply(_ record: NodEventRecord) {
    // `seq` restarts at 1 when a resumed runtime opens a new run, which it announces with
    // `sessionStarted`; anything else at or below the last seen seq is a replay.
    if case .sessionStarted = record.event {
    } else if record.seq <= lastSeq {
      return
    }
    lastSeq = record.seq

    switch record.event {
    case .sessionStarted(let started):
      closeRunningTurn(at: record.at)
      session = Session(
        engine: started.engine, model: started.model, conversationID: started.conversationID)
      if failure?.kind == .signInExpired || failure?.kind == .engineError { failure = nil }

    case .turnStarted(let started):
      closeRunningTurn(at: record.at)
      var turn = Turn(number: started.turn, origin: started.origin, startedAt: record.at)
      if started.origin.carriesPrompt, !queued.isEmpty {
        turn.prompt = queued.removeFirst()
      }
      turns.append(turn)
      if failure?.kind == .spendCap || failure?.kind == .permissionUnavailable { failure = nil }

    case .userMessage(let message):
      receive(message)

    case .assistantText(let text):
      appendText(text)

    case .toolCall(let call):
      append(.tool(ToolCard(call: call)), toTurn: call.turn)

    case .toolResult(let result):
      updateItems { item in
        guard case .tool(var card) = item, card.call.callID == result.callID else { return false }
        card.result = result
        item = .tool(card)
        return true
      }

    case .hunkStaged(let staged):
      append(.hunk(HunkCard(staged: staged)), toTurn: staged.turn)

    case .hunkResolved(let resolved):
      updateItems { item in
        guard case .hunk(var card) = item, card.staged.hunkID == resolved.hunkID else {
          return false
        }
        card.resolution = resolved
        item = .hunk(card)
        return true
      }

    case .permissionAsked(let ask):
      let turn = currentTurn?.number ?? turns.last?.number ?? 0
      append(.permission(PermissionCard(ask: ask)), toTurn: turn)

    case .permissionResolved(let resolved):
      updateItems { item in
        guard case .permission(var card) = item, card.ask.askID == resolved.askID else {
          return false
        }
        card.decision = resolved.decision
        item = .permission(card)
        return true
      }

    case .goalCheck(let check):
      lastGoalCheck = check
      goalCheckCount += 1
      append(.goalCheck(check), toTurn: check.turn)

    case .turnEnded(let ended):
      guard let index = turns.lastIndex(where: { $0.number == ended.turn }) else { return }
      turns[index].ended = ended
      turns[index].endedAt = record.at
      activity = nil

    case .usage(let usage):
      self.usage = usage
      totalCostUSD += usage.costUSD ?? 0
      totalPremiumRequests += usage.premiumRequests ?? 0

    case .planProposed(let plan):
      append(.plan(plan), toTurn: currentTurn?.number ?? turns.last?.number ?? 0)

    case .mailDraft(let draft):
      append(.mailDraft(draft), toTurn: currentTurn?.number ?? turns.last?.number ?? 0)

    case .compacted(let compacted):
      for index in turns.indices
      where (compacted.fromTurn...compacted.throughTurn).contains(turns[index].number) {
        turns[index].isCompacted = true
      }
      if failure?.kind == .contextFull { failure = nil }

    case .activity(let activity):
      self.activity = activity.line

    case .failure(let failure):
      self.failure = failure

    case .unknown:
      break
    }
  }

  /// A queued message belongs to the turn it will start; a steer belongs to the turn it
  /// lands in. A message accepted while idle is the prompt of the turn about to start —
  /// whichever of the two records the runtime writes first.
  private mutating func receive(_ message: NodEvent.UserMessage) {
    if message.delivery == .steer, let index = runningTurnIndex {
      turns[index].items.append(.steer(message))
      return
    }
    if let index = runningTurnIndex, turns[index].prompt == nil, turns[index].items.isEmpty,
      turns[index].origin.carriesPrompt
    {
      turns[index].prompt = message
      return
    }
    queued.append(message)
  }

  private mutating func appendText(_ text: NodEvent.AssistantText) {
    guard let turnIndex = index(ofTurn: text.turn) else { return }
    if let itemIndex = turns[turnIndex].items.lastIndex(where: {
      if case .text(let message) = $0 { return message.id == text.messageID }
      return false
    }), case .text(var message) = turns[turnIndex].items[itemIndex] {
      message.text += text.delta
      message.isFinal = message.isFinal || text.final
      turns[turnIndex].items[itemIndex] = .text(message)
    } else {
      turns[turnIndex].items.append(
        .text(Message(id: text.messageID, text: text.delta, isFinal: text.final)))
    }
  }

  private mutating func append(_ item: Item, toTurn number: Int) {
    guard let index = index(ofTurn: number) else { return }
    turns[index].items.append(item)
  }

  /// The turn a record names, or — for one that names a turn this log never started, as a
  /// runtime resumed mid-turn would — a stand-in so its cards are not dropped.
  private mutating func index(ofTurn number: Int) -> Int? {
    if let index = turns.lastIndex(where: { $0.number == number }) { return index }
    turns.append(Turn(number: number, origin: .user, startedAt: .distantPast))
    return turns.count - 1
  }

  private var runningTurnIndex: Int? {
    guard let last = turns.indices.last, turns[last].isRunning else { return nil }
    return last
  }

  /// A turn that never wrote `turnEnded` — the runtime was killed mid-turn — is closed by
  /// the next one starting, so only one turn ever reads as running.
  private mutating func closeRunningTurn(at date: Date) {
    guard let index = runningTurnIndex else { return }
    turns[index].wasInterrupted = true
    turns[index].endedAt = date
  }

  /// Newest first: a result or resolution is for a card near the end of the log.
  private mutating func updateItems(_ update: (inout Item) -> Bool) {
    for turnIndex in turns.indices.reversed() {
      for itemIndex in turns[turnIndex].items.indices.reversed()
      where update(&turns[turnIndex].items[itemIndex]) {
        return
      }
    }
  }
}

extension NodTurnOrigin {
  /// Whether a turn of this origin starts from a message the human (or a peer) sent,
  /// rather than from the runtime itself.
  var carriesPrompt: Bool {
    switch self {
    case .user, .queue, .handoff, .mail: return true
    case .steer, .timer, .goalCheck: return false
    }
  }
}
