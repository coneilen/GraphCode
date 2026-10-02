import ComposableArchitecture
import Foundation
import GraphcodeKit

/// `NodGraphActions` as a dependency, so a reducer test sees what a fork or a Composite
/// would send without creating a worktree or writing briefs.
struct NodGraphActionsClient: Sendable {
  var fork:
    @Sendable (
      _ source: LoopNode, _ graph: LoopGraph, _ messageID: String, _ conversationID: String?,
      _ send: NodGraphActions.Send
    ) async throws -> UUID
  var runAsComposite:
    @Sendable (_ plan: NodEditablePlan, _ source: LoopNode, _ send: NodGraphActions.Send)
      async throws -> UUID
}

extension NodGraphActionsClient: DependencyKey {
  static let liveValue = NodGraphActionsClient(
    fork: { source, graph, messageID, conversationID, send in
      try await NodGraphActions.fork(
        source, in: graph, atMessage: messageID, conversationID: conversationID, send: send)
    },
    runAsComposite: { plan, source, send in
      try await NodGraphActions.runAsComposite(plan, plannedIn: source, send: send)
    })

  static let testValue = NodGraphActionsClient(
    fork: { _, _, _, _, _ in throw NodGraphActions.Failure.nodUnavailable },
    runAsComposite: { _, _, _ in throw NodGraphActions.Failure.nodUnavailable })
}

extension DependencyValues {
  var nodGraphActions: NodGraphActionsClient {
    get { self[NodGraphActionsClient.self] }
    set { self[NodGraphActionsClient.self] = newValue }
  }
}

extension NodGraphActions.Failure: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .nodUnavailable: "Nod isn't enabled on this Mac."
    case .nothingToRun: "The plan has no steps to run."
    case .worktree(let output): "Couldn't create the fork's worktree: \(output)"
    }
  }
}

extension NodGraphVerb.ResolveError {
  var message: String {
    switch self {
    case .unknownLoop(let name): "No loop called \(name) in this graph."
    case .noDownstream:
      "Nothing is downstream to hand off to. Name one: \(NodGraphVerb.handoffUsage)"
    case .emptyBrief: "Write the brief to hand off: \(NodGraphVerb.handoffUsage)"
    case .notASketch: "Only a sketch can be promoted."
    }
  }
}
