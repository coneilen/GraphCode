import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// A goal loop can become time-based and a time-based loop a goal loop, through the same
/// promotion that gives a main loop its shape. The id, edges and memory stay; only what
/// ends the loop changes, and the old shape's stop condition or cadence goes with it.
@Suite
struct LoopRetypeTests {
  private func goalDraft(_ predicate: String? = nil) -> NodeDraft {
    NodeDraft(
      title: "Fix", loopType: .goalBased,
      goal: GoalSpec(summary: "the flake is fixed", predicate: predicate))
  }

  private func timeDraft() -> NodeDraft {
    NodeDraft(title: "Watch", loopType: .timeBased, triggerPrompt: "/loop 1h triage new issues")
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test
  func aGoalLoopBecomesTimeBasedKeepingItsIdentity() async {
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in
      started.withValue { $0.append(node) }
    })
    let parent = NodeDraft(title: "Parent", loopType: .turnBased, firstInstruction: "Work")
    let goal = goalDraft()
    await store.handle(.createNode(parent))
    await store.handle(.createNode(goal))
    await store.handle(.createEdge(from: parent.id, to: goal.id, spec: EdgeSpec()))

    await store.handle(
      .promoteNode(
        goal.id, promotion: .timed(triggerPrompt: "/loop 1h check the flake"), promotedBy: nil))

    let graph = await store.graph
    let retyped = graph.nodes[id: goal.id]
    #expect(graph.nodes.count == 2)
    #expect(retyped?.loopType == .timeBased)
    #expect(retyped?.triggerPrompt == "/loop 1h check the flake")
    #expect(retyped?.goal == nil)
    #expect(retyped?.state == .idle)
    #expect(graph.edges.contains { $0.from == parent.id && $0.to == goal.id })
    #expect(await eventually { started.value.contains { $0.id == goal.id } })
  }

  @Test
  func aTimeBasedLoopBecomesAGoalLoopAndDropsItsCadence() async {
    let store = GraphStore()
    let time = timeDraft()
    await store.handle(.createNode(time))

    await store.handle(
      .promoteNode(
        time.id, promotion: .goal(GoalSpec(summary: "the backlog is empty")), promotedBy: nil))

    let retyped = await store.graph.nodes[id: time.id]
    #expect(retyped?.loopType == .goalBased)
    #expect(retyped?.goal?.summary == "the backlog is empty")
    #expect(retyped?.state == .running)
    #expect(retyped?.triggerPrompt == nil)
    #expect(retyped?.heartbeatIntervalSeconds == nil)
    // Verdicts from any goal the transcript held before must not count for this one.
    #expect(retyped?.goalSetAt != nil)
  }

  /// Leaving goal is leaving a stop condition, so the loop under it may not do it —
  /// otherwise any goal loop could end its own goal by turning itself into a watcher.
  @Test
  func aLoopMayNotDropItsOwnGoal() async {
    let entries = LockIsolated<[String]>([])
    let store = GraphStore(onAppendMemory: { _, entry in
      entries.withValue { $0.append(entry) }
    })
    let goal = goalDraft()
    await store.handle(.createNode(goal))

    await store.handle(
      .promoteNode(goal.id, promotion: .timed(triggerPrompt: "/loop 1h x"), promotedBy: goal.id))

    #expect(await store.graph.nodes[id: goal.id]?.loopType == .goalBased)
    #expect(entries.value.contains { $0.contains("may not drop its own goal") })
  }

  @Test
  func aTimeLoopGivingItselfAPredicateIsStillRefused() async {
    let store = GraphStore()
    let time = timeDraft()
    await store.handle(.createNode(time))

    await store.handle(
      .promoteNode(
        time.id, promotion: .goal(GoalSpec(summary: "done", predicate: "true")),
        promotedBy: time.id))

    #expect(await store.graph.nodes[id: time.id]?.loopType == .timeBased)
  }

  @Test
  func onlyGoalAndTimeSwapAndNothingElseIsRetyped() async {
    let store = GraphStore()
    let goal = goalDraft()
    let time = timeDraft()
    let turn = NodeDraft(title: "Review", loopType: .turnBased, firstInstruction: "Work")
    for draft in [goal, time, turn] { await store.handle(.createNode(draft)) }

    await store.handle(
      .promoteNode(goal.id, promotion: .turn(pausesBeforeWritesOnly: false), promotedBy: nil))
    await store.handle(
      .promoteNode(goal.id, promotion: .goal(GoalSpec(summary: "other")), promotedBy: nil))
    await store.handle(
      .promoteNode(time.id, promotion: .timed(triggerPrompt: "/loop 5m y"), promotedBy: nil))
    await store.handle(
      .promoteNode(turn.id, promotion: .timed(triggerPrompt: "/loop 5m y"), promotedBy: nil))

    let graph = await store.graph
    #expect(graph.nodes[id: goal.id]?.goal?.summary == "the flake is fixed")
    #expect(graph.nodes[id: time.id]?.triggerPrompt == "/loop 1h triage new issues")
    #expect(graph.nodes[id: turn.id]?.loopType == .turnBased)
  }

  @Test
  func aStoppedLoopIsNotRetyped() async {
    let store = GraphStore()
    let time = timeDraft()
    await store.handle(.createNode(time))
    await store.handle(.stopNode(time.id))

    await store.handle(
      .promoteNode(time.id, promotion: .goal(GoalSpec(summary: "x")), promotedBy: nil))

    #expect(await store.graph.nodes[id: time.id]?.loopType == .timeBased)
  }

  /// The common case: a goal loop finished, and now the same session should keep watching.
  @Test
  func aMetGoalLoopReopensAsTimeBased() async {
    let store = GraphStore()
    let goal = goalDraft()
    await store.handle(.createNode(goal))
    await store.handle(.completeNode(goal.id, result: "fixed", from: goal.id))
    #expect(await store.graph.nodes[id: goal.id]?.state == .succeeded)

    await store.handle(
      .promoteNode(goal.id, promotion: .timed(triggerPrompt: "/loop 1d x"), promotedBy: nil))

    let retyped = await store.graph.nodes[id: goal.id]
    #expect(retyped?.loopType == .timeBased)
    #expect(retyped?.state == .idle)
    #expect(retyped?.resolution == nil)
  }

  /// The new shape's prompt goes in verbatim, after the old one is let go of, so the
  /// directive arms instead of arriving as prose about a directive.
  @Test
  func aLiveSessionIsToldToLetGoThenGivenTheNewDirective() async {
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      onDeliverMessage: { _, text, _ in
        delivered.withValue { $0.append(text) }
        return true
      },
      onSessionAlive: { _, _ in true })
    let goal = goalDraft()
    let time = timeDraft()
    await store.handle(.createNode(goal))
    await store.handle(.createNode(time))

    await store.handle(
      .promoteNode(
        goal.id, promotion: .timed(triggerPrompt: "/loop 1h check the flake"), promotedBy: nil))
    #expect(await eventually { delivered.value.count == 3 })
    #expect(delivered.value.first?.contains("no longer a goal loop") == true)
    #expect(Array(delivered.value.dropFirst()) == ["/goal clear", "/loop 1h check the flake"])

    delivered.setValue([])
    await store.handle(
      .promoteNode(time.id, promotion: .goal(GoalSpec(summary: "CI passes")), promotedBy: nil))
    #expect(await eventually { delivered.value.count == 2 })
    #expect(delivered.value.first?.contains("turn off any recurring schedule") == true)
    #expect(delivered.value.last?.hasPrefix("/goal CI passes") == true)
  }

  /// Copilot and OpenCode have `/goal` but no verified `clear`; typing one could arm a
  /// goal named "clear", so those sessions are told in prose only.
  @Test
  func goalClearIsTypedOnlyWhereTheSubcommandIsVerified() {
    for backend in CLISessionBackendKind.allCases {
      let node = LoopNode(
        title: "Watch", loopType: .timeBased, triggerPrompt: "/loop 1h x", backend: backend)
      let messages = GraphStore.retypeMessages(
        for: node, from: .goalBased, formerGoal: "the flake is fixed")
      #expect(
        messages.contains("/goal clear") == [.claudeCode, .codex].contains(backend),
        "\(backend)")
    }
  }

  @Test
  func updatingAGoalLoopsCadenceSaysWhereTheTypeChangeLives() async {
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(onAnnounceError: { message in errors.withValue { $0.append(message) } })
    let goal = goalDraft()
    await store.handle(.createNode(goal))

    await store.handle(.updateNode(goal.id, update: NodeUpdate(triggerPrompt: "/loop 1h x")))

    #expect(errors.value.contains { $0.contains("graphcode node promote") })
  }
}
