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
    /// How many hand-offs from a beginning this loop sits — its level. A loop nothing
    /// hands off to is at level 0, wired or loose.
    let column: Int
    let row: Int
    /// Which column *within* its level the card wrapped into. A level holds at most
    /// `Metrics.maximumRowsPerLevel` rows; past that it grows sideways rather than down,
    /// and this is how far sideways. Levels are still laid out in order, so column 1 of
    /// level 0 is nowhere near level 1.
    var subColumn = 0
    /// A loop with no edge in either direction has no level to be at. It goes in the
    /// block below the chains, wrapped by the same rule but measured from the lane's own
    /// left edge — never *between* two levels, where the hand-offs crossing from one to
    /// the next would run over it.
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
    /// The fewest rows a lane ever packs to, however small the pane. Below this the grid
    /// is wider than it is tall for no gain — the cards start running off the side
    /// instead of the bottom.
    static let minimumRowBudget = 3
    /// The most columns a level spreads into. Width is the cheap axis, but it is not
    /// free: past this the lane is wider than any display and the wrapping has only
    /// traded a scroll down for a scroll across.
    static let maximumColumnsPerLevel = 8
    /// The most rows a level ever stacks before it wraps into the column beside it,
    /// however much room the pane has. Six loops one under another already read as a
    /// list rather than as a level, and a level you have to scroll is one you cannot
    /// compare across. The pane's own budget can lower this on a short window; nothing
    /// raises it.
    static let maximumRowsPerLevel = 5

    /// How many rows fit in `height` points of pane, at the scale a canvas settles at
    /// when it opens (`CanvasTransform.defaultFitFloor`) and after the lane's own
    /// furniture — caption, padding, the rail's top margin — has taken its share.
    ///
    /// This is what makes the wrap dynamic: the budget is what the pane can actually
    /// show, not a number picked once. A taller display packs fewer, wider columns; a
    /// short window spreads the same loops further across.
    static func rowBudget(forHeight height: CGFloat) -> Int {
      let furniture = laneTop + CanvasBand.captionHeight + CanvasBand.padding * 2
      let usable = height / CanvasTransform.defaultFitFloor - furniture
      return max(minimumRowBudget, Int(usable / rowHeight))
    }

    /// The budget when no pane has been measured yet — what the main display could show.
    /// The graph is opened on a monitor whether or not a `GeometryReader` has run.
    static var displayRowBudget: Int {
      let height = CGDisplayBounds(CGMainDisplayID()).height
      return rowBudget(forHeight: height > 0 ? height : 900)
    }

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
  /// Where each level's cards start, as an offset from the lane's first card — index by
  /// a slot's column. Not a single pitch: a level is as wide as the columns it wrapped
  /// into, and one holding several rows earns a wider gap after it than one holding a
  /// single hand-off (`Metrics.busyDepthGap`).
  private(set) var depthOffsets: [CGFloat] = [0]
  /// How wide the lane came out, from the first card's leading edge to the last one's
  /// trailing edge — a band has to be drawn around it, and a lane whose levels wrapped is
  /// wider than the levels alone say.
  private(set) var contentWidth = Metrics.card.width

  /// - Parameters:
  ///   - roles: passed in rather than resolved here because both callers already have
  ///     them for their cards, and `CardEntryRole.roles(in:)` walks the whole edge list.
  ///   - rowHeight: the Graph view's pitch unless the caller needs a taller one — see
  ///     `rowHeight(for:)`.
  init(
    graph: LoopGraph, roles: [UUID: CardEntryRole], origin: CGPoint = Metrics.origin,
    rowHeight: CGFloat = Metrics.rowHeight, rowBudget: Int = Metrics.displayRowBudget
  ) {
    // Everything nothing hands off to goes in level 0, one per row, and each chain flows
    // right into the next level along its own row. A level taller than
    // `maximumRowsPerLevel` then wraps into the column beside it — every level by the same
    // rule, so a fan of twenty children reads as a block the same way a pile of twenty
    // loose loops does. Wrapping the loose ones only was the visible version of this
    // being two rules: the bottom of a lane wrapped and the top of it did not.
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
    // Who handed off to each card, so a level can keep one parent's children together
    // rather than running two parents' fans into one block — see `wrapLevels`.
    var handedOffBy: [UUID: UUID] = [:]

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
        if placed[next.id] == nil { handedOffBy[next.id] = node.id }
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

    let rows = Self.rowsPerLevel(within: rowBudget)
    var wrapped = Self.wrapLevels(placed, rowsPerLevel: rows, handedOffBy: handedOffBy)

    // Everything left has no edge in either direction, so it has no level to be at and no
    // chain to be read along: its own block below the chains, wrapped by the same rule.
    let chainRows = wrapped.values.map(\.row).max().map { $0 + 1 } ?? 0
    for (index, node) in graph.nodes.filter({ !wired.contains($0.id) }).enumerated() {
      wrapped[node.id] = Slot(
        column: 0, row: chainRows + index % rows,
        subColumn: min(index / rows, Metrics.maximumColumnsPerLevel - 1), isLoose: true)
    }

    slots = wrapped
    depthOffsets = Self.depthOffsets(for: slots)
    positions = slots.mapValues { slot in
      CGPoint(
        x: x(of: slot, from: origin),
        y: origin.y + CGFloat(slot.row) * rowHeight)
    }
    rowCount = max(slots.values.map(\.row).max().map { $0 + 1 } ?? 1, 1)
    contentWidth = (slots.values.map { x(of: $0, from: .zero) }.max() ?? 0) + Metrics.card.width
  }

  /// How many rows a level stacks before it wraps: the pane's own budget, never more than
  /// `Metrics.maximumRowsPerLevel`. The cap is what makes the wrap unconditional — a
  /// level of twenty wraps on a tall display too, where there was room to just keep
  /// stacking and the result was a column nobody could compare across.
  static func rowsPerLevel(within rowBudget: Int) -> Int {
    max(1, min(rowBudget, Metrics.maximumRowsPerLevel))
  }

  /// Packs each level into a block of at most `rows` rows and wraps into the column
  /// beside it after that, keeping one parent's children together.
  ///
  /// Packed *densely*: a level's own cards are renumbered 0, 1, 2… before the fold rather
  /// than folded on whatever row a chain happened to reach. Folding the raw row left a
  /// level of five cards scattered over four columns and twenty cells, because a fan-out
  /// upstream had already spent those rows — that was the ragged, half-empty lane, and
  /// most of the width it took up.
  ///
  /// Dense is not enough on its own, though: packed straight through, two parents' fans
  /// run into one another mid-column and the level reads as a single set of children
  /// belonging to nobody in particular. So a group that would be split starts the next
  /// column instead, and the block of cards under one parent is a block you can point at.
  /// A fan longer than a column still spans as many as it needs.
  ///
  /// Order is preserved, which is what keeps the simple cases lined up: two chains side
  /// by side stay level with each other, and a 1:1 hand-off stays on its parent's row.
  private static func wrapLevels(
    _ placed: [UUID: Slot], rowsPerLevel rows: Int, handedOffBy: [UUID: UUID]
  ) -> [UUID: Slot] {
    var packed: [UUID: Slot] = [:]
    for (level, members) in Dictionary(grouping: placed.map { ($0.key, $0.value) }, by: \.1.column)
    {
      // One group per parent, each in the order the chain walk reached it, and the groups
      // themselves in that order too.
      let ordered = members.sorted { $0.1.row < $1.1.row }
      var groups: [[(UUID, Slot)]] = []
      var index: [UUID: Int] = [:]
      for member in ordered {
        let key = handedOffBy[member.0] ?? UUID.zeroParent
        if let existing = index[key] {
          groups[existing].append(member)
        } else {
          index[key] = groups.count
          groups.append([member])
        }
      }

      var column = 0
      var row = 0
      for group in groups {
        // A fan gets columns of its own — opened before it and closed after it — so the
        // cards under one parent are a block you can point at. Two parents' fans packed
        // into one column is the thing this is for: it reads as a single set of children
        // belonging to nobody, whichever way the lines are drawn.
        //
        // A parent with one child is not a fan and shares the column, which is what keeps
        // a lane of 1:1 chains one column wide and level with itself.
        let isFan = group.count > 1
        if isFan && row > 0 {
          column += 1
          row = 0
        }
        for member in group {
          packed[member.0] = Slot(
            column: level, row: row,
            subColumn: min(column, Metrics.maximumColumnsPerLevel - 1))
          row += 1
          if row == rows {
            column += 1
            row = 0
          }
        }
        if isFan && row > 0 {
          column += 1
          row = 0
        }
      }
    }
    return packed
  }

  /// A card's centre x: where its level starts, plus however far it wrapped within it.
  /// Levels are a table rather than a multiplication because one is as wide as the
  /// columns it wrapped into, and the gap after it depends on how many rows it holds —
  /// see `Metrics.busyDepthGap`.
  func x(of slot: Slot, from origin: CGPoint) -> CGFloat {
    guard !slot.isLoose else { return origin.x + CGFloat(slot.subColumn) * Metrics.columnWidth }
    let depth = max(min(slot.column, depthOffsets.count - 1), 0)
    return origin.x + depthOffsets[depth] + CGFloat(slot.subColumn) * Metrics.columnWidth
  }

  /// One offset per level, each pushed out by however wide the level before it came out —
  /// the columns it wrapped into — plus a gap that widens when that level holds more than
  /// one row.
  private static func depthOffsets(for placed: [UUID: Slot]) -> [CGFloat] {
    let levels = Dictionary(grouping: placed.values.filter { !$0.isLoose }, by: \.column)
    var offsets: [CGFloat] = [0]
    for depth in 1..<Metrics.columns {
      let previous = levels[depth - 1] ?? []
      let columns = (previous.map(\.subColumn).max() ?? 0) + 1
      let width =
        CGFloat(columns) * Metrics.card.width + CGFloat(columns - 1) * Metrics.columnGap
      let gap = Set(previous.map(\.row)).count > 1 ? Metrics.busyDepthGap : Metrics.depthGap
      offsets.append(offsets[depth - 1] + width + gap)
    }
    return offsets
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
  static func positions(
    forCanvas graph: LoopGraph, rowBudget: Int = Metrics.displayRowBudget
  ) -> [UUID: CGPoint] {
    var placed = LaneLayout(
      graph: graph, roles: CardEntryRole.roles(in: graph), rowHeight: rowHeight(for: graph),
      rowBudget: rowBudget
    ).positions
    for node in graph.nodes {
      guard let subGraph = node.subGraph else { continue }
      placed.merge(positions(forCanvas: subGraph, rowBudget: rowBudget)) { current, _ in current }
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

extension UUID {
  /// The key a card with no parent groups under: every beginning is a sibling of the
  /// lane's origin, so they share one group rather than each earning a column.
  fileprivate static let zeroParent = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
