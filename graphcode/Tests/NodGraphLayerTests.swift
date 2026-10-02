import Foundation
import IdentifiedCollections
import Testing

@testable import GraphcodeKit

@Suite
struct NodCompositeGroupingTests {
  /// The design's plan: steps 1, 2 and 4 touch the server, 3 the app, 4 is the done check.
  static let usageCapSteps = [
    NodPlanStep(
      id: "1", text: "Move /export behind UsageGate", files: ["Sources/Server/Routes.swift"]),
    NodPlanStep(
      id: "2", text: "Return 402 with { limit, resetsAt }, and log the block",
      files: ["Sources/Server/UsageGate.swift"], editedByHuman: true),
    NodPlanStep(
      id: "3", text: "Upgrade banner in the macOS app reads the 402",
      files: ["App/Billing/BillingBanner.swift"], size: .medium),
    NodPlanStep(
      id: "4", text: "Tests: past cap, monthly reset, legacy export",
      files: ["Tests/ServerTests/UsageCapTests.swift"], doneCheck: true),
  ]

  @Test
  func theDesignPlanBecomesTwoLoopsAndACheck() {
    let plan = NodCompositePlan(title: "Usage caps on every paid route", steps: Self.usageCapSteps)
    #expect(plan.groups.map(\.area) == ["Server", "App"])
    #expect(plan.groups.map { $0.steps.map(\.id) } == [["1", "2"], ["3"]])
    #expect(plan.doneChecks.map(\.id) == ["4"])
    #expect(plan.check == "Tests: past cap, monthly reset, legacy export")
  }

  @Test(arguments: [
    ("Sources/Server/Routes.swift", "Server"),
    ("Tests/ServerTests/UsageCapTests.swift", "Server"),
    ("src/lib/api/client.ts", "api"),
    ("./App/Billing/Banner.swift", "App"),
    ("README.md", ""),
    ("Sources/main.swift", ""),
    ("packages/web-tests/a.ts", "web"),
  ])
  func areaIsTheFirstMeaningfulDirectory(path: String, area: String) {
    #expect(NodCompositePlan.area(ofFile: path) == area)
  }

  @Test
  func aStepTouchingTwoAreasJoinsThem() {
    let steps = [
      NodPlanStep(id: "a", text: "server", files: ["Sources/Server/A.swift"]),
      NodPlanStep(id: "b", text: "app", files: ["App/B.swift"]),
      NodPlanStep(id: "c", text: "docs", files: ["docs/c.md"]),
      NodPlanStep(id: "d", text: "bridge", files: ["App/D.swift", "Sources/Server/D.swift"]),
    ]
    let plan = NodCompositePlan(title: "x", steps: steps)
    #expect(plan.groups.map { $0.steps.map(\.id) } == [["a", "b", "d"], ["c"]])
  }

  @Test
  func stepsWithoutFilesFollowTheStepBeforeThem() {
    let steps = [
      NodPlanStep(id: "lead", text: "think first"),
      NodPlanStep(id: "a", text: "server", files: ["Sources/Server/A.swift"]),
      NodPlanStep(id: "b", text: "app", files: ["App/B.swift"]),
      NodPlanStep(id: "tail", text: "tidy the app"),
    ]
    let plan = NodCompositePlan(title: "x", steps: steps)
    #expect(plan.groups.map { $0.steps.map(\.id) } == [["lead", "a"], ["b", "tail"]])
  }

  @Test
  func aPlanWithNoFilesIsOneLoopAndNoCheckWithoutADoneStep() {
    let plan = NodCompositePlan(
      title: "tidy", steps: [NodPlanStep(id: "1", text: "a"), NodPlanStep(id: "2", text: "b")])
    #expect(plan.groups.count == 1)
    #expect(plan.check == nil)
  }

  @Test
  func theCompositeHasAGoalChildPerGroupEachBriefedFromTheTranscript() throws {
    let worktree = WorktreeRef(
      id: "loop/monetization", repositoryPath: "/repo", worktreePath: "/repo-wt",
      branch: "loop/monetization")
    let source = LoopNode(
      title: "Monetization", loopType: .sketch, backend: .nod, worktreeBinding: worktree)
    let plan = NodCompositePlan(title: "Usage caps on every paid route", steps: Self.usageCapSteps)
    let made = plan.makeComposite(plannedIn: source) { "/briefs/\($0.uuidString).json" }

    #expect(made.draft.loopType == .composite)
    #expect(made.draft.title == "UsageCapsOnEvery")
    #expect(made.draft.checkDescription == plan.check)
    #expect(made.draft.createdBy == source.id)
    let children = try #require(made.draft.subGraph?.nodes)
    #expect(children.map(\.title) == ["Server", "App"])
    for child in children {
      #expect(child.loopType == .goalBased)
      #expect(child.backend == .nod)
      #expect(child.worktreeBinding == worktree)
      #expect(child.lineage?.kind == .compositeChild)
      #expect(child.lineage?.sourceNodeID == source.id)
    }
    #expect(children[0].goal?.summary.contains("Move /export behind UsageGate") == true)
    #expect(children[0].goal?.summary.contains("Upgrade banner") == false)

    #expect(made.briefs.count == 2)
    #expect(made.briefs.map(\.path) == children.compactMap(\.lineage?.briefPath))
    let brief = made.briefs[0].brief
    #expect(brief.kind == .compositeChild)
    #expect(brief.fromNodeID == source.id)
    #expect(
      brief.attachments == [NodAttachment(kind: .loopTranscript, reference: source.id.uuidString)])
    #expect(brief.text.contains("→ 1. Move /export behind UsageGate"))
    #expect(brief.text.contains("  3. Upgrade banner"))
    #expect(brief.text.contains("✓ 4. Tests"))
    #expect(brief.text.contains("Steps a human rewrote are theirs"))
  }

  /// `makeNode` re-identifies a composite's sub-graph; the lineage, and so the brief, must
  /// survive it.
  @Test
  func lineageSurvivesCreation() throws {
    let source = LoopNode(title: "Planner", loopType: .sketch)
    let made = NodCompositePlan(title: "p", steps: Self.usageCapSteps)
      .makeComposite(plannedIn: source) { "/b/\($0).json" }
    let node = made.draft.makeNode()
    let children = try #require(node.subGraph?.nodes)
    #expect(children.map(\.lineage) == made.draft.subGraph?.nodes.map(\.lineage))
    #expect(Set(children.map(\.id)).isDisjoint(with: made.draft.subGraph?.nodes.map(\.id) ?? []))
  }
}

@Suite
struct NodForkTests {
  static func graph(_ nodes: [LoopNode], edges: [LoopEdge] = []) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/work/repo", name: "repo"),
      nodes: IdentifiedArrayOf(uniqueElements: nodes),
      edges: IdentifiedArrayOf(uniqueElements: edges))
  }

  @Test
  func aForkIsASiblingOnItsOwnBranchCutFromTheSources() {
    let source = LoopNode(
      title: "Monetization", loopType: .goalBased,
      goal: GoalSpec(summary: "every paid route is capped", predicate: "swift test"),
      backend: .nod,
      worktreeBinding: WorktreeRef(
        id: "loop/monetization", repositoryPath: "/work/repo",
        worktreePath: "/work/repo-loop-monetization", branch: "loop/monetization"))
    let fork = NodFork(
      of: source, in: Self.graph([source]), atMessage: "m7", conversationID: "c1",
      approach: "check the cap inside the handler", briefPath: "/b/f.json")

    #expect(fork.draft.title == "Monetization2")
    #expect(fork.draft.loopType == .goalBased)
    #expect(fork.draft.goal == source.goal)
    #expect(fork.draft.backend == .nod)
    #expect(fork.draft.createdBy == nil)
    #expect(
      fork.draft.lineage
        == LoopLineage(kind: .fork, sourceNodeID: source.id, briefPath: "/b/f.json"))
    #expect(fork.worktree.repositoryPath == "/work/repo")
    #expect(fork.worktree.branch == "loop/monetization-fork2")
    #expect(fork.worktree.worktreePath == "/work/repo-loop-monetization-fork2")
    #expect(fork.worktree.startPoint == "loop/monetization")
    #expect(fork.brief.kind == .fork)
    #expect(fork.brief.fork == NodBrief.ForkPoint(conversationID: "c1", messageID: "m7"))
    #expect(fork.brief.text.contains("check the cap inside the handler"))
  }

  @Test
  func forksNumberUpAndAnUnboundSourceForksFromTheProject() {
    let source = LoopNode(title: "Spike", loopType: .sketch, backend: .nod)
    let first = NodFork(of: source, in: Self.graph([source]), atMessage: "m", briefPath: "/a")
    var second = first.draft.makeNode()
    second = LoopNode(
      id: second.id, title: second.title, loopType: second.loopType, lineage: second.lineage)
    let next = NodFork(
      of: source, in: Self.graph([source, second]), atMessage: "m", briefPath: "/b")
    #expect(first.worktree.branch == "nod/Spike-fork2")
    #expect(first.worktree.startPoint == nil)
    #expect(first.worktree.worktreePath == "/work/repo-nod-Spike-fork2")
    #expect(next.draft.title == "Spike3")
  }

  @Test
  func theForkedFromLinkIsDrawnOnlyWhileTheSourceExists() {
    let source = LoopNode(title: "A", loopType: .sketch)
    let fork = LoopNode(
      title: "A2", loopType: .sketch, lineage: LoopLineage(kind: .fork, sourceNodeID: source.id))
    let child = LoopNode(
      title: "C", loopType: .goalBased,
      lineage: LoopLineage(kind: .compositeChild, sourceNodeID: source.id))
    let links = Self.graph([source, fork, child]).forkLinks
    #expect(links.count == 1)
    #expect(links.first?.from == source.id && links.first?.to == fork.id)
    #expect(Self.graph([fork]).forkLinks.isEmpty)
  }

  @Test
  func lineageRoundTripsAndAGraphWithoutItStillDecodes() throws {
    let node = LoopNode(
      title: "A2", lineage: LoopLineage(kind: .fork, sourceNodeID: UUID(), briefPath: "/b"))
    let data = try JSONEncoder().encode(node)
    #expect(try JSONDecoder().decode(LoopNode.self, from: data).lineage == node.lineage)

    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["lineage"] = ["kind": "fromTheFuture", "sourceNodeID": UUID().uuidString]
    let future = try JSONSerialization.data(withJSONObject: json)
    #expect(try JSONDecoder().decode(LoopNode.self, from: future).lineage == nil)
  }
}

@Suite
struct NodGraphVerbTests {
  static let me = LoopNode(title: "Monetization", loopType: .goalBased)
  static let pricing = LoopNode(title: "Pricing", loopType: .goalBased)
  static let notes = LoopNode(title: "ReleaseNotes", loopType: .turnBased)
  static let billing = LoopNode(title: "BillingUI", loopType: .turnBased)
  static let graph = NodForkTests.graph(
    [me, pricing, notes, billing],
    edges: [
      LoopEdge(from: pricing.id, to: me.id),
      LoopEdge(from: me.id, to: notes.id),
      LoopEdge(from: billing.id, to: me.id, kind: .message),
    ])

  @Test
  func theContextStripReadsFromBesideTo() {
    let context = NodGraphContext(nodeID: Self.me.id, in: Self.graph)
    #expect(context.from.map(\.title) == ["Pricing"])
    #expect(context.to.map(\.title) == ["ReleaseNotes"])
    #expect(context.beside.map(\.title) == ["BillingUI"])
    #expect(!context.isEmpty)
  }

  @Test
  func theContextStripCollapsesWithNoEdges() {
    let lone = LoopNode(title: "Lone", loopType: .sketch)
    #expect(NodGraphContext(nodeID: lone.id, in: NodForkTests.graph([lone, Self.me])).isEmpty)
  }

  @Test
  func handoffGoesDownstreamOrToTheNamedLoop() throws {
    let downstream = try NodGraphVerb.parse("/handoff 402 body is { limit, resetsAt }").get()
    #expect(downstream == .handoff(target: nil, brief: "402 body is { limit, resetsAt }"))
    #expect(
      try downstream.commands(from: Self.me.id, in: Self.graph).get() == [
        .messageNode(
          Self.notes.id, text: "Handoff: 402 body is { limit, resetsAt }", from: Self.me.id,
          followUp: true)
      ])

    let named = try NodGraphVerb.parse("/handoff @billing check the 402").get()
    #expect(
      try named.commands(from: Self.me.id, in: Self.graph).get().first
        == .messageNode(
          Self.billing.id, text: "Handoff: check the 402", from: Self.me.id, followUp: true))
  }

  @Test
  func handoffRefusesWhatItCannotDeliver() throws {
    #expect(
      try NodGraphVerb.parse("/handoff brief").get().commands(from: Self.notes.id, in: Self.graph)
        == .failure(.noDownstream))
    #expect(
      try NodGraphVerb.parse("/handoff @Nobody x").get().commands(from: Self.me.id, in: Self.graph)
        == .failure(.unknownLoop("Nobody")))
    #expect(
      try NodGraphVerb.parse("/handoff").get().commands(from: Self.me.id, in: Self.graph)
        == .failure(.emptyBrief))
  }

  @Test
  func askMessagesASibling() throws {
    let ask = try NodGraphVerb.parse("/ask @BillingUI does the banner read the 402?").get()
    #expect(
      try ask.commands(from: Self.me.id, in: Self.graph).get() == [
        .messageNode(
          Self.billing.id, text: "does the banner read the 402?", from: Self.me.id, followUp: true)
      ])
    #expect(NodGraphVerb.parse("/ask nobody") == .failure(.usage(NodGraphVerb.askUsage)))
  }

  @Test
  func promoteGivesAMainLoopAShape() throws {
    let sketch = LoopNode(title: "Spike", loopType: .sketch)
    let graph = NodForkTests.graph([sketch, Self.notes])
    let goal = try NodGraphVerb.parse("/promote goal every route is capped").get()
    #expect(
      try goal.commands(from: sketch.id, in: graph).get() == [
        .promoteNode(
          sketch.id, promotion: .goal(GoalSpec(summary: "every route is capped")), promotedBy: nil)
      ])
    #expect(
      try NodGraphVerb.parse("/promote turn writes").get()
        == .promote(.turn(pausesBeforeWritesOnly: true)))
    #expect(
      try NodGraphVerb.parse("/promote timed /loop 1h check").get()
        == .promote(.timed(triggerPrompt: "/loop 1h check")))
    #expect(NodGraphVerb.parse("/promote goal") == .failure(.usage(NodGraphVerb.promoteUsage)))
    #expect(
      try goal.commands(from: Self.notes.id, in: graph) == .failure(.notASketch))
    #expect(NodGraphVerb.parse("/plan") == .failure(.notAGraphVerb))
  }
}

@Suite
struct NodInboundMailTests {
  static func message(_ text: String, from: UUID? = nil) -> NodEvent.UserMessage {
    NodEvent.UserMessage(id: "u1", text: text, delivery: .queue, attachments: [], fromNodeID: from)
  }

  @Test
  func aSiblingsQuestionIsMail() throws {
    let mail = try #require(
      NodInboundMail.classify(
        Self.message("[graphcode] BillingUI: What does /export return over the cap?"),
        nodeID: NodGraphVerbTests.me.id, in: NodGraphVerbTests.graph))
    #expect(mail.kind == .mail)
    #expect(mail.sender?.id == NodGraphVerbTests.billing.id)
    #expect(mail.body == "What does /export return over the cap?")
    #expect(mail.isQuestion)
    #expect(
      mail.answerCommand(from: NodGraphVerbTests.me.id, text: "402")
        == .messageNode(
          NodGraphVerbTests.billing.id, text: "402", from: NodGraphVerbTests.me.id, followUp: true))
  }

  @Test
  func anUpstreamLoopFinishingIsAHandoff() throws {
    let edgeFired = try #require(
      NodInboundMail.classify(
        Self.message("[graphcode] Pricing: Free tier is 50 exports a month."),
        nodeID: NodGraphVerbTests.me.id, in: NodGraphVerbTests.graph))
    #expect(edgeFired.kind == .handoff)
    let bare = try #require(
      NodInboundMail.classify(
        Self.message("[graphcode] Pricing finished."), nodeID: NodGraphVerbTests.me.id,
        in: NodGraphVerbTests.graph))
    #expect(bare.kind == .handoff && bare.body.isEmpty)
    let named = try #require(
      NodInboundMail.classify(
        Self.message(
          "[graphcode] BillingUI: Handoff: banner done", from: NodGraphVerbTests.billing.id),
        nodeID: NodGraphVerbTests.me.id, in: NodGraphVerbTests.graph))
    #expect(named.kind == .handoff && named.body == "banner done")
  }

  @Test
  func humanTypingAndDaemonNoticesAreNotMail() {
    let graph = NodGraphVerbTests.graph
    #expect(
      NodInboundMail.classify(
        Self.message("fix /export"), nodeID: NodGraphVerbTests.me.id, in: graph) == nil)
    #expect(
      NodInboundMail.classify(
        Self.message("[graphcode] Stop requested from the graph."), nodeID: NodGraphVerbTests.me.id,
        in: graph) == nil)
  }

  @Test
  func theNewestDraftForTheMessageWins() throws {
    let mail = try #require(
      NodInboundMail.classify(
        Self.message("[graphcode] BillingUI: what status?"), nodeID: NodGraphVerbTests.me.id,
        in: NodGraphVerbTests.graph))
    let to = NodGraphVerbTests.billing.id
    let events: [NodEvent] = [
      .mailDraft(.init(draftID: "d1", toNodeID: to, inReplyTo: "u1", text: "402")),
      .mailDraft(.init(draftID: "d2", toNodeID: to, inReplyTo: "other", text: "no")),
      .mailDraft(
        .init(draftID: "d3", toNodeID: to, inReplyTo: "u1", text: "402 { limit, resetsAt }")),
    ]
    #expect(mail.draft(in: events)?.draftID == "d3")
  }
}

@Suite
struct NodHandoffOfferTests {
  static let met = NodEvent.GoalCheck(
    turn: 4, evaluatorModel: "haiku",
    clauses: [
      NodGoalClause(
        text: "Every paid route goes through UsageGate", met: true,
        evidence: "4 of 4 paid routes capped"),
      NodGoalClause(text: "swift test passes", met: true, evidence: "31 tests pass"),
    ], met: true)

  @Test
  func offeredWhenTheGoalHoldsAndSomethingIsDownstream() throws {
    let offer = try #require(
      NodHandoffOffer.make(
        check: Self.met, nodeID: NodGraphVerbTests.me.id, in: NodGraphVerbTests.graph,
        summaries: ["Moved /export into the paid group."]))
    #expect(offer.targets.map(\.title) == ["ReleaseNotes"])
    #expect(offer.evidence == ["4 of 4 paid routes capped", "31 tests pass"])
    #expect(offer.suggestedBrief == "Moved /export into the paid group.")
    #expect(
      offer.commands(brief: "Moved /export.\nTests added.") == [
        .messageNode(
          NodGraphVerbTests.notes.id, text: "Handoff: Moved /export.\nTests added.",
          from: NodGraphVerbTests.me.id, followUp: true),
        .completeNode(NodGraphVerbTests.me.id, result: "Moved /export.", from: nil),
      ])
  }

  @Test
  func notOfferedUnmetOrWithNothingDownstream() {
    var unmet = Self.met
    unmet.met = false
    #expect(
      NodHandoffOffer.make(
        check: unmet, nodeID: NodGraphVerbTests.me.id, in: NodGraphVerbTests.graph) == nil)
    #expect(
      NodHandoffOffer.make(
        check: Self.met, nodeID: NodGraphVerbTests.notes.id, in: NodGraphVerbTests.graph) == nil)
  }
}

@Suite
struct NodEditablePlanTests {
  static var plan: NodEditablePlan {
    NodEditablePlan(
      planID: "p1", title: "Usage caps", steps: NodCompositeGroupingTests.usageCapSteps)
  }

  @Test
  func rewritingAStepMakesItTheHumans() {
    var plan = Self.plan
    plan.rewrite(stepID: "1", to: "  Move /export behind UsageGate  ")
    #expect(!plan.steps[0].editedByHuman)
    plan.rewrite(stepID: "1", to: "Move /export and /share behind UsageGate")
    #expect(plan.steps[0].editedByHuman)
    #expect(plan.steps[0].text == "Move /export and /share behind UsageGate")
  }

  @Test
  func dragReordersAndDeleteDrops() {
    var plan = Self.plan
    plan.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(plan.steps.map(\.id) == ["3", "1", "2", "4"])
    plan.move(fromOffsets: IndexSet([0, 1]), toOffset: 4)
    #expect(plan.steps.map(\.id) == ["2", "4", "3", "1"])
    plan.remove(stepID: "4")
    #expect(plan.steps.map(\.id) == ["2", "3", "1"])
  }

  @Test
  func addedStepsAreHumansAndTheCompositeCountFollowsEdits() {
    var plan = Self.plan
    #expect(plan.compositeLoopCount == 2)
    plan.add("Docs for the 402")
    #expect(plan.steps.last?.editedByHuman == true)
    plan.steps[plan.steps.count - 1].files = ["docs/billing.md"]
    #expect(plan.compositeLoopCount == 3)
    plan.toggleDoneCheck(stepID: "3")
    #expect(plan.compositeLoopCount == 2)
    #expect(
      plan.runCommand(.composite)
        == .runPlan(.init(planID: "p1", steps: plan.steps, mode: .composite)))
  }
}

@Suite
struct NodProtocolGraphLayerTests {
  @Test
  func aPlanStepWithoutDoneCheckDecodesAsNotOne() throws {
    let json = #"{"id":"1","text":"a","files":[],"editedByHuman":false}"#
    let step = try JSONDecoder().decode(NodPlanStep.self, from: Data(json.utf8))
    #expect(!step.doneCheck)
    let done = try JSONDecoder().decode(
      NodPlanStep.self, from: Data(#"{"id":"1","text":"a","doneCheck":true}"#.utf8))
    #expect(done.doneCheck && done.files.isEmpty && !done.editedByHuman)
  }

  @Test
  func aBriefRoundTripsInTheAgreedEncoding() throws {
    let brief = NodBrief(
      kind: .fork, fromNodeID: UUID(), text: "t",
      fork: .init(conversationID: "c", messageID: "m"))
    let data = try NodProtocol.makeEncoder().encode(brief)
    #expect(try NodProtocol.makeDecoder().decode(NodBrief.self, from: data) == brief)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["v"] as? Int == NodProtocol.version)
    #expect(object["kind"] as? String == "fork")
  }
}
