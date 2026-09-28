import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The canvas half of goal ↔ time retyping: "Change to…" opens the promotion form on a
/// goal or time loop for the other type, and confirming sends the same `promoteNode` the
/// CLI's `node promote` does.
@Suite
@MainActor
struct LoopRetypeFormTests {
  private static let project = ProjectRef(path: "/tmp/retype", name: "retype")

  private let goal = LoopNode(
    title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "the flake is fixed"))
  private let time = LoopNode(
    title: "Watch", loopType: .timeBased, triggerPrompt: "/loop 1h triage new issues")

  private func state(_ nodes: [LoopNode]) -> ProjectFeature.State {
    ProjectFeature.State(
      graph: LoopGraph(project: Self.project, nodes: IdentifiedArray(uniqueElements: nodes)))
  }

  @Test
  func eachUnattendedTypeRetypesOnlyToTheOther() {
    #expect(LoopType.goalBased.retypeTarget == .timeBased)
    #expect(LoopType.timeBased.retypeTarget == .goalBased)
    #expect(LoopType.turnBased.retypeTarget == nil)
    #expect(LoopType.composite.retypeTarget == nil)
    #expect(LoopType.sketch.retypeTarget == nil)
  }

  @Test
  func aGoalLoopsTimedFormNeedsATaskOfItsOwn() {
    var state = state([goal])
    state.nodePendingPromotion = goal.id
    state.promotionTarget = .timeBased
    state.promotionInterval = .hourly

    // A goal loop has no note to repeat, and repeating its withdrawn goal would be wrong.
    #expect(state.promotion == nil)
    state.promotionTask = "check the flake hasn't come back"
    #expect(state.promotion == .timed(triggerPrompt: "/loop 1h check the flake hasn't come back"))
  }

  @Test
  func changingAGoalLoopToTimedSendsThePromotion() async {
    let sent = SentCommandsBox()
    let store = TestStore(initialState: state([goal])) {
      ProjectFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.promoteNodeRequested(goal.id, to: .timeBased))
    #expect(store.state.nodePendingPromotion == goal.id)
    #expect(store.state.promotionSource == .goalBased)

    await store.send(.binding(.set(\.promotionTask, "check the flake hasn't come back")))
    await store.send(.promotionConfirmed)
    await store.finish()

    #expect(store.state.nodePendingPromotion == nil)
    #expect(
      await sent.all == [
        .graphCommand(
          projectPath: Self.project.path,
          command: .promoteNode(
            goal.id, promotion: .timed(triggerPrompt: "/loop 1h check the flake hasn't come back"),
            promotedBy: nil))
      ])
  }

  @Test
  func changingATimeLoopToGoalSendsThePromotion() async {
    let sent = SentCommandsBox()
    let store = TestStore(initialState: state([time])) {
      ProjectFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.promoteNodeRequested(time.id, to: .goalBased))
    await store.send(.binding(.set(\.promotionGoal, "the backlog is empty")))
    await store.send(.promotionConfirmed)
    await store.finish()

    #expect(
      await sent.all == [
        .graphCommand(
          projectPath: Self.project.path,
          command: .promoteNode(
            time.id, promotion: .goal(GoalSpec(summary: "the backlog is empty")),
            promotedBy: nil))
      ])
  }

  /// The daemon refuses these; the form must not open on them and let a human fill it in
  /// for nothing.
  @Test
  func theFormStaysShutForAnythingTheDaemonWouldRefuse() async {
    let turn = LoopNode(title: "Review", checkDescription: "Sound?")
    var stopped = time
    stopped.state = .stopped
    let store = TestStore(initialState: state([goal, turn, stopped])) {
      ProjectFeature()
    }
    store.exhaustivity = .off

    await store.send(.promoteNodeRequested(goal.id, to: .turnBased))
    await store.send(.promoteNodeRequested(goal.id, to: .goalBased))
    await store.send(.promoteNodeRequested(turn.id, to: .timeBased))
    await store.send(.promoteNodeRequested(stopped.id, to: .goalBased))

    #expect(store.state.nodePendingPromotion == nil)
  }
}

private actor SentCommandsBox {
  private(set) var all: [DaemonCommand] = []
  func append(_ command: DaemonCommand) { all.append(command) }
}
