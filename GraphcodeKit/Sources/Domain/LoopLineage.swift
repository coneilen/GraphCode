import Foundation

/// Where a loop came from when it was branched off another one rather than created fresh.
///
/// Not an edge: a fork runs beside its source, it does not wait on it or report to it, and
/// an unknown `EdgeKind` would fail an older app's whole graph decode. The canvas draws a
/// `.fork` lineage as a dotted "forked from" line instead.
public struct LoopLineage: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    /// A sibling started from one message of another loop's conversation, in its own
    /// worktree, so two approaches race.
    case fork
    /// A child of a composite made from a Nod plan.
    case compositeChild
  }

  public var kind: Kind
  public var sourceNodeID: UUID
  /// The `NodBrief` the loop starts from, if it has one.
  public var briefPath: String?

  public init(kind: Kind, sourceNodeID: UUID, briefPath: String? = nil) {
    self.kind = kind
    self.sourceNodeID = sourceNodeID
    self.briefPath = briefPath
  }
}

extension LoopGraph {
  /// Every fork in this graph as (source, fork) pairs whose source is still in the graph.
  public var forkLinks: [(from: UUID, to: UUID)] {
    nodes.compactMap { node in
      guard let lineage = node.lineage, lineage.kind == .fork,
        nodes[id: lineage.sourceNodeID] != nil
      else { return nil }
      return (lineage.sourceNodeID, node.id)
    }
  }
}
