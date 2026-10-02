import Foundation
import GraphcodeKit

/// What a Nod loop's card knows beyond what every card knows: how many goal clauses the
/// evaluator last found met, and the permission ask nobody has answered yet.
///
/// The live line is not here. It is `LoopNode.activity` like every backend's, which Nod
/// fills exactly from its SDK events ("Running swift test · turn 4", or "asks to run …"
/// while an ask is open).
struct NodCardDetail: Equatable {
  struct Ask: Equatable {
    var askID: String
    var kind: NodPermissionKind
    var subject: String
    /// Allowlisted or read-only asks may be answered from the card; anything else opens
    /// the chat, so the person sees what led to it.
    var answerableFromCard: Bool
  }

  var goalMet: Int?
  var goalTotal: Int?
  var ask: Ask?
}

/// Where cards get `NodCardDetail` from. The daemon folds Nod's event log into node state
/// alongside presence; until that field reaches `LoopNode`, the provider has nothing to
/// say and Nod cards draw like any other.
@MainActor
protocol NodCardStateProviding {
  func cardDetail(for node: LoopNode) -> NodCardDetail?
}

/// Answers a permission ask from the card. Live, this sends `resolvePermission` over the
/// loop's control socket.
@MainActor
protocol NodPermissionAnswering {
  func allowOnce(nodeID: UUID, askID: String)
}

@MainActor
enum NodCardWiring {
  static var provider: any NodCardStateProviding = Unavailable()
  static var answerer: any NodPermissionAnswering = Unavailable()

  private struct Unavailable: NodCardStateProviding, NodPermissionAnswering {
    func cardDetail(for node: LoopNode) -> NodCardDetail? { nil }
    func allowOnce(nodeID: UUID, askID: String) {}
  }

  static func detail(for node: LoopNode) -> NodCardDetail? {
    node.backend == .nod ? provider.cardDetail(for: node) : nil
  }
}

extension NodPermissionKind {
  /// The card's reason for sending an ask to the chat, e.g. "network · needs context".
  var cardLabel: String {
    switch self {
    case .shell: "shell"
    case .network: "network"
    case .editOutsideWorktree: "outside worktree"
    case .messageLoop: "message"
    case .mcpTool: "MCP tool"
    }
  }
}
