import Foundation
import GraphcodeKit

/// What the pane draws for one turn: its cards in order, except that a turn past
/// `foldThreshold` tool calls gathers them into one Work block (design 1b) so a long turn
/// stays one screen. Failed calls stay out of the fold — failures open on their own.
enum NodTurnBlock: Equatable, Identifiable {
  case item(NodTranscript.Item)
  case work(NodWorkSummary)

  var id: String {
    switch self {
    case .item(let item): return item.id
    case .work(let summary): return "work:\(summary.turn)"
    }
  }
}

struct NodWorkSummary: Equatable {
  var turn: Int
  var tools: [NodTranscript.ToolCard]

  /// `read 3 · searched 1 · edited 2 · ran 1`, in the order the verbs first appeared.
  var line: String {
    var counts: [(verb: String, count: Int)] = []
    for tool in tools {
      let verb = NodToolVerb(tool: tool.call.tool).pastTense
      if let index = counts.firstIndex(where: { $0.verb == verb }) {
        counts[index].count += 1
      } else {
        counts.append((verb, 1))
      }
    }
    return counts.map { "\($0.verb) \($0.count)" }.joined(separator: " · ")
  }

  var running: NodTranscript.ToolCard? { tools.last { $0.status == .running } }

  var durationMs: Int { tools.compactMap(\.result?.durationMs).reduce(0, +) }
}

enum NodToolVerb: Equatable {
  case read, search, edit, shell, other

  init(tool: String) {
    switch tool.lowercased() {
    case "read", "view", "ls", "notebookread": self = .read
    case "grep", "glob", "search", "websearch", "webfetch": self = .search
    case "edit", "write", "multiedit", "notebookedit", "apply_patch": self = .edit
    case "bash", "shell", "run": self = .shell
    default: self = .other
    }
  }

  var pastTense: String {
    switch self {
    case .read: return "read"
    case .search: return "searched"
    case .edit: return "edited"
    case .shell: return "ran"
    case .other: return "used"
    }
  }

  var label: String {
    switch self {
    case .read: return "Read"
    case .search: return "Search"
    case .edit: return "Edit"
    case .shell: return "Shell"
    case .other: return "Tool"
    }
  }
}

enum NodChatPresentation {
  static let foldThreshold = 5
  /// Design 8b: the warning shows from here; the runtime compacts on its own at 95%.
  static let contextWarningThreshold = 0.8

  static func blocks(for turn: NodTranscript.Turn) -> [NodTurnBlock] {
    let toolCount = turn.items.reduce(0) { count, item in
      if case .tool = item { return count + 1 }
      return count
    }
    guard toolCount > foldThreshold else { return turn.items.map(NodTurnBlock.item) }

    var blocks: [NodTurnBlock] = []
    var folded: [NodTranscript.ToolCard] = []
    var workIndex: Int?
    for item in turn.items {
      if case .tool(let card) = item, card.status != .error {
        folded.append(card)
        if workIndex == nil {
          workIndex = blocks.count
          blocks.append(.work(NodWorkSummary(turn: turn.number, tools: [])))
        }
      } else {
        blocks.append(.item(item))
      }
    }
    if let workIndex {
      blocks[workIndex] = .work(NodWorkSummary(turn: turn.number, tools: folded))
    }
    return blocks
  }

  enum Banner: Equatable {
    case signInExpired(String)
    case contextNearlyFull(percent: Int)
    case spendCap(String)
    case other(String)
  }

  /// One banner above the composer: a reported failure wins over the context warning,
  /// which `usage` alone drives.
  static func banner(for transcript: NodTranscript) -> Banner? {
    if let failure = transcript.failure {
      switch failure.kind {
      case .signInExpired: return .signInExpired(failure.message)
      case .spendCap: return .spendCap(failure.message)
      case .contextFull:
        return .contextNearlyFull(percent: percent(transcript.usage?.contextUsed ?? 0.95))
      case .permissionUnavailable, .engineError: return .other(failure.message)
      }
    }
    if let used = transcript.usage?.contextUsed, used >= contextWarningThreshold {
      return .contextNearlyFull(percent: percent(used))
    }
    return nil
  }

  private static func percent(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

  enum GoalVerdict: Equatable {
    case unchecked
    case notYet(checks: Int)
    case holds(metClauses: Int, of: Int)
  }

  static func goalVerdict(for transcript: NodTranscript) -> GoalVerdict {
    guard let check = transcript.lastGoalCheck else { return .unchecked }
    if check.met {
      return .holds(metClauses: check.clauses.filter(\.met).count, of: check.clauses.count)
    }
    return .notYet(checks: transcript.goalCheckCount)
  }

  static func verdictLabel(_ verdict: GoalVerdict) -> String {
    switch verdict {
    case .unchecked: return "not checked yet"
    case .notYet(let checks): return "not yet · checked \(checks)×"
    case .holds(let met, let total): return "✓ holds · \(met) / \(total)"
    }
  }

  /// What sits beside the model chip: dollars on the Claude engine, premium requests on
  /// Copilot, which bills those instead.
  static func costLabel(for transcript: NodTranscript) -> String? {
    if transcript.session?.engine == .copilotSDK || transcript.totalPremiumRequests > 0 {
      let count = transcript.totalPremiumRequests
      return count == 0 ? nil : "\(count) premium"
    }
    guard transcript.totalCostUSD > 0 else { return nil }
    return String(format: "$%.2f", transcript.totalCostUSD)
  }

  /// The catalog's name for a model this engine offers, else the family read off the id.
  static func modelLabel(_ model: String?, engine: NodEngine) -> String {
    guard let model else { return "Model" }
    return NodModelCatalog.model(id: model, engine: engine)?.displayName ?? modelLabel(model)
  }

  /// `Sonnet`, from `claude-sonnet-4-5` or `sonnet`; anything unrecognised is shown as is.
  static func modelLabel(_ model: String) -> String {
    let lower = model.lowercased()
    for family in ["opus", "sonnet", "haiku", "fable"] where lower.contains(family) {
      return family.prefix(1).uppercased() + family.dropFirst()
    }
    if lower.hasPrefix("gpt-") { return "GPT-" + model.dropFirst(4) }
    return model
  }

  static func duration(ms: Int) -> String {
    ms < 1000
      ? String(format: "%.1fs", Double(ms) / 1000) : "\(Int((Double(ms) / 1000).rounded()))s"
  }
}

// MARK: - Composer menus

struct NodSlashCommand: Equatable, Identifiable {
  enum Group: String, Equatable {
    case thisLoop = "This loop"
    case graph = "The graph"
  }

  var name: String
  var detail: String
  var group: Group

  var id: String { name }

  /// Design 2b: the CLIs' verbs where they overlap, graph verbs grouped apart because they
  /// act on other loops.
  static let all: [NodSlashCommand] = [
    .init(name: "plan", detail: "Draft steps before touching anything", group: .thisLoop),
    .init(name: "goal", detail: "Set or edit the done condition", group: .thisLoop),
    .init(name: "fork", detail: "Branch the conversation from here", group: .thisLoop),
    .init(name: "compact", detail: "Summarise older turns, keep the goal", group: .thisLoop),
    .init(name: "handoff", detail: "Pass a brief to a downstream loop", group: .graph),
    .init(name: "ask", detail: "Message a sibling loop", group: .graph),
    .init(name: "promote", detail: "Turn this Main loop into a type", group: .graph),
  ]

  static func matching(_ query: String) -> [NodSlashCommand] {
    let query = query.lowercased()
    guard !query.isEmpty else { return all }
    return all.filter { $0.name.hasPrefix(query) }
  }
}

/// Something `@` can name: a loop (message it while it runs, attach its transcript once it
/// has finished — design 2c) or a file.
struct NodMention: Equatable, Identifiable {
  enum Kind: Equatable {
    case loop(id: UUID, isRunning: Bool, detail: String)
    case file(path: String)
  }

  var title: String
  var kind: Kind

  var id: String {
    switch kind {
    case .loop(let id, _, _): return "loop:\(id)"
    case .file(let path): return "file:\(path)"
    }
  }

  /// The action ⏎ takes; ⇥ switches to the other one.
  var defaultActionLabel: String {
    switch kind {
    case .loop(_, let isRunning, _): return isRunning ? "message" : "attach"
    case .file: return "attach"
    }
  }

  static func matching(_ query: String, in candidates: [NodMention]) -> [NodMention] {
    let query = query.lowercased()
    guard !query.isEmpty else { return candidates }
    return candidates.filter { $0.title.lowercased().contains(query) }
  }
}

/// The trigger the caret sits in: `/com` at the start of the draft, or `@bi` anywhere
/// after whitespace.
enum NodComposerTrigger: Equatable {
  case slash(String)
  case mention(String)

  static func detect(in draft: String) -> NodComposerTrigger? {
    if draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") {
      return .slash(String(draft.dropFirst()))
    }
    guard let at = draft.lastIndex(of: "@") else { return nil }
    let before = draft[..<at]
    guard before.isEmpty || before.last?.isWhitespace == true else { return nil }
    let query = draft[draft.index(after: at)...]
    guard !query.contains(where: \.isWhitespace) else { return nil }
    return .mention(String(query))
  }
}
