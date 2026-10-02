import Foundation

/// The composer's graph verbs — the slash commands that act on other loops rather than on
/// this conversation — parsed into the `GraphCommand`s they send.
public enum NodGraphVerb: Equatable, Sendable {
  /// `/handoff [@Loop] [brief…]`: pass a brief downstream, or to the named loop.
  case handoff(target: String?, brief: String)
  /// `/ask @Loop <message…>`: message a sibling.
  case ask(target: String, text: String)
  /// `/promote goal <done when…>` · `/promote turn [writes]` · `/promote timed <prompt…>`.
  case promote(SketchPromotion)

  public enum ParseError: Error, Equatable, Sendable {
    case notAGraphVerb
    case usage(String)
  }

  public static let handoffUsage = "/handoff [@Loop] <brief>"
  public static let askUsage = "/ask @Loop <message>"
  public static let promoteUsage = "/promote goal <done when…> | turn [writes] | timed <prompt>"

  public static func parse(_ line: String) -> Result<NodGraphVerb, ParseError> {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    var words = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard let verb = words.first else { return .failure(.notAGraphVerb) }
    let rest = words.count > 1 ? String(words.removeLast()) : ""
    switch verb {
    case "/handoff":
      let (target, brief) = splitMention(rest)
      return .success(.handoff(target: target, brief: brief))
    case "/ask":
      let (target, text) = splitMention(rest)
      guard let target, !text.isEmpty else { return .failure(.usage(askUsage)) }
      return .success(.ask(target: target, text: text))
    case "/promote":
      let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
      let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
      switch parts.first?.lowercased() {
      case "goal" where !argument.isEmpty:
        return .success(.promote(.goal(GoalSpec(summary: argument))))
      case "turn":
        return .success(.promote(.turn(pausesBeforeWritesOnly: argument.lowercased() == "writes")))
      case "timed" where !argument.isEmpty, "time" where !argument.isEmpty:
        return .success(.promote(.timed(triggerPrompt: argument)))
      default:
        return .failure(.usage(promoteUsage))
      }
    default:
      return .failure(.notAGraphVerb)
    }
  }

  private static func splitMention(_ text: String) -> (String?, String) {
    guard text.hasPrefix("@") else { return (nil, text) }
    let parts = text.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
    let body = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    return (parts.first, body)
  }

  public enum ResolveError: Error, Equatable, Sendable {
    case unknownLoop(String)
    case noDownstream
    case emptyBrief
    case notASketch
  }

  /// The commands this verb sends from `nodeID`. Sent by a human from Nod's composer, so
  /// they are attributed to the loop but not gated by `messagesOtherLoops`, which governs
  /// what Nod does on its own.
  public func commands(from nodeID: UUID, in graph: LoopGraph) -> Result<
    [GraphCommand], ResolveError
  > {
    switch self {
    case .handoff(let target, let brief):
      let targets: [LoopNode]
      if let target {
        guard let node = NodGraphVerb.node(named: target, in: graph, excluding: nodeID) else {
          return .failure(.unknownLoop(target))
        }
        targets = [node]
      } else {
        targets = NodGraphVerb.downstream(of: nodeID, in: graph)
        guard !targets.isEmpty else { return .failure(.noDownstream) }
      }
      guard !brief.isEmpty else { return .failure(.emptyBrief) }
      return .success(NodGraphVerb.handoffCommands(from: nodeID, to: targets, brief: brief))
    case .ask(let target, let text):
      guard let node = NodGraphVerb.node(named: target, in: graph, excluding: nodeID) else {
        return .failure(.unknownLoop(target))
      }
      return .success([.messageNode(node.id, text: text, from: nodeID, followUp: true)])
    case .promote(let promotion):
      guard let node = graph.nodes[id: nodeID],
        node.loopType == .sketch || node.loopType.retypeTarget == promotion.targetType
      else { return .failure(.notASketch) }
      return .success([.promoteNode(nodeID, promotion: promotion, promotedBy: nil)])
    }
  }

  /// A handoff brief starts with this word so a receiving Nod renders it as a handoff and a
  /// CLI reads it as one.
  public static let handoffPrefix = "Handoff: "

  static func handoffCommands(from nodeID: UUID, to targets: [LoopNode], brief: String)
    -> [GraphCommand]
  {
    targets.map {
      .messageNode($0.id, text: handoffPrefix + brief, from: nodeID, followUp: true)
    }
  }

  static func downstream(of nodeID: UUID, in graph: LoopGraph) -> [LoopNode] {
    graph.edges.filter { $0.from == nodeID && $0.kind == .handoff }
      .compactMap { graph.nodes[id: $0.to] }
  }

  /// Case-insensitive, exact before prefix — `@bill` finds Billing UI when nothing else
  /// starts that way.
  static func node(named name: String, in graph: LoopGraph, excluding nodeID: UUID)
    -> LoopNode?
  {
    let wanted = name.lowercased()
    let candidates = graph.nodes.filter { $0.id != nodeID }
    if let exact = candidates.first(where: { $0.title.lowercased() == wanted }) { return exact }
    let prefixed = candidates.filter { $0.title.lowercased().hasPrefix(wanted) }
    return prefixed.count == 1 ? prefixed.first : nil
  }
}

// MARK: - Inbound

/// Mail or a handoff that arrived in a Nod conversation from another loop.
///
/// The daemon types every message as `[graphcode] <Sender>: <text>` (and a bare handoff as
/// `[graphcode] <Sender> finished.`), and the runtime echoes it as a `userMessage`. This is
/// what turns that back into who sent what.
public struct NodInboundMail: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case mail
    case handoff
  }

  public var messageID: String
  public var kind: Kind
  public var senderTitle: String
  public var sender: NodGraphContext.Neighbour?
  public var body: String

  public var isQuestion: Bool { body.contains("?") }

  static let prefix = "[graphcode] "

  /// Nil for a message a human typed, or a `[graphcode]` notice no loop sent.
  public static func classify(
    _ message: NodEvent.UserMessage, nodeID: UUID, in graph: LoopGraph
  ) -> NodInboundMail? {
    var senderTitle: String
    var body: String
    var senderNode: LoopNode?
    if let fromNodeID = message.fromNodeID {
      senderNode = graph.nodes[id: fromNodeID]
      senderTitle = senderNode?.title ?? ""
      body = message.text
      if message.text.hasPrefix(prefix) {
        let parsed = parse(message.text, in: graph)
        body = parsed?.body ?? body
      }
    } else {
      guard let parsed = parse(message.text, in: graph) else { return nil }
      senderNode = parsed.node
      senderTitle = parsed.title
      body = parsed.body
    }
    let isHandoff: Bool
    if body.hasPrefix(NodGraphVerb.handoffPrefix) {
      body.removeFirst(NodGraphVerb.handoffPrefix.count)
      isHandoff = true
    } else if let senderNode {
      isHandoff = graph.edges.contains {
        $0.from == senderNode.id && $0.to == nodeID && $0.kind == .handoff
      }
    } else {
      isHandoff = false
    }
    return NodInboundMail(
      messageID: message.id, kind: isHandoff ? .handoff : .mail, senderTitle: senderTitle,
      sender: senderNode.map(NodGraphContext.Neighbour.init), body: body)
  }

  /// Titles may contain `: `, so the longest title that matches wins.
  private static func parse(_ text: String, in graph: LoopGraph)
    -> (title: String, node: LoopNode?, body: String)?
  {
    guard text.hasPrefix(prefix) else { return nil }
    let rest = String(text.dropFirst(prefix.count))
    let byLength = graph.nodesAtAnyDepth.sorted { $0.title.count > $1.title.count }
    for node in byLength {
      if rest.hasPrefix(node.title + ": ") {
        return (node.title, node, String(rest.dropFirst(node.title.count + 2)))
      }
      if rest == node.title + " finished." {
        return (node.title, node, "")
      }
    }
    return nil
  }

  /// The reply Nod drafted for this message, if any — the newest one wins.
  public func draft(in events: [NodEvent]) -> NodEvent.MailDraft? {
    events.reversed().lazy.compactMap { event -> NodEvent.MailDraft? in
      guard case .mailDraft(let draft) = event, draft.inReplyTo == messageID else { return nil }
      return draft
    }.first
  }

  /// "Answer myself": the human's reply, sent as this loop without Nod.
  public func answerCommand(from nodeID: UUID, text: String) -> GraphCommand? {
    guard let sender else { return nil }
    return .messageNode(sender.id, text: text, from: nodeID, followUp: true)
  }
}

// MARK: - Handoff offer

/// "Goal holds — hand off to Release notes with a summary of what changed?"
public struct NodHandoffOffer: Equatable, Sendable {
  public var nodeID: UUID
  public var targets: [NodGraphContext.Neighbour]
  /// The evaluator's evidence, one clause per item: `4 of 4 paid routes capped`.
  public var evidence: [String]
  public var suggestedBrief: String

  /// Offered only when the goal holds and something is downstream to receive it.
  public static func make(
    check: NodEvent.GoalCheck, nodeID: UUID, in graph: LoopGraph, summaries: [String] = []
  ) -> NodHandoffOffer? {
    guard check.met else { return nil }
    let targets = NodGraphVerb.downstream(of: nodeID, in: graph)
    guard !targets.isEmpty else { return nil }
    let evidence = check.clauses.map { $0.evidence ?? $0.text }
    let brief = summaries.filter { !$0.isEmpty }.joined(separator: "\n")
    return NodHandoffOffer(
      nodeID: nodeID, targets: targets.map(NodGraphContext.Neighbour.init),
      evidence: evidence,
      suggestedBrief: brief.isEmpty ? check.clauses.map(\.text).joined(separator: "\n") : brief)
  }

  /// Hands the brief to each downstream loop, then reports this loop's goal met with the
  /// brief as its result, which fires its handoff edges.
  public func commands(brief: String) -> [GraphCommand] {
    let text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
    let targets = targets.map { LoopNode(id: $0.id, title: $0.title) }
    return NodGraphVerb.handoffCommands(from: nodeID, to: targets, brief: text)
      + [.completeNode(nodeID, result: text.split(separator: "\n").first.map(String.init), from: nil)]
  }
}
