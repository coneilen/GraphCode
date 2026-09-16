import ComposableArchitecture
import Foundation
import GraphcodeKit

/// Where a folder canvas's cards go, and what a new graph does to the state derived from
/// it. Split out of `ProjectFeature` the way the template half is: these are the
/// mutations that answer "where is everything", and the reducer body is a list of what
/// the human did, not of how the canvas re-lays itself out.
extension ProjectFeature {
  /// The pane measured itself and can show a different number of rows than before, so the
  /// loose loops re-pack — wider in a short window, narrower in a tall one (`LaneLayout`).
  ///
  /// A budget it already has is dropped rather than re-laid out: dragging a window edge
  /// crosses a row boundary now and then, and re-deriving every position per point of
  /// drag would move the cards under the pointer.
  static func repack(_ state: inout State, to budget: Int) {
    guard budget != state.canvasRowBudget else { return }
    state.canvasRowBudget = budget
    relayOut(&state)
  }

  /// Every position again, from the graph, the pane's row budget and the sidebar's order —
  /// the three things a card's place depends on, read from one place so no caller can
  /// pass two of them and forget the third.
  static func relayOut(_ state: inout State) {
    state.nodePositions = LaneLayout.positions(
      forCanvas: state.graph, rowBudget: state.canvasRowBudget, order: state.sidebarNodeOrder)
  }

  /// Everything a fresh graph changes about the canvas around it: where the cards are,
  /// which reclaim offers still have a loop to belong to, and the human's sidebar order.
  ///
  /// Every card is placed again from the graph that just arrived, rather than only the
  /// ones that are new. Slots handed out at arrival time made the canvas a record of the
  /// order loops turned up in: a hand-off drawn between two cards the layout had no
  /// reason to put near each other ran behind whatever sat between them, and wiring a
  /// graph up changed nothing about how it looked. See `LaneLayout`.
  static func absorb(_ newGraph: LoopGraph, into state: inout State) {
    state.graph = newGraph
    // An offer only makes sense while its loop exists, stays resolved, and still points
    // at the worktree — a restarted or deleted loop takes it with it.
    state.worktreeReclaimOffers = state.worktreeReclaimOffers.filter { id, _ in
      newGraph.nodes[id: id].map { $0.isResolved && $0.worktreeBinding != nil } == true
    }
    // Keep the human's sidebar arrangement across broadcasts: drop ids the graph no
    // longer has, append ones it gained, and touch nothing else.
    let currentIDs = Set(newGraph.nodes.map(\.id))
    state.sidebarNodeOrder.removeAll { !currentIDs.contains($0) }
    for node in newGraph.nodes where !state.sidebarNodeOrder.contains(node.id) {
      state.sidebarNodeOrder.append(node.id)
    }
    // Last, so the order it lays out by already knows about the loops this graph added.
    relayOut(&state)
  }
}
