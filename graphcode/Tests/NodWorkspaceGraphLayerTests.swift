import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// Pricing → Monetization → Release notes, with Billing UI messaging beside it: the
/// design's 1c graph, around a Nod goal loop whose log holds mail from Billing UI with
/// Nod's draft, a plan, and a goal check that holds.
enum NodGraphLayerFixture {
  static let pricing = LoopNode(title: "Pricing", loopType: .goalBased)
  static let me = LoopNode(
    title: "Monetization", loopType: .goalBased,
    goal: GoalSpec(summary: "every paid route enforces the cap"), backend: .nod)
  static let notes = LoopNode(title: "Release notes", loopType: .turnBased)
  static let billing = LoopNode(title: "Billing UI", loopType: .turnBased)

  static let graph = LoopGraph(
    project: ProjectRef(path: "/work/repo", name: "repo"),
    nodes: IdentifiedArrayOf(uniqueElements: [pricing, me, notes, billing]),
    edges: IdentifiedArrayOf(uniqueElements: [
      LoopEdge(from: pricing.id, to: me.id),
      LoopEdge(from: me.id, to: notes.id),
      LoopEdge(from: billing.id, to: me.id, kind: .message),
    ]))

  static let planSteps: [[String: Any]] = [
    ["id": "1", "text": "Move /export behind UsageGate", "files": ["Sources/Server/Routes.swift"]],
    ["id": "2", "text": "Show the cap in the upgrade banner", "files": ["App/Banner.swift"]],
    ["id": "3", "text": "swift test passes", "files": [], "doneCheck": true],
  ]

  static var log: NodLog {
    var log = NodLog()
    log.session()
    log.add(
      "userMessage",
      [
        "id": "u1", "text": "[graphcode] Billing UI: What does /export return over the cap?",
        "delivery": "queue", "attachments": [], "fromNodeID": billing.id.uuidString,
      ])
    log.turn(1, origin: "mail")
    log.say("It returns 402 with the plan's limit in the body.", turn: 1, id: "m1")
    log.add(
      "mailDraft",
      [
        "draftID": "d1", "toNodeID": billing.id.uuidString, "inReplyTo": "u1",
        "text": "402 Payment Required, with `limit` and `used` in the JSON body.",
      ])
    log.endTurn(1)
    log.user("Plan the cap work across server and app.", id: "u2")
    log.turn(2)
    log.add(
      "planProposed", ["planID": "p1", "title": "Enforce the usage cap", "steps": planSteps])
    log.say("Capped every paid route; the suite is green.", turn: 2, id: "m2")
    log.goalCheck(
      turn: 2, met: true,
      clauses: [
        ("Every paid route goes through UsageGate", true, "4 / 4 routes"),
        ("swift test passes", true, "31 tests pass"),
      ])
    log.endTurn(2, files: 2, added: 25, removed: 1)
    return log
  }

  static func workspace(node: LoopNode = me) -> LoopWorkspaceFeature.State {
    var state = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: "/work/repo",
      projectName: "repo")
    state.graph = graph
    var chat = NodChatFeature.State(
      nodeID: node.id, stateDirectory: URL(fileURLWithPath: "/tmp/nod-unused"),
      loopTitle: node.title, loopType: node.loopType, goal: node.goal?.summary)
    chat.transcript = log.transcript
    state.nodChat = chat
    return state
  }
}

@MainActor
@Suite
struct NodWorkspaceDelegateTests {
  typealias Fixture = NodGraphLayerFixture

  private struct Fork: Sendable {
    var source: UUID
    var messageID: String
    var conversationID: String?
  }

  private struct Recorded: Sendable {
    let sent = LockIsolated<[DaemonCommand]>([])
    let forks = LockIsolated<[Fork]>([])
    let composites = LockIsolated<[NodEditablePlan]>([])
    let openedSettings = LockIsolated(0)
    let policies = LockIsolated<[NodSettings.EditPolicy]>([])

    var graphCommands: [GraphCommand] {
      sent.value.compactMap {
        guard case .graphCommand(let path, let command) = $0, path == "/work/repo" else {
          return nil
        }
        return command
      }
    }
  }

  private func makeStore(
    _ state: LoopWorkspaceFeature.State = Fixture.workspace(), recorded: Recorded,
    forkFails: Bool = false
  ) -> TestStoreOf<LoopWorkspaceFeature> {
    let store = TestStore(initialState: state) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in recorded.sent.withValue { $0.append(command) } }
      $0.nodGraphActions = NodGraphActionsClient(
        fork: { source, graph, messageID, conversationID, send in
          #expect(graph == Fixture.graph)
          recorded.forks.withValue {
            $0.append(Fork(source: source.id, messageID: messageID, conversationID: conversationID))
          }
          if forkFails { throw NodGraphActions.Failure.worktree("branch exists") }
          let id = UUID()
          try await send(
            .createNode(NodeDraft(id: id, title: "Monetization fork", loopType: .goalBased)))
          return id
        },
        runAsComposite: { plan, _, send in
          recorded.composites.withValue { $0.append(plan) }
          let id = UUID()
          try await send(.pilotComposite(id))
          return id
        })
      $0.nodSettings.openNodSettings = { recorded.openedSettings.withValue { $0 += 1 } }
      $0.nodSettings.setEditPolicy = { policy in recorded.policies.withValue { $0.append(policy) } }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func forkAsSiblingForksAtTheMessageOnTheConversationAndSendsThroughTheDaemon() async {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded)
    await store.send(.nodChat(.delegate(.forkAsSibling(messageID: "m2"))))
    await store.finish()
    #expect(recorded.forks.value.map(\.source) == [Fixture.me.id])
    #expect(recorded.forks.value.map(\.messageID) == ["m2"])
    #expect(recorded.forks.value.map(\.conversationID) == ["c-1"])
    guard case .createNode(let draft) = recorded.graphCommands.first else {
      Issue.record("no createNode reached the daemon: \(recorded.sent.value)")
      return
    }
    #expect(draft.title == "Monetization fork")
  }

  @Test
  func aFailedForkLandsInTheChatsErrorLine() async {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded, forkFails: true)
    await store.send(.nodChat(.delegate(.forkAsSibling(messageID: "m2"))))
    await store.receive(\.nodGraphActionFailed)
    #expect(store.state.nodChat?.sendError == "Couldn't create the fork's worktree: branch exists")
    #expect(recorded.sent.value.isEmpty)
  }

  @Test
  func runPlanAsCompositeRunsThePlanAsTheHumanLeftIt() async {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded)
    await store.send(.nodChat(.delegate(.runPlanAsComposite(planID: "p1"))))
    await store.finish()
    #expect(recorded.composites.value.first?.steps.map(\.id) == ["1", "2", "3"])

    var edited = NodEditablePlan(planID: "p1", title: "Enforce the usage cap", steps: [])
    edited.add("Only the server half")
    await store.send(.nodPlanEdited(edited))
    await store.send(.nodChat(.runPlanTapped(planID: "p1", mode: .composite)))
    await store.finish()
    #expect(recorded.composites.value.last == edited)
    #expect(
      recorded.graphCommands.filter { if case .pilotComposite = $0 { true } else { false } }.count
        == 2)

    await store.send(.nodChat(.delegate(.runPlanAsComposite(planID: "missing"))))
    await store.finish()
    #expect(recorded.composites.value.count == 2)
  }

  @Test
  func graphVerbsSendTheirCommandsAndExplainARefusal() async {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded)
    await store.send(
      .nodChat(.delegate(.graphCommand(name: "handoff", argument: "cap is enforced"))))
    await store.finish()
    #expect(
      recorded.graphCommands == [
        .messageNode(
          Fixture.notes.id, text: "Handoff: cap is enforced", from: Fixture.me.id, followUp: true)
      ])

    await store.send(
      .nodChat(.delegate(.graphCommand(name: "ask", argument: "@Billing what's the copy?"))))
    await store.finish()
    #expect(
      recorded.graphCommands.last
        == .messageNode(
          Fixture.billing.id, text: "what's the copy?", from: Fixture.me.id, followUp: true))

    await store.send(.nodChat(.delegate(.graphCommand(name: "ask", argument: ""))))
    await store.receive(\.nodGraphActionFailed)
    #expect(store.state.nodChat?.sendError == "Usage: \(NodGraphVerb.askUsage)")

    await store.send(.nodChat(.delegate(.graphCommand(name: "promote", argument: "turn"))))
    await store.receive(\.nodGraphActionFailed)
    #expect(store.state.nodChat?.sendError == "Only a sketch can be promoted.")

    await store.send(.nodChat(.delegate(.graphCommand(name: "ask", argument: "@Nobody hi"))))
    await store.receive(\.nodGraphActionFailed)
    #expect(store.state.nodChat?.sendError == "No loop called Nobody in this graph.")
    #expect(recorded.graphCommands.count == 2)
  }

  @Test
  func messageLoopStartsAnAskToThatLoop() async {
    let store = makeStore(recorded: Recorded())
    await store.send(.nodChat(.delegate(.messageLoop(Fixture.notes.id))))
    #expect(store.state.nodChat?.draft == "/ask @Release notes ")
    await store.send(.nodChat(.delegate(.messageLoop(UUID()))))
    #expect(store.state.nodChat?.draft == "/ask @Release notes ")
  }

  @Test
  func editGoalOpensTheSheetAndSavingUpdatesTheNode() async {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded)
    await store.send(.nodChat(.delegate(.editGoal)))
    #expect(store.state.nodGoalDraft == "every paid route enforces the cap")

    await store.send(.nodGoalDraftChanged("   "))
    await store.send(.nodGoalSaved)
    #expect(store.state.nodGoalDraft == "   ")

    await store.send(.nodGoalDraftChanged("every paid route is capped and logged"))
    await store.send(.nodGoalSaved)
    await store.finish()
    #expect(store.state.nodGoalDraft == nil)
    #expect(
      recorded.graphCommands == [
        .updateNode(
          Fixture.me.id, update: NodeUpdate(goalSummary: "every paid route is capped and logged"))
      ])

    await store.send(.nodChat(.editGoalTapped))
    await store.receive(\.nodChat.delegate.editGoal)
    #expect(store.state.nodGoalDraft != nil)
    await store.send(.nodGoalDraftChanged(nil))
    #expect(store.state.nodGoalDraft == nil)
  }

  @Test
  func signInAndRaiseCapOpenNodsSettings() async {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded)
    await store.send(.nodChat(.delegate(.signIn)))
    await store.send(.nodChat(.delegate(.raiseSpendCap)))
    await store.send(.nodChat(.signInTapped))
    await store.finish()
    #expect(recorded.openedSettings.value == 3)
  }

  @Test
  func editPolicyChosenIsKeptForTheChatAndSettings() async {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded)
    await store.send(.nodChat(.delegate(.editPolicyChosen(.auto))))
    await store.finish()
    #expect(store.state.nodChat?.editPolicy == .auto)
    #expect(recorded.policies.value == [.auto])
  }

  @Test
  func takingTheHandoffHandsTheBriefDownstreamAndCompletesTheLoop() async throws {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded)
    let check = try #require(store.state.nodChat?.transcript.lastGoalCheck)
    let offer = try #require(
      NodHandoffOffer.make(check: check, nodeID: Fixture.me.id, in: Fixture.graph))
    await store.send(.nodHandoffTapped(offer, brief: "Cap enforced on 4 routes", turn: 2))
    await store.finish()
    #expect(store.state.nodSettledHandoffs == [2])
    #expect(
      recorded.graphCommands == [
        .messageNode(
          Fixture.notes.id, text: "Handoff: Cap enforced on 4 routes", from: Fixture.me.id,
          followUp: true),
        .completeNode(Fixture.me.id, result: "Cap enforced on 4 routes", from: nil),
      ])

    await store.send(.nodHandoffDismissed(turn: 5))
    #expect(store.state.nodSettledHandoffs == [2, 5])
  }

  @Test
  func answeringMailMyselfMessagesTheSenderAsThisLoop() async throws {
    let recorded = Recorded()
    let store = makeStore(recorded: recorded)
    let transcript = try #require(store.state.nodChat?.transcript)
    let mail = try #require(
      NodGraphLayerModel.inboundMail(in: transcript, nodeID: Fixture.me.id, graph: Fixture.graph)[
        "u1"])
    await store.send(.nodMailAnswered(mail, text: "402, see the body"))
    await store.finish()
    #expect(
      recorded.graphCommands == [
        .messageNode(
          Fixture.billing.id, text: "402, see the body", from: Fixture.me.id, followUp: true)
      ])
  }
}

@MainActor
@Suite
struct NodWorkspaceSlotsTests {
  typealias Fixture = NodGraphLayerFixture

  @Test
  func mailFromASiblingIsFoundWithNodsDraft() throws {
    let transcript = Fixture.log.transcript
    let inbound = NodGraphLayerModel.inboundMail(
      in: transcript, nodeID: Fixture.me.id, graph: Fixture.graph)
    #expect(Array(inbound.keys) == ["u1"])
    let mail = try #require(inbound["u1"])
    #expect(mail.kind == .mail)
    #expect(mail.sender?.id == Fixture.billing.id)
    #expect(mail.isQuestion)
    #expect(transcript.mailDraft(inReplyTo: "u1")?.draftID == "d1")
    #expect(transcript.mailDraft(inReplyTo: "u2") == nil)
  }

  @Test
  func theHandoffIsOfferedUnderTheNewestHeldCheckUntilSettled() throws {
    let transcript = Fixture.log.transcript
    let check = try #require(transcript.lastGoalCheck)
    func offer(_ check: NodEvent.GoalCheck, node: LoopNode = Fixture.me, settled: Set<Int> = [])
      -> NodHandoffOffer?
    {
      NodGraphLayerModel.handoffOffer(
        after: check, in: transcript, node: node, graph: Fixture.graph, settled: settled)
    }
    let offered = try #require(offer(check))
    #expect(offered.targets.map(\.id) == [Fixture.notes.id])
    #expect(offered.evidence == ["4 / 4 routes", "31 tests pass"])
    #expect(offered.suggestedBrief == "Capped every paid route; the suite is green.")

    #expect(offer(check, settled: [2]) == nil)
    var resolved = Fixture.me
    resolved.state = .succeeded
    #expect(offer(check, node: resolved) == nil)
    var older = check
    older.turn = 1
    #expect(offer(older) == nil)
    var unmet = Fixture.log
    unmet.goalCheck(turn: 3, met: false, clauses: [("swift test passes", false, nil)])
    let unmetCheck = try #require(unmet.transcript.lastGoalCheck)
    #expect(
      NodGraphLayerModel.handoffOffer(
        after: unmetCheck, in: unmet.transcript, node: Fixture.me, graph: Fixture.graph,
        settled: []) == nil)
  }

  @Test
  func theWorkspaceFillsEverySlotTheGraphCalledFor() throws {
    let store = Store(initialState: Fixture.workspace()) { LoopWorkspaceFeature() }
    let scoped: StoreOf<NodChatFeature>? = store.scope(state: \.nodChat, action: \.nodChat)
    let chat = try #require(scoped)
    let slots = NodGraphSlots.workspace(store, chat: chat)
    let transcript = Fixture.log.transcript
    let mailPrompt = try #require(transcript.turns.first?.prompt)
    let humanPrompt = try #require(transcript.turns.last?.prompt)
    let check = try #require(transcript.lastGoalCheck)

    #expect(slots.contextStrip != nil)
    #expect(slots.inboundMessage?(mailPrompt, .mail) != nil)
    #expect(slots.inboundMessage?(humanPrompt, .user) == nil)
    #expect(slots.afterGoalCheck?(check) != nil)
    #expect(slots.plan != nil)
    #expect(slots.mailDraft != nil)

    store.send(.nodHandoffDismissed(turn: 2))
    #expect(NodGraphSlots.workspace(store, chat: chat).afterGoalCheck?(check) == nil)
  }

  @Test
  func aLoopWithNoNeighboursKeepsThePlainPane() {
    let context = NodGraphContext(
      nodeID: Fixture.me.id,
      in: LoopGraph(
        project: ProjectRef(path: "/work/repo", name: "repo"),
        nodes: IdentifiedArrayOf(uniqueElements: [Fixture.me])))
    #expect(context.isEmpty)
    let full = NodGraphContext(nodeID: Fixture.me.id, in: Fixture.graph)
    #expect(full.from.map(\.id) == [Fixture.pricing.id])
    #expect(full.to.map(\.id) == [Fixture.notes.id])
    #expect(full.beside.map(\.id) == [Fixture.billing.id])
  }
}
