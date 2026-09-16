import ComposableArchitecture
import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// The canvas lists loops in the sidebar's order.
///
/// Reported: packing a lane for space reshuffled it — a parent's children came out in the
/// order their edges were created, and beginnings in the order the daemon stored them, so
/// the canvas and the list beside it disagreed about which loop comes next. Space is
/// found by wrapping, never by reordering.
@Suite
struct LaneOrderTests {
  private static let project = ProjectRef(path: "/tmp/lane-order", name: "lane-order")

  /// Reading order on a canvas: down a column, then the next column across.
  private func readingOrder(_ overview: GraphOverview, titles: Set<String>) -> [String] {
    overview.loops.filter { titles.contains($0.node.title) }
      .sorted { ($0.position.x, $0.position.y) < ($1.position.x, $1.position.y) }
      .map(\.node.title)
  }

  @Test
  func aParentsChildrenFollowTheSidebarNotTheOrderTheirEdgesWereMade() {
    let parent = LoopNode(title: "parent")
    let first = LoopNode(title: "first")
    let second = LoopNode(title: "second")
    let third = LoopNode(title: "third")
    // Three different orders, so only following the sidebar gives the right answer: the
    // graph stores second, third, first; the edges were made third, first, second.
    let graph = LoopGraph(
      project: Self.project, nodes: [parent, second, third, first],
      edges: [
        LoopEdge(from: parent.id, to: third.id), LoopEdge(from: parent.id, to: first.id),
        LoopEdge(from: parent.id, to: second.id),
      ])

    let overview = GraphOverview(
      graphs: [graph],
      orders: [Self.project.path: [parent.id, first.id, second.id, third.id]])

    #expect(
      readingOrder(overview, titles: ["first", "second", "third"])
        == ["first", "second", "third"])
  }

  @Test
  func beginningsAndLooseLoopsFollowTheSidebarToo() {
    let wiredA = LoopNode(title: "wired-a")
    let wiredB = LoopNode(title: "wired-b")
    let childA = LoopNode(title: "child-a")
    let childB = LoopNode(title: "child-b")
    let looseA = LoopNode(title: "loose-a")
    let looseB = LoopNode(title: "loose-b")
    let graph = LoopGraph(
      project: Self.project, nodes: [wiredA, wiredB, childA, childB, looseA, looseB],
      edges: [LoopEdge(from: wiredA.id, to: childA.id), LoopEdge(from: wiredB.id, to: childB.id)])

    // The sidebar has B before A in both groups — the reverse of the graph's own order.
    let order = [wiredB.id, childB.id, looseB.id, wiredA.id, childA.id, looseA.id]
    let overview = GraphOverview(graphs: [graph], orders: [Self.project.path: order])

    #expect(readingOrder(overview, titles: ["wired-a", "wired-b"]) == ["wired-b", "wired-a"])
    #expect(readingOrder(overview, titles: ["loose-a", "loose-b"]) == ["loose-b", "loose-a"])
    // A chain still stays on its beginning's row.
    let at = Dictionary(uniqueKeysWithValues: overview.loops.map { ($0.node.title, $0.position) })
    #expect(at["child-b"]?.y == at["wired-b"]?.y)
    #expect(at["child-a"]?.y == at["wired-a"]?.y)
  }

  @Test
  func wrappingALongLevelKeepsItsOrder() {
    // Twelve children wrap into columns; reading down each column and then across must
    // still give the sidebar's order, not the edges'.
    let parent = LoopNode(title: "parent")
    let children = (0..<12).map { LoopNode(title: String(format: "child-%02d", $0)) }
    // Stored odds-then-evens and wired in reverse, so neither the graph's order nor the
    // edges' can pass for the sidebar's.
    let stored = children.enumerated().sorted {
      ($0.offset % 2, $0.offset) > ($1.offset % 2, $1.offset)
    }
    .map(\.element)
    let graph = LoopGraph(
      project: Self.project,
      nodes: IdentifiedArray(uniqueElements: [parent] + stored),
      edges: IdentifiedArray(
        uniqueElements: children.reversed().map { LoopEdge(from: parent.id, to: $0.id) }))

    let overview = GraphOverview(
      graphs: [graph], orders: [Self.project.path: [parent.id] + children.map(\.id)])

    let titles = Set(children.map(\.title))
    #expect(readingOrder(overview, titles: titles) == children.map(\.title))
    #expect(
      Set(overview.loops.filter { titles.contains($0.node.title) }.map(\.position.x)).count > 1)
  }

  @Test
  func reorderingTheSidebarReordersAFoldersCanvas() async {
    let first = LoopNode(title: "first")
    let second = LoopNode(title: "second")
    let graph = LoopGraph(project: Self.project, nodes: [first, second])
    let store = await TestStore(initialState: ProjectFeature.State(graph: graph)) {
      ProjectFeature()
    }
    store.exhaustivity = .off
    let before = store.state.nodePositions

    await store.send(.sidebarNodesReordered([second.id, first.id]))

    let after = store.state.nodePositions
    // Dragged above it in the sidebar, so above it on the canvas.
    #expect((after[second.id]?.y ?? 0) < (after[first.id]?.y ?? 0))
    #expect(before != after)
  }
}
