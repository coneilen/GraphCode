import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// Clicking an edge lights the two loops it joins and dims the rest of the canvas.
@Suite
struct EdgeFocusTests {
  private let from = UUID()
  private let to = UUID()
  private let bystander = UUID()

  @Test
  func theTwoLoopsAnEdgeJoinsStayLitAndEverythingElseStepsBack() {
    let focus = EdgeFocus(edgeID: "e1", from: from, to: to)

    #expect(focus.emphasis(forNode: from) == .lit)
    #expect(focus.emphasis(forNode: to) == .lit)
    #expect(focus.emphasis(forNode: bystander) == .dimmed)
    #expect(focus.emphasis(forEdge: "e1") == .lit)
    #expect(focus.emphasis(forEdge: "e2") == .dimmed)
    // Dimmed is a step back, not gone — the graph's shape has to survive around the pair.
    #expect(CanvasEmphasis.dimmed.opacity > 0 && CanvasEmphasis.dimmed.opacity < 1)
    #expect(CanvasEmphasis.lit.opacity == 1)
  }

  @Test
  func withNothingFocusedTheCanvasDrawsAsItAlwaysDid() {
    let none: EdgeFocus? = nil
    #expect(none.emphasis(forNode: bystander) == .normal)
    #expect(none.emphasis(forEdge: "e1") == .normal)
    #expect(none.sceneryOpacity == 1)
    // Scenery only ever steps back; it has no lit state to be in.
    let some: EdgeFocus? = EdgeFocus(edgeID: "e1", from: from, to: to)
    #expect(some.sceneryOpacity == CanvasEmphasis.dimmed.opacity)
  }

  @Test
  func clickingTheFocusedEdgeAgainLetsGoAndClickingAnotherMovesTheFocus() {
    let first = EdgeFocus(edgeID: "e1", from: from, to: to)
    let second = EdgeFocus(edgeID: "e2", from: to, to: bystander)

    #expect(EdgeFocus.toggling(nil, to: first) == first)
    #expect(EdgeFocus.toggling(first, to: first) == nil)
    #expect(EdgeFocus.toggling(first, to: second) == second)
  }

  @Test
  func theGraphViewsEdgesCarryTheLoopsTheyJoin() {
    // Without the ids a click on an overview edge has nothing to light.
    let a = Fixture.make("a")
    let b = Fixture.make("b")
    let overview = GraphOverview(graphs: [Fixture.graph([a, b], edgeFrom: a, to: b)])
    let link = overview.links.first
    #expect(link?.fromID == a.id)
    #expect(link?.toID == b.id)
  }
}

private enum Fixture {
  static func make(_ title: String) -> LoopNode { LoopNode(title: title) }

  static func graph(_ nodes: [LoopNode], edgeFrom from: LoopNode, to: LoopNode) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/edge-focus", name: "edge-focus"),
      nodes: IdentifiedArray(uniqueElements: nodes),
      edges: [LoopEdge(from: from.id, to: to.id)])
  }
}
