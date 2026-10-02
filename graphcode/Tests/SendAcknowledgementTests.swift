import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// `node send` exiting 75 for a message that landed. The daemon used to type the whole
/// message — a `zmx ls` gate over every session, each chunk, the submit beat, Enter —
/// before it acknowledged the request, and on a starved machine that outlasted the CLI's
/// ten-second wait. The acknowledgement now comes once the message is on the board and
/// queued for its session; the typing follows.
@Suite
struct SendAcknowledgementTests {
  private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      guard !opened else { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
      opened = true
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
  }

  private static func graph() -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/send-ack", name: "send-ack"),
      nodes: [
        LoopNode(
          title: "Worker", loopType: .goalBased, goal: GoalSpec(summary: "work"),
          state: .running)
      ])
  }

  @Test
  func aSendIsAcknowledgedBeforeItIsTyped() async {
    let events = LockIsolated<[String]>([])
    let graph = Self.graph()
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, text, _ in
        try? await Task.sleep(for: .milliseconds(200))
        events.withValue { $0.append("typed \(text)") }
        return true
      },
      onAppendMemory: { _, _ in })

    let result = await store.handle(
      .messageNode(graph.nodes[0].id, text: "the API changed", from: nil, followUp: nil))
    events.withValue { $0.append("acknowledged") }
    await store.finishSessionTyping()

    guard case .applied = result else {
      Issue.record("expected the send to be acknowledged, got \(result)")
      return
    }
    #expect(events.value == ["acknowledged", "typed [graphcode] the API changed"])
  }

  // Bounded: typed before the acknowledgement, the gate below is never opened.
  @Test(.timeLimit(.minutes(1)))
  func sendsToOneLoopAreTypedInTheOrderTheyWereSent() async {
    let gate = Gate()
    let typed = LockIsolated<[String]>([])
    let graph = Self.graph()
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, text, _ in
        if text.hasSuffix("first") { await gate.wait() }
        typed.withValue { $0.append(text) }
        return true
      },
      onAppendMemory: { _, _ in })
    let nodeID = graph.nodes[0].id

    await store.handle(.messageNode(nodeID, text: "first", from: nil, followUp: nil))
    await store.handle(.messageNode(nodeID, text: "second", from: nil, followUp: nil))
    await gate.open()
    await store.finishSessionTyping()

    #expect(typed.value == ["[graphcode] first", "[graphcode] second"])
  }

  // Bounded: typed before the acknowledgement, the gate below is never opened.
  @Test(.timeLimit(.minutes(1)))
  func aFollowUpWaitsBehindASendStillBeingTyped() async {
    let gate = Gate()
    let typed = LockIsolated<[String]>([])
    let graph = Self.graph()
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, text, _ in
        if text.hasSuffix("now") { await gate.wait() }
        typed.withValue { $0.append(text) }
        return true
      },
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
      onAppendMemory: { _, _ in })
    let nodeID = graph.nodes[0].id

    await store.handle(.messageNode(nodeID, text: "now", from: nil, followUp: nil))
    await store.handle(.messageNode(nodeID, text: "later", from: nil, followUp: true))
    #expect(typed.value.isEmpty)
    await gate.open()
    await store.finishSessionTyping()

    #expect(typed.value == ["[graphcode] now", "[graphcode] later"])
  }

  @Test
  func aSendThatCannotBeTypedIsStagedWithoutAnErrorForOtherClients() async {
    let remembered = LockIsolated<[String]>([])
    var graph = Self.graph()
    graph.nodes[0].loopType = .turnBased
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, _, _ in false },
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })

    let result = await store.handle(
      .messageNode(graph.nodes[0].id, text: "wake up", from: nil, followUp: nil))
    await store.finishSessionTyping()

    guard case .applied = result else {
      Issue.record("expected the send to be acknowledged, got \(result)")
      return
    }
    #expect(remembered.value == ["while you were away: [graphcode] wake up"])
    // The failure is learned after the acknowledgement; an announced error would be the
    // verdict of whichever command ran next, not this one.
    let next = await store.handle(.memoNode(graph.nodes[0].id, text: "note", from: nil))
    guard case .applied = next else {
      Issue.record("an unrelated command inherited the send's failure: \(next)")
      return
    }
  }
}

/// One `zmx ls` per presence pass, shared with sends, instead of one per node per read.
@Suite
struct SessionListingTests {
  private static let listing = ZmxSessionLauncher.ZmxResult(
    status: 0, output: "name=graphcode-A\tpid=1\tclients=0\n")

  @Test
  func concurrentReadersShareOneListing() async {
    let listing = ZmxSessionLauncher.SessionListing(reuseWindow: .zero) {
      try? await Task.sleep(for: .milliseconds(100))
      return Self.listing
    }

    let results = await withTaskGroup(of: ZmxSessionLauncher.ZmxResult?.self) { group in
      for _ in 0..<20 { group.addTask { await listing.listing() } }
      return await group.reduce(into: []) { $0.append($1) }
    }

    #expect(results.allSatisfy { $0 == Self.listing })
    #expect(await listing.listingsTaken == 1)
  }

  @Test
  func aPassTakesOneListingHoweverManyReadsItMakes() async {
    let listing = ZmxSessionLauncher.SessionListing(reuseWindow: .zero) { Self.listing }

    await listing.beginPass()
    for _ in 0..<27 { _ = await listing.listing() }
    await listing.endPass()

    #expect(await listing.listingsTaken == 1)
  }

  @Test
  func outsideAPassAListingOlderThanTheWindowIsRetaken() async {
    let listing = ZmxSessionLauncher.SessionListing(reuseWindow: .zero) { Self.listing }

    _ = await listing.listing()
    try? await Task.sleep(for: .milliseconds(5))
    _ = await listing.listing()

    #expect(await listing.listingsTaken == 2)
  }

  @Test
  func aSessionStartedOrKilledInvalidatesTheListing() async {
    let listing = ZmxSessionLauncher.SessionListing(reuseWindow: .seconds(60)) { Self.listing }

    await listing.beginPass()
    _ = await listing.listing()
    await listing.noteChanged()
    _ = await listing.listing()
    _ = await listing.listing()
    await listing.endPass()

    #expect(await listing.listingsTaken == 2)
  }

  @Test
  func aFreshListingIsNeverAnsweredByAnEarlierOne() async {
    // A send that found its target missing confirms it against a listing of its own: the
    // shared one may predate a session a human's pane has just started.
    let listing = ZmxSessionLauncher.SessionListing(reuseWindow: .seconds(60)) { Self.listing }

    _ = await listing.listing()
    _ = await listing.listing()
    _ = await listing.listing(fresh: true)

    #expect(await listing.listingsTaken == 2)
  }

  @Test
  func aFailedListingIsSharedRatherThanRetriedPerNode() async {
    let listing = ZmxSessionLauncher.SessionListing(reuseWindow: .zero) { nil }

    await listing.beginPass()
    let first = await listing.listing()
    let second = await listing.listing()
    await listing.endPass()

    #expect(first == nil && second == nil)
    #expect(await listing.listingsTaken == 1)
  }
}

@Suite
struct RunCollectingOutputTests {
  @Test
  func collectsMoreOutputThanAPipeHoldsAndTheExitStatus() async {
    let result = await ZmxSessionLauncher.runCollectingOutput(
      URL(fileURLWithPath: "/bin/sh"),
      ["-c", "head -c 200000 /dev/zero | tr '\\000' x; exit 3"])

    #expect(result?.status == 3)
    #expect(result?.output.count == 200_000)
  }

  @Test
  func aMissingExecutableIsNil() async {
    let result = await ZmxSessionLauncher.runCollectingOutput(
      URL(fileURLWithPath: "/nonexistent/zmx"), ["ls"])

    #expect(result == nil)
  }
}

/// Issue #215 through the shared listing: a husk — a session whose task has ended, its
/// wrapper shell still at the prompt — is never typed into. `zmx ls` marks one with
/// `ended=`/`exit_code=`, and the listing everyone else shares can be older than the end.
@Suite
struct HuskSendGateTests {
  private static let node = LoopNode(title: "Worker")
  private static var name: String {
    SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
  }
  private static var live: String { "name=\(name)\tpid=1\tclients=0\tcmd=claude\n" }
  private static var husk: String {
    "name=\(name)\tpid=1\tclients=0\tcmd=claude\tended=1790000000\texit_code=0\n"
  }

  private static func listing(_ outputs: [String]) -> ZmxSessionLauncher.SessionListing {
    let remaining = LockIsolated(outputs)
    return ZmxSessionLauncher.SessionListing(reuseWindow: .seconds(60)) {
      let output = remaining.withValue { $0.count > 1 ? $0.removeFirst() : $0[0] }
      return ZmxSessionLauncher.ZmxResult(status: 0, output: output)
    }
  }

  @Test
  func aLiveSessionPassesTheGate() async {
    #expect(await ZmxSessionLauncher.sendGate(Self.node, listing: Self.listing([Self.live])))
  }

  @Test(arguments: [
    "\tended=1790000000\texit_code=0", "\tended=1790000000", "\texit_code=137",
  ])
  func aHuskAtListingTimeIsNeverTypedInto(marker: String) async {
    let row = "name=\(Self.name)\tpid=1\tclients=0\tcmd=claude\(marker)\n"

    #expect(!(await ZmxSessionLauncher.sendGate(Self.node, listing: Self.listing([row]))))
  }

  @Test
  func aSessionThatEndsAfterTheSharedListingIsNeverTypedInto() async {
    let listing = Self.listing([Self.live, Self.husk])
    // A presence pass has the session alive in the shared listing; the task then ends.
    await listing.beginPass()
    let shared = await listing.listing()
    #expect(shared?.output == Self.live)

    let typed = await ZmxSessionLauncher.sendGate(Self.node, listing: listing)
    await listing.endPass()

    #expect(!typed)
    #expect(await listing.listingsTaken == 2)
  }
}
