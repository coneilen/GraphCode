import GraphcodeKit
import SwiftUI

/// The strip above a Nod transcript: `from Pricing → Monetization → Release notes ·
/// beside Billing UI`. Renders nothing at all for a loop with no neighbours, so a Main loop
/// on its own keeps the plain reading column.
struct NodContextStrip: View {
  let context: NodGraphContext
  let onOpen: (UUID) -> Void

  var body: some View {
    if !context.isEmpty {
      HStack(spacing: 6) {
        if !context.from.isEmpty {
          label("from")
          chips(context.from)
          arrow
        }
        Text(context.title)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.primary)
        if !context.to.isEmpty {
          arrow
          chips(context.to)
        }
        if !context.beside.isEmpty {
          label("beside").padding(.leading, 8)
          chips(context.beside)
        }
        Spacer(minLength: 8)
        Text("Nod can read these")
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.55))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(Theme.activityStrip)
      .overlay(alignment: .bottom) { Rectangle().fill(Theme.loopCardBorder).frame(height: 1) }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Loops beside this one")
    }
  }

  private var arrow: some View {
    Image(systemName: "arrow.right")
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(.white.opacity(0.55))
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 10))
      .foregroundStyle(.white.opacity(0.55))
  }

  private func chips(_ neighbours: [NodGraphContext.Neighbour]) -> some View {
    ForEach(neighbours) { neighbour in
      Button {
        onOpen(neighbour.id)
      } label: {
        HStack(spacing: 4) {
          Circle().fill(neighbour.loopType.accent).frame(width: 6, height: 6)
          Text(neighbour.title).font(.system(size: 11))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.tabSelectedBackground))
      }
      .buttonStyle(.plain)
      .help("\(neighbour.loopType.displayName) · open \(neighbour.title)")
    }
  }
}
