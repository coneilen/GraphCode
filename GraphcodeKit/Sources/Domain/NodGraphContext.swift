import Foundation

/// The neighbours a Nod conversation can see, as the chat pane's context strip shows them:
/// who hands off to this loop, who it hands off to, and who it talks to beside the chain.
public struct NodGraphContext: Equatable, Sendable {
  public struct Neighbour: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var loopType: LoopType
    public var state: LoopState

    public init(_ node: LoopNode) {
      id = node.id
      title = node.title
      loopType = node.loopType
      state = node.displayState
    }
  }

  public var nodeID: UUID
  public var title: String
  /// Upstream: sources of handoff edges into this loop.
  public var from: [Neighbour]
  /// Downstream: targets of handoff edges out of this loop.
  public var to: [Neighbour]
  /// Message peers in either direction, and forks of or from this loop.
  public var beside: [Neighbour]

  /// A loop with no neighbours gets no strip at all.
  public var isEmpty: Bool { from.isEmpty && to.isEmpty && beside.isEmpty }

  public init(nodeID: UUID, in graph: LoopGraph) {
    self.nodeID = nodeID
    title = graph.nodes[id: nodeID]?.title ?? ""
    func neighbours(_ ids: [UUID]) -> [Neighbour] {
      var seen = Set<UUID>()
      return ids.compactMap { id in
        guard id != nodeID, seen.insert(id).inserted, let node = graph.nodes[id: id] else {
          return nil
        }
        return Neighbour(node)
      }
    }
    let sequencing = graph.edges.filter { $0.kind != .message }
    from = neighbours(sequencing.filter { $0.to == nodeID }.map(\.from))
    to = neighbours(sequencing.filter { $0.from == nodeID }.map(\.to))
    let peers = graph.edges.filter { $0.kind == .message }.compactMap { edge -> UUID? in
      edge.from == nodeID ? edge.to : edge.to == nodeID ? edge.from : nil
    }
    let forks = graph.forkLinks.compactMap { link -> UUID? in
      link.from == nodeID ? link.to : link.to == nodeID ? link.from : nil
    }
    let chain = Set(from.map(\.id)).union(to.map(\.id))
    beside = neighbours(peers + forks).filter { !chain.contains($0.id) }
  }
}
