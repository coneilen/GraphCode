import Foundation
import GraphcodeKit

extension NodCardDetail {
  init?(_ state: NodCardState) {
    guard state.goalProgress != nil || state.pendingAsk != nil else { return nil }
    goalMet = state.goalProgress?.met
    goalTotal = state.goalProgress?.total
    ask = state.pendingAsk.map {
      Ask(
        askID: $0.askID, kind: $0.kind, subject: $0.subject,
        answerableFromCard: $0.answerableFromCard)
    }
  }
}

/// What `NodCardWiring` is set to at launch: the card state folded from each Nod loop's
/// `events.jsonl` (`NodSessionFold.cardState`, the fold the daemon's readings come from),
/// and Allow once over its `control.sock`.
///
/// Cards redraw on every graph broadcast, so the fold is cached per loop and redone only
/// when the log's size or modification date moves.
@MainActor
final class NodLiveCardState: NodCardStateProviding, NodPermissionAnswering {
  private struct Cached {
    var size: UInt64
    var modified: Date?
    var detail: NodCardDetail?
  }

  private let eventsFile: (UUID) -> URL
  private let fold: (UUID) -> NodCardState
  private let resolve: @Sendable (NodCommand, UUID) async -> Void
  private var cache: [UUID: Cached] = [:]

  init(
    eventsFile: @escaping (UUID) -> URL = NodRuntimeLocator.eventsFile(forNodeID:),
    fold: @escaping (UUID) -> NodCardState = { NodSessionLog.fold(forNodeID: $0).cardState },
    resolve: @escaping @Sendable (NodCommand, UUID) async -> Void = { command, nodeID in
      _ = await NodControlClient.send(command, toNodeID: nodeID)
    }
  ) {
    self.eventsFile = eventsFile
    self.fold = fold
    self.resolve = resolve
  }

  func cardDetail(for node: LoopNode) -> NodCardDetail? {
    let url = eventsFile(node.id)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      cache[node.id] = nil
      return nil
    }
    let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    let modified = attributes[.modificationDate] as? Date
    if let cached = cache[node.id], cached.size == size, cached.modified == modified {
      return cached.detail
    }
    let detail = NodCardDetail(fold(node.id))
    cache[node.id] = Cached(size: size, modified: modified, detail: detail)
    return detail
  }

  func allowOnce(nodeID: UUID, askID: String) {
    let resolve = resolve
    Task { await resolve(.resolvePermission(.init(askID: askID, decision: .allowOnce)), nodeID) }
  }
}
