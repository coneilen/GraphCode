import Foundation

/// A clicked edge, and what the rest of the canvas does about it: the two loops it joins
/// stay lit, and everything else steps back.
///
/// A graph of thirty loops answers "what does this hand-off connect" by tracing a line
/// across a lane of other lines; dimming everything else turns it into a question you
/// answer by looking. View state rather than reducer state — like the canvas transform, it
/// describes how the graph is being *looked at*, and nothing else in the app needs it.
struct EdgeFocus: Equatable {
  /// The focused line's id, in the namespace of the canvas that drew it — a link id on
  /// the Graph view, an edge id on a folder's canvas.
  let edgeID: String
  let from: UUID
  let to: UUID

  func emphasis(forNode id: UUID) -> CanvasEmphasis { id == from || id == to ? .lit : .dimmed }
  func emphasis(forEdge id: String) -> CanvasEmphasis { id == edgeID ? .lit : .dimmed }

  /// Clicking the focused edge again lets go of it: the click that set it undoes it, so
  /// there is no second gesture to learn.
  static func toggling(_ current: EdgeFocus?, to next: EdgeFocus) -> EdgeFocus? {
    current == next ? nil : next
  }
}

enum CanvasEmphasis: Equatable {
  case normal
  case lit
  case dimmed

  /// Dimmed is low enough that the lit pair reads as the only thing on the canvas, and
  /// high enough that the graph's shape survives around it — you still know where on it
  /// you are, which is what makes letting go of the focus not feel like a context switch.
  var opacity: Double { self == .dimmed ? 0.2 : 1 }
}

extension EdgeFocus? {
  func emphasis(forNode id: UUID) -> CanvasEmphasis { self?.emphasis(forNode: id) ?? .normal }
  func emphasis(forEdge id: String) -> CanvasEmphasis { self?.emphasis(forEdge: id) ?? .normal }

  /// Bands, tethers, the start node: scenery has no lit state, it only steps back.
  var sceneryOpacity: Double { self == nil ? 1 : CanvasEmphasis.dimmed.opacity }
}
