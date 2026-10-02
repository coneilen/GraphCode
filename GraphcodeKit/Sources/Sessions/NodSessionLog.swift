import Foundation

/// Every reading graphcode takes of a Nod session, from the event log the runtime writes
/// (`$NOD_STATE/events.jsonl`) through the one fold, `NodSessionFold`.
///
/// Presence is `.reported`, not `.scanned` like Copilot's: these events are Nod telling
/// graphcode what it is doing, not a log graphcode reads over a CLI's shoulder.
///
/// Local only. A remote project's state directory is on the other machine; its readings
/// are `nil` or `.unknown` until Nod runs remotely at all.
public enum NodSessionLog {
  /// Big enough to hold the current run of a long session: the fold needs the
  /// `sessionStarted` that opened it, and hunks and tool output make records large.
  static let tailBytes = 1024 * 1024

  public static func records(forNodeID nodeID: UUID) -> [NodEventRecord] {
    records(inLogAt: NodRuntimeLocator.eventsFile(forNodeID: nodeID))
  }

  static func records(inLogAt url: URL) -> [NodEventRecord] {
    let decoder = NodProtocol.makeDecoder()
    return SummaryBeatBuilder.tailLines(of: url, bytes: tailBytes).compactMap {
      try? decoder.decode(NodEventRecord.self, from: $0)
    }
  }

  public static func fold(forNodeID nodeID: UUID) -> NodSessionFold {
    NodSessionFold(records: records(forNodeID: nodeID))
  }

  static func isRemote(_ projectPath: String?) -> Bool {
    projectPath.map { RemoteProjectLocation.parse(projectPath: $0) != nil } ?? false
  }

  public static func presence(of node: LoopNode, projectPath: String? = nil) async
    -> PresenceReading
  {
    guard !isRemote(projectPath) else { return .unknown }
    guard ZmxLocator.isInstalled else { return .absent }
    switch await ZmxSessionLauncher.sessionTaskState(node) {
    case .unknown: return .unknown
    case .absent: return .absent
    case .exited(let code):
      return PresenceReading(presence: .idle, confidence: .scanned, exitCode: code)
    case .alive: break
    }
    let fold = fold(forNodeID: node.id)
    bankConversation(of: fold, forNodeID: node.id)
    guard let presence = fold.presence else {
      // Alive with no `sessionStarted` yet: the runtime is still coming up.
      return PresenceReading(presence: .idle, confidence: .heuristic)
    }
    return PresenceReading(presence: presence, confidence: .reported)
  }

  /// Banks the run's conversation id where every resumer already looks
  /// (`SessionIDStore`), the job a `SessionStart` hook does for Claude Code. Banked only
  /// from a live session, so a loop whose session was killed for good — which clears the
  /// store — is not handed its old conversation back by the log it left behind.
  static func bankConversation(of fold: NodSessionFold, forNodeID nodeID: UUID) {
    guard let id = fold.session?.conversationID, !id.isEmpty,
      SessionIDStore.load(forNodeID: nodeID) != id
    else { return }
    SessionIDStore.save(id, forNodeID: nodeID)
  }

  public static func activity(of node: LoopNode, projectPath: String? = nil) async -> String? {
    guard !isRemote(projectPath), ZmxLocator.isInstalled,
      await ZmxSessionLauncher.sessionExists(node)
    else { return nil }
    return fold(forNodeID: node.id).activityLine.flatMap(ZmxSessionLauncher.condensedActivity)
  }

  public static func usage(of node: LoopNode, projectPath: String? = nil) async -> UsageSample? {
    guard !isRemote(projectPath) else { return nil }
    return fold(forNodeID: node.id).usageSample
  }

  public static func verdict(of node: LoopNode) -> GoalVerdict? {
    fold(forNodeID: node.id).goalVerdict
  }

  public static func summary(of node: LoopNode, projectPath: String? = nil) async
    -> SummaryReading?
  {
    guard !isRemote(projectPath) else { return nil }
    let log = NodRuntimeLocator.eventsFile(forNodeID: node.id)
    guard await TranscriptFreshness.shared.hasChanged(log, forNode: node.id) else { return nil }
    let reading = reading(of: records(inLogAt: log), metricSamples: node.metricHistory)
    return reading.isEmpty ? nil : reading
  }

  /// Turns open passes, the finished assistant messages are the narration, tool calls
  /// the evidence — the same beats a CLI's transcript yields, without parsing prose.
  static func reading(of records: [NodEventRecord], metricSamples: [MetricSample])
    -> SummaryReading
  {
    var builder = SummaryBeatBuilder()
    var drafts: [String: String] = [:]
    for record in records {
      switch record.event {
      case .turnStarted:
        builder.noteUserTurn(at: record.at)
      case .assistantText(let text):
        drafts[text.messageID, default: ""] += text.delta
        if text.final, let message = drafts.removeValue(forKey: text.messageID) {
          builder.noteNarration(message, at: record.at)
        }
      case .toolCall(let call):
        builder.noteTool(call.title, at: record.at)
      case .turnEnded:
        builder.noteTurnEnd()
      default:
        continue
      }
    }
    return SummaryBeatBuilder.reading(
      from: builder.beats(), turns: builder.userTurns(), metricSamples: metricSamples,
      closing: builder.closingAnswer())
  }
}

extension NodSessionLog {
  /// A `.message` edge, a heartbeat or `graphcode node send`, as a queued `send` — the
  /// default, because a message from elsewhere in the graph must never redirect a turn
  /// already running. `nil` when the socket is not there to ask, which leaves the caller
  /// to type the line into the PTY instead: the runtime reads a plain line as the same
  /// queued send, so a runtime still starting up loses nothing.
  static func deliver(_ text: String, to node: LoopNode) async -> Bool? {
    switch await NodControlClient.send(.send(.init(text: text)), toNodeID: node.id) {
    case .success: return true
    case .failure(.unreachable): return nil
    case .failure: return false
    }
  }
}
