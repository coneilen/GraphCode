import GraphcodeKit
import SwiftUI

/// "✓ Goal holds · Hand off to Release notes with a summary of what changed?" — under a
/// met goal check, when something is downstream. The brief is reviewed before it goes.
struct NodHandoffOfferView: View {
  let offer: NodHandoffOffer
  /// The reviewed brief; send `offer.commands(brief:)`.
  let onHandOff: (String) -> Void
  let onDismiss: () -> Void

  @State private var reviewing = false
  @State private var brief = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(LoopType.goalBased.accent)
        Text("Goal holds").font(.system(size: 12, weight: .semibold))
        Text(offer.evidence.joined(separator: " · "))
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.7))
          .lineLimit(1)
      }
      Text("Hand off to \(targetNames) with a summary of what changed?")
        .font(.system(size: 12))
      if reviewing {
        TextEditor(text: $brief)
          .font(.system(size: 12))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 60, maxHeight: 180)
          .padding(4)
          .background(RoundedRectangle(cornerRadius: 6).fill(Theme.draftField))
        HStack {
          Button("Hand off") { onHandOff(brief) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Cancel") { reviewing = false }
        }
        .controlSize(.small)
      } else {
        HStack {
          Button("Review & hand off") {
            brief = offer.suggestedBrief
            reviewing = true
          }
          .buttonStyle(.borderedProminent)
          Button("Not now", action: onDismiss)
        }
        .controlSize(.small)
      }
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sheet))
    .overlay(
      RoundedRectangle(cornerRadius: 8).stroke(LoopType.goalBased.accent.opacity(0.45)))
  }

  private var targetNames: String {
    ListFormatter.localizedString(byJoining: offer.targets.map(\.title))
  }
}
