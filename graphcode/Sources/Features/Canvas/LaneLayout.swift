import CoreGraphics
import Foundation
import GraphcodeKit

/// Where one graph's cards go: the column says how far a loop sits from a beginning, the
/// row says which chain it belongs to.
///
/// Lifted out of the Graph view's lane layout so a folder's own canvas can be placed by the
/// same rules. The two used to disagree about what a graph looks like — the Graph view read
/// the edges and laid chains out left-to-right off a column of beginnings, while a project's
/// canvas handed out grid slots in whatever order nodes arrived from the daemon and never
/// looked at an edge at all. The same three loops therefore read as a chain in one view and
/// as a scatter in the other, with the hand-offs between them running behind the cards.
/// There is one answer to "where does this card go" now, and both canvases ask it.
///
/// Positions are *derived*, never accumulated. Recomputing from the graph is cheaper than
/// reconciling a stored table against the next broadcast, and it is the whole point: a new
/// edge has to re-flow the cards it now relates, which a table of slots handed out at
/// arrival time can never do.
struct LaneLayout: Equatable {
  /// One card's place in the lane, before it becomes a point.
  struct Slot: Hashable {
    /// For a loop in a chain, how many hand-offs from a beginning it sits — its depth.
    /// For a loose one, which packed column it landed in, which means nothing but "the
    /// nth on this row".
    let column: Int
    let row: Int
    /// A loop with no edge in either direction has no depth to be at, so it is packed at
    /// the tighter pitch below the chains rather than given a level of its own.
    var isLoose = false
  }

  enum Metrics {
    static let card = LoopCardView.Metrics.size
    /// Between two cards on the same depth — the loose grid's pitch.
    static let columnGap: CGFloat = 40
    /// Between one depth and the next, and much wider than `columnGap` on purpose: with
    /// both the same, a lane of packed loose loops and a chain three hand-offs long are
    /// the same picture, and the x axis stops meaning "how far from a beginning". Width
    /// is the cheap axis — the graph is read on a landscape monitor, and a lane that runs
    /// wide is one that never ran tall.
    static let depthGap: CGFloat = 140
    /// The gap *after* a depth that holds more than one row. A level with several chains
    /// leaving it fans several hand-offs into the next one, and they all cross the same
    /// gap: at the ordinary width those curves bunch into a braid you cannot follow a
    /// single strand of.
    static let busyDepthGap: CGFloat = 230
    static let rowGap: CGFloat = 24
    /// How far right a chain runs before it folds back into the last column. A lane that
    /// grew without bound would push whatever is below it off the canvas, and four
    /// hand-offs is already deeper than a real graph goes.
    static let columns = 4
    /// How many loose loops stack in one column before they wrap into a second beside
    /// it. A graph of twenty loops that nothing runs is the common shape — loops that
    /// spawned loops — and one row each made the lane a card-wide ribbon several screens
    /// long with its whole width empty beside it. Only the loose ones wrap: a chain's
    /// row is where its hand-offs are drawn, and folding those would put one chain's
    /// beginning to the right of another chain's end.
    static let wrapAfterRows = 6

    static let columnWidth = card.width + columnGap
    static let depthWidth = card.width + depthGap
    static let rowHeight = card.height + rowGap
    /// Where a lane's band begins. On the Graph view that leaves the start node its own
    /// 60pt column plus a gap; a project's canvas has no start node, but it keeps the
    /// margin so a band drawn around its cards lands exactly where a lane's band does.
    static let bandX: CGFloat = 80
    /// Clear of the attention rail, which floats over both canvases' top-left corner.
    static let laneTop: CGFloat = 62
    static let bandWidth = bandWidth(contentWidth: CGFloat(columns - 1) * depthWidth + card.width)

    /// A band around a lane whose cards span `contentWidth`, leading edge to trailing
    /// edge. Taken from the lane rather than from a column count: a lane of packed loose
    /// loops and a lane of chains are different widths for the same number of cards.
    static func bandWidth(contentWidth: CGFloat) -> CGFloat {
      CanvasBand.padding * 2 + CanvasBand.originLane + max(contentWidth, card.width)
    }
    /// The first card's centre, inside the band and clear of the origin lane.
    static let firstLoopX =
      bandX + CanvasBand.padding + CanvasBand.originLane + card.width / 2
    static let firstRowInset = CanvasBand.captionHeight + CanvasBand.padding + card.height / 2
    /// The first card's centre on a canvas showing exactly one graph. The Graph view
    /// stacks several, so it offsets each lane's own top instead — see `GraphOverview`.
    static let origin = CGPoint(x: firstLoopX, y: laneTop + firstRowInset)
  }

  /// Which column and row each node landed in.
  private(set) var slots: [UUID: Slot] = [:]
  /// Each node's card centre, in canvas coordinates.
  private(set) var positions: [UUID: CGPoint] = [:]
  /// How many rows the lane used — never zero, so a band around an empty graph is still
  /// one row tall rather than a caption-height sliver.
  private(set) var rowCount = 1
  /// Where each depth's cards sit, as an offset from the lane's first card — index by a
  /// slot's column. Not a single pitch, because a depth that holds several rows earns a
  /// wider gap after it than one that holds a single hand-off (`Metrics.busyDepthGap`).
  private(set) var depthOffsets: [CGFloat] = [0]
  /// How wide the lane came out, from the first card's leading edge to the last one's
  /// trailing edge — a band has to be drawn around it, and a lane that packed its loose
  /// loops is wider than the depths alone say.
  private(set) var contentWidth = Metrics.card.width

  /// - Parameters:
  ///   - roles: passed in rather than resolved here because both callers already have
  ///     them for their cards, and `CardEntryRole.roles(in:)` walks the whole edge list.
  ///   - rowHeight: the Graph view's pitch unless the caller needs a taller one — see
  ///     `rowHeight(for:)`.
  init(
    graph: LoopGraph, roles: [UUID: CardEntryRole], origin: CGPoint = Metrics.origin,
    rowHeight: CGFloat = Metrics.rowHeight
  ) {
    // Everything nothing hands off to goes in column 0, one per row, and each chain flows
    // right along its own row.
    //
    // Filling rows left-to-right put all four rootless cards of a real graph side by side,
    // which hid the origin's fan behind them — cards draw over the lines, so the connectors
    // showed only in the gaps and read as one card chained to the next. A column of
    // beginnings is also how the graph reads: down the left is where work starts, across is
    // where it goes.
    let hangsOffOrigin: (LoopNode) -> Bool = {
      roles[$0.id] == .entry || roles[$0.id] == .unwired
    }
    let wired = Set(graph.edges.flatMap { [$0.from, $0.to] })
    let starts = Array(graph.nodes).filter(hangsOffOrigin)
    let depths = Self.depths(in: graph, from: starts.map(\.id))

    var placed: [UUID: Slot] = [:]
    var takenRows: Set<Int> = []
    var occupied: Set<Slot> = []

    func place(_ node: LoopNode, preferring row: Int) {
      guard placed[node.id] == nil else { return }
      let column = min(depths[node.id] ?? 0, Metrics.columns - 1)
      var candidate = row
      while occupied.contains(Slot(column: column, row: candidate)) { candidate += 1 }
      let slot = Slot(column: column, row: candidate)
      placed[node.id] = slot
      occupied.insert(slot)
      takenRows.insert(candidate)
      // Walk this chain onward on the same row, so a hand-off reads as one line of work.
      for edge in graph.edges where edge.from == node.id {
        guard let next = graph.nodes[id: edge.to] else { continue }
        place(next, preferring: candidate)
      }
    }

    var nextRow = 0
    for node in starts where wired.contains(node.id) {
      while takenRows.contains(nextRow) { nextRow += 1 }
      place(node, preferring: nextRow)
    }
    // Whatever a walk from a beginning never reached: a closed cycle, which has none.
    for node in graph.nodes where placed[node.id] == nil && wired.contains(node.id) {
      while takenRows.contains(nextRow) { nextRow += 1 }
      place(node, preferring: nextRow)
    }

    // Everything left has no edge in either direction, so it has no depth and no chain to
    // be read along — it is packed below what does, in as many columns as it takes to
    // keep the lane readable without scrolling.
    let chainRows = placed.values.map(\.row).max().map { $0 + 1 } ?? 0
    let loose = graph.nodes.filter { !wired.contains($0.id) }
    let looseColumns = Self.looseColumns(for: loose.count)
    for (index, node) in loose.enumerated() {
      placed[node.id] = Slot(
        column: index % looseColumns, row: chainRows + index / looseColumns, isLoose: true)
    }

    slots = placed
    depthOffsets = Self.depthOffsets(for: placed)
    positions = placed.mapValues { slot in
      CGPoint(
        x: x(of: slot, from: origin),
        y: origin.y + CGFloat(slot.row) * rowHeight)
    }
    rowCount = max(placed.values.map(\.row).max().map { $0 + 1 } ?? 1, 1)
    contentWidth = (placed.values.map { x(of: $0, from: .zero) }.max() ?? 0) + Metrics.card.width
  }

  /// A card's centre x: where its depth starts, or its packed column at the tighter
  /// pitch. Depths are a table rather than a multiplication because the gap between two
  /// of them depends on how many rows the nearer one holds — see `Metrics.busyDepthGap`.
  func x(of slot: Slot, from origin: CGPoint) -> CGFloat {
    guard !slot.isLoose else { return origin.x + CGFloat(slot.column) * Metrics.columnWidth }
    let depth = min(slot.column, depthOffsets.count - 1)
    return origin.x + depthOffsets[max(depth, 0)]
  }

  /// One offset per depth, each pushed out by the width of the depth before it plus a gap
  /// that widens when that depth holds more than one row.
  private static func depthOffsets(for placed: [UUID: Slot]) -> [CGFloat] {
    let rows = Dictionary(grouping: placed.values.filter { !$0.isLoose }, by: \.column)
      .mapValues { Set($0.map(\.row)).count }
    var offsets: [CGFloat] = [0]
    for depth in 1..<Metrics.columns {
      let gap = (rows[depth - 1] ?? 0) > 1 ? Metrics.busyDepthGap : Metrics.depthGap
      offsets.append(offsets[depth - 1] + Metrics.card.width + gap)
    }
    return offsets
  }

  /// How wide to pack `count` loose loops: one column until they would out-run the lane's
  /// height, then as many as it takes to stay within it. A handful stays a column, which
  /// is the shape a small graph has always had.
  private static func looseColumns(for count: Int) -> Int {
    guard count > Metrics.wrapAfterRows else { return 1 }
    return max(1, Int((Double(count) / Double(Metrics.wrapAfterRows)).rounded(.up)))
  }

  /// Every card one canvas can show: this graph's own loops, plus the insides of every
  /// composite on it.
  ///
  /// Drilling into a composite swaps the canvas over to its sub-graph (see
  /// `ProjectFeature.State.canvasGraph`), and those loops need somewhere to be too — a
  /// missing position draws every card of a drilled-in canvas at the same unplaced point.
  /// Node ids are unique across the whole tree, so one flat table serves every level; the
  /// levels are laid out over each other on purpose, since exactly one of them is ever on
  /// screen.
  static func positions(forCanvas graph: LoopGraph) -> [UUID: CGPoint] {
    var placed = LaneLayout(
      graph: graph, roles: CardEntryRole.roles(in: graph), rowHeight: rowHeight(for: graph)
    ).positions
    for node in graph.nodes {
      guard let subGraph = node.subGraph else { continue }
      placed.merge(positions(forCanvas: subGraph)) { current, _ in current }
    }
    return placed
  }

  /// The row pitch a canvas needs: the Graph view's own, unless a composite here is drawn
  /// open. A folder's canvas hangs a composite's insides below its card (`SubGraphLayout`),
  /// and those chips need more room under a card than the Graph view — which expands
  /// nothing — leaves between rows. Taller uniformly rather than only under the composites,
  /// because rows of two different heights is exactly the raggedness this layout is for.
  static func rowHeight(for graph: LoopGraph) -> CGFloat {
    let expandsSomething = graph.nodes.contains { $0.subGraph?.nodes.isEmpty == false }
    return expandsSomething ? max(Metrics.rowHeight, SubGraphLayout.rowPitch) : Metrics.rowHeight
  }

  /// How many hand-offs from a beginning each loop sits — its column.
  ///
  /// Capped by the walk itself rather than by a visited set: a cycle would otherwise raise
  /// its own depth forever, and the column is clamped to the lane's width anyway.
  private static func depths(in graph: LoopGraph, from starts: [UUID]) -> [UUID: Int] {
    var depths = Dictionary(uniqueKeysWithValues: starts.map { ($0, 0) })
    var frontier = starts
    while let current = frontier.popLast() {
      let next = (depths[current] ?? 0) + 1
      guard next < Metrics.columns else { continue }
      for edge in graph.edges where edge.from == current {
        guard (depths[edge.to] ?? -1) < next else { continue }
        depths[edge.to] = next
        frontier.append(edge.to)
      }
    }
    return depths
  }
}
