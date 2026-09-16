import ComposableArchitecture
import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// Where a lane's cards land — the geometry half of the Graph view, split from
/// `GraphOverviewTests` so each stays inside swiftlint's body limit.
///
/// These are all statements about one thing: a graph has to stay readable as it grows.
/// A level wraps rather than stacking past what a pane can show, a hand-off is a wider
/// step than a wrap so depth still means depth, and every lane is drawn in a band of the
/// same width so the folders read as a table rather than a collage.
@Suite
struct GraphOverviewLayoutTests {
  private static let projectA = ProjectRef(path: "/tmp/project-a", name: "project-a")
  private static let projectB = ProjectRef(path: "/tmp/project-b", name: "project-b")

  @Test
  func aLaneOfLooseLoopsPacksIntoAGridRatherThanOneLongRibbon() throws {
    // The shape a graph of loops-that-spawned-loops actually has: twenty loops nothing
    // runs. A row each made the lane a card-wide ribbon several screens tall with its own
    // width empty beside it, which is what "the graph is skewed" means.
    let nodes = (0..<20).map { LoopNode(title: "loop-\($0)") }
    let pane: CGFloat = 900
    let overview = GraphOverview(
      graphs: [LoopGraph(project: Self.projectA, nodes: IdentifiedArray(uniqueElements: nodes))],
      viewportHeight: pane)

    let columns = Set(overview.loops.map(\.position.x))
    let rows = Set(overview.loops.map(\.position.y))
    // Packed to what the pane can show, not to a number picked once.
    #expect(rows.count <= LaneLayout.Metrics.rowBudget(forHeight: pane))
    #expect(columns.count > 1)
    // Every card still lands inside the band drawn around the lane — the band is sized
    // to the lane it wrapped into, not to the four columns a chain can reach.
    let band = try #require(overview.folders.first).band
    #expect(
      overview.loops.allSatisfy {
        $0.position.x - GraphOverview.Metrics.card.width / 2 >= band.minX
          && $0.position.x + GraphOverview.Metrics.card.width / 2 <= band.maxX
      })
  }

  @Test
  func packingLooseLoopsNeverCostsADepthItsOwnDistance() {
    // The packed columns are a grid of cards with no depth between them; a hand-off is a
    // level. If the two were the same pitch, a lane of loose loops and a chain three
    // hand-offs long would be the same picture.
    let root = LoopNode(title: "root")
    let downstream = LoopNode(title: "downstream")
    let loose = (0..<20).map { LoopNode(title: "loose-\($0)") }
    let overview = GraphOverview(graphs: [
      LoopGraph(
        project: Self.projectA,
        nodes: IdentifiedArray(uniqueElements: [root, downstream] + loose),
        edges: [LoopEdge(from: root.id, to: downstream.id)])
    ])

    let at = Dictionary(uniqueKeysWithValues: overview.loops.map { ($0.node.title, $0.position) })
    let depthStep = (at["downstream"]?.x ?? 0) - (at["root"]?.x ?? 0)
    let packedColumns = Set(
      overview.loops.filter { $0.node.title.hasPrefix("loose") }.map(\.position.x))
    let packedStep = (packedColumns.sorted().dropFirst().first ?? 0) - (packedColumns.min() ?? 0)
    #expect(packedStep > 0)
    #expect(depthStep > packedStep)
    // A chain still reads along its own row.
    #expect(at["downstream"]?.y == at["root"]?.y)
    // The loose ones have no level to be at, so they go in their own block below the
    // chains — wrapped by the same rule, but never *between* two levels, where the
    // hand-offs crossing from one to the next would run over them.
    #expect(
      overview.loops.filter { $0.node.title.hasPrefix("loose") }
        .allSatisfy { $0.position.y > (at["root"]?.y ?? 0) })
  }

  @Test
  func ashorterPaneSpreadsTheSameLoopsWiderRatherThanTaller() {
    // The dynamic half: the same graph in half the pane is the same graph laid out
    // wider. Height is what runs out on a display; width is what there is spare.
    let nodes = (0..<24).map { LoopNode(title: "loop-\($0)") }
    func lane(inPaneOf height: CGFloat) -> (rows: Int, columns: Int) {
      let overview = GraphOverview(
        graphs: [
          LoopGraph(project: Self.projectA, nodes: IdentifiedArray(uniqueElements: nodes))
        ], viewportHeight: height)
      return (
        Set(overview.loops.map(\.position.y)).count, Set(overview.loops.map(\.position.x)).count
      )
    }

    // Both sides of `rowsPerLevel`: a roomy pane packs to the five-row cap, a cramped
    // one to what it can actually show.
    let tall = lane(inPaneOf: 900)
    let short = lane(inPaneOf: 400)
    #expect(short.rows < tall.rows)
    #expect(short.columns > tall.columns)
  }

  @Test
  func everyLevelWrapsAtTheSameHeight() {
    // The reported bug: the bottom of a lane wrapped and the top of it did not. Loops
    // nothing runs were packed into a grid while a parent's twenty children still took a
    // row each, so one lane had two layouts in it.
    let parent = LoopNode(title: "parent")
    let children = (0..<14).map { LoopNode(title: "child-\($0)") }
    let overview = GraphOverview(graphs: [
      LoopGraph(
        project: Self.projectA,
        nodes: IdentifiedArray(uniqueElements: [parent] + children),
        edges: IdentifiedArray(
          uniqueElements: children.map { LoopEdge(from: parent.id, to: $0.id) }))
    ])

    let placed = overview.loops.filter { $0.node.title.hasPrefix("child") }
    #expect(placed.count == children.count)
    // Wrapped, not stacked: no more rows than the cap, and more than one column of them.
    #expect(Set(placed.map(\.position.y)).count <= LaneLayout.Metrics.maximumRowsPerLevel)
    #expect(Set(placed.map(\.position.x)).count > 1)
    // Still one level out from their parent — every one of them to the right of it.
    let parentX = overview.loops.first { $0.node.title == "parent" }?.position.x ?? 0
    #expect(placed.allSatisfy { $0.position.x > parentX })
    // And inside the band drawn around the lane.
    let band = overview.folders.first?.band ?? .zero
    #expect(placed.allSatisfy { $0.position.x + GraphOverview.Metrics.card.width / 2 <= band.maxX })
  }

  @Test
  func aDepthCarryingSeveralRowsPushesTheNextOneFurtherOut() {
    // Several chains leaving one level fan their hand-offs across the same gap, and at
    // the ordinary width those curves bunch into a braid. Width is the cheap axis here —
    // the graph is read on a landscape monitor.
    func step(chains: Int) -> CGFloat {
      var nodes: [LoopNode] = []
      var edges: [LoopEdge] = []
      for index in 0..<chains {
        let root = LoopNode(title: "root-\(index)")
        let next = LoopNode(title: "next-\(index)")
        nodes += [root, next]
        edges.append(LoopEdge(from: root.id, to: next.id))
      }
      let overview = GraphOverview(graphs: [
        LoopGraph(
          project: Self.projectA, nodes: IdentifiedArray(uniqueElements: nodes),
          edges: IdentifiedArray(uniqueElements: edges))
      ])
      let at = Dictionary(
        uniqueKeysWithValues: overview.loops.map { ($0.node.title, $0.position.x) })
      return (at["next-0"] ?? 0) - (at["root-0"] ?? 0)
    }

    #expect(step(chains: 2) > step(chains: 1))
  }

  @Test
  func lanesKeepOneWidthSoTheyReadAsATableOfProjects() {
    // A wrapped lane is wider than an unwrapped one, and bands cut each to their own
    // contents read as a collage. The widest lane sets the width for all of them.
    let wide = (0..<20).map { LoopNode(title: "wide-\($0)") }
    let overview = GraphOverview(graphs: [
      LoopGraph(project: Self.projectA, nodes: IdentifiedArray(uniqueElements: wide)),
      LoopGraph(project: Self.projectB, nodes: [LoopNode(title: "alone")]),
    ])

    let widths = Set(overview.folders.map(\.band.width))
    #expect(widths.count == 1)
    #expect(overview.size.width >= (widths.first ?? 0))
  }
}
