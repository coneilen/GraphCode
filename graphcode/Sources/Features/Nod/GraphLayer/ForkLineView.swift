import GraphcodeKit
import SwiftUI

/// The dotted "forked from" line between a loop and the fork racing it. Not an edge: it
/// sequences nothing and carries nothing, so it has no head and no context menu.
struct ForkLineView: View {
  let from: CGPoint
  let to: CGPoint

  var body: some View {
    let start = CanvasEdgeGeometry.exit(from: from, toward: to, cardSize: LoopCardView.Metrics.size)
    let end = CanvasEdgeGeometry.entry(at: to, from: from, cardSize: LoopCardView.Metrics.size)
    let controls = CanvasEdgeGeometry.controls(from: start, to: end)
    Path { path in
      path.move(to: start)
      path.addCurve(to: end, control1: controls.0, control2: controls.1)
    }
    .stroke(
      Color.white.opacity(0.4),
      style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.5, 5])
    )
    .help("forked from")
    .accessibilityLabel("Forked from")
  }
}
