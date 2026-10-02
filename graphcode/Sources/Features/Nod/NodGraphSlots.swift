import GraphcodeKit
import SwiftUI

/// Where the graph layer (design 1c, owned by the NodGraphLayer stream) plugs into the
/// chat pane without the pane knowing what a sibling or a handoff is: a context strip under
/// the goal header, inline mail and handoff offers between turns, and offers above the
/// composer. Every slot defaults to nothing, which is also what a loop with no edges gets.
///
/// Installed with `.environment(\.nodGraphSlots, …)` around `NodChatPaneView`.
struct NodGraphSlots {
  /// "from Pricing → Monetization → Release notes · beside Billing UI".
  var contextStrip: (() -> AnyView)?
  /// Drawn after a turn: mail that arrived during it, a handoff it received.
  var afterTurn: ((_ turn: Int) -> AnyView?)?
  /// "Hand off to Release notes with a summary of what changed?"
  var aboveComposer: (() -> AnyView)?
  /// Replaces the pane's plain draft card for a reply Nod drafted to a sibling.
  var mailDraft: ((NodEvent.MailDraft) -> AnyView)?
  /// Replaces the pane's plain plan card (design section 4).
  var plan: ((NodEvent.PlanProposed) -> AnyView)?

  init(
    contextStrip: (() -> AnyView)? = nil,
    afterTurn: ((Int) -> AnyView?)? = nil,
    aboveComposer: (() -> AnyView)? = nil,
    mailDraft: ((NodEvent.MailDraft) -> AnyView)? = nil,
    plan: ((NodEvent.PlanProposed) -> AnyView)? = nil
  ) {
    self.contextStrip = contextStrip
    self.afterTurn = afterTurn
    self.aboveComposer = aboveComposer
    self.mailDraft = mailDraft
    self.plan = plan
  }
}

private struct NodGraphSlotsKey: EnvironmentKey {
  static let defaultValue = NodGraphSlots()
}

extension EnvironmentValues {
  var nodGraphSlots: NodGraphSlots {
    get { self[NodGraphSlotsKey.self] }
    set { self[NodGraphSlotsKey.self] = newValue }
  }
}
