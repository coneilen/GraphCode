import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

@Suite
struct NodTranscriptTests {
  @Test
  func aMessageSentWhileIdleBecomesThePromptWhicheverRecordComesFirst() {
    var before = NodLog()
    before.session()
    before.user("fix the cap", id: "u1")
    before.turn(1)
    #expect(before.transcript.turns.map(\.prompt?.text) == ["fix the cap"])
    #expect(before.transcript.queued.isEmpty)

    var after = NodLog()
    after.session()
    after.turn(1)
    after.user("fix the cap", id: "u1")
    #expect(after.transcript.turns.map(\.prompt?.text) == ["fix the cap"])
    #expect(after.transcript.queued.isEmpty)
  }

  @Test
  func deltasWithOneMessageIDConcatenate() {
    var log = NodLog()
    log.turn(1)
    log.say("Found ", turn: 1, id: "m1", final: false)
    log.say("it.", turn: 1, id: "m1", final: true)
    log.say("Next.", turn: 1, id: "m2", final: false)

    let items = log.transcript.turns[0].items
    #expect(items.count == 2)
    guard case .text(let first) = items[0], case .text(let second) = items[1] else {
      Issue.record("expected two text items, got \(items)")
      return
    }
    #expect(first == .init(id: "m1", text: "Found it.", isFinal: true))
    #expect(second == .init(id: "m2", text: "Next.", isFinal: false))
  }

  @Test
  func aToolResultLandsOnItsCall() {
    var log = NodLog()
    log.turn(1)
    log.tool("c1", turn: 1, tool: "Bash", title: "swift test", status: nil)
    #expect(log.transcript.turns[0].items.toolCards.map(\.status) == [.running])

    log.add("toolResult", ["callID": "c1", "status": "error", "summary": "exit 1"])
    let card = log.transcript.turns[0].items.toolCards[0]
    #expect(card.status == .error)
    #expect(card.result?.summary == "exit 1")
  }

  @Test
  func aQueuedMessageWaitsForTheTurnItStarts() {
    var log = NodLog()
    log.user("first", id: "u1")
    log.turn(1)
    log.user("second", id: "u2")
    #expect(log.transcript.queued.map(\.text) == ["second"])
    #expect(log.transcript.currentTurn?.number == 1)

    log.endTurn(1)
    log.turn(2, origin: "queue")
    let transcript = log.transcript
    #expect(transcript.queued.isEmpty)
    #expect(transcript.turns.map(\.prompt?.text) == ["first", "second"])
  }

  @Test
  func aSteerLandsInTheRunningTurn() {
    var log = NodLog()
    log.user("first", id: "u1")
    log.turn(1)
    log.tool("c1", turn: 1, tool: "Edit", title: "Edit UsageCapTests.swift")
    log.user("use the fixture clock", id: "u2", delivery: "steer")

    let transcript = log.transcript
    #expect(transcript.queued.isEmpty)
    guard case .steer(let steer) = transcript.turns[0].items.last else {
      Issue.record("expected a steer item")
      return
    }
    #expect(steer.text == "use the fixture clock")
  }

  @Test
  func hunksAreStagedUntilResolvedAndAutoAcceptedOnesReadAsAccepted() {
    var log = NodLog()
    log.turn(1)
    log.hunk("h1", turn: 1, file: "A.swift", header: "@@ 1,3 @@", diff: "+a", added: 1, removed: 0)
    log.hunk(
      "h2", turn: 1, file: "B.swift", header: "@@ 1,3 @@", diff: "+b", added: 1, removed: 0,
      auto: true)
    #expect(log.transcript.turns[0].items.hunkCards.map(\.decision) == [nil, .accept])

    log.add("hunkResolved", ["hunkID": "h1", "decision": "comment", "note": "use 51"])
    let cards = log.transcript.turns[0].items.hunkCards
    #expect(cards[0].decision == .comment)
    #expect(cards[0].resolution?.note == "use 51")
  }

  @Test
  func anOpenAskIsNeedsYouUntilResolved() {
    var log = NodLog()
    log.turn(1)
    log.ask("a1", subject: "swift package resolve", reason: "network")
    #expect(log.transcript.openAsks.map(\.askID) == ["a1"])

    log.add("permissionResolved", ["askID": "a1", "decision": "allowOnce"])
    #expect(log.transcript.openAsks.isEmpty)
  }

  @Test
  func theGoalHeaderCountsChecksAndShowsTheLatest() {
    var log = NodLog()
    #expect(NodChatPresentation.goalVerdict(for: log.transcript) == .unchecked)
    log.turn(1)
    log.goalCheck(turn: 1, met: false, clauses: [("routes", true, nil), ("tests", false, nil)])
    log.turn(2, origin: "goalCheck")
    log.goalCheck(turn: 2, met: false, clauses: [("routes", true, nil), ("tests", false, nil)])
    #expect(NodChatPresentation.goalVerdict(for: log.transcript) == .notYet(checks: 2))
    #expect(
      NodChatPresentation.verdictLabel(.notYet(checks: 2)) == "not yet · checked 2×")

    log.goalCheck(turn: 2, met: true, clauses: [("routes", true, nil), ("tests", true, nil)])
    #expect(
      NodChatPresentation.goalVerdict(for: log.transcript) == .holds(metClauses: 2, of: 2))
  }

  @Test
  func costSumsPerCallAndCopilotShowsPremiumRequests() {
    var claude = NodLog()
    claude.session()
    claude.usage(cost: 0.25, context: 0.1)
    claude.usage(cost: 0.5, context: 0.2)
    #expect(NodChatPresentation.costLabel(for: claude.transcript) == "$0.75")

    var copilot = NodLog()
    copilot.session(model: "gpt-5", engine: "copilot")
    copilot.usage(premium: 1, context: 0.1)
    copilot.usage(premium: 2, context: 0.1)
    #expect(NodChatPresentation.costLabel(for: copilot.transcript) == "3 premium")
  }

  @Test
  func bannersFollowFailuresAndClearWhenTheirCauseDoes() {
    var log = NodLog()
    log.session()
    log.turn(1)
    log.usage(cost: 0.1, context: 0.5)
    #expect(NodChatPresentation.banner(for: log.transcript) == nil)

    log.usage(cost: 0.1, context: 0.82)
    #expect(NodChatPresentation.banner(for: log.transcript) == .contextNearlyFull(percent: 82))

    log.failure("spendCap", "Nightly deps hit its $2.00 cap this run.")
    #expect(
      NodChatPresentation.banner(for: log.transcript)
        == .spendCap("Nightly deps hit its $2.00 cap this run."))
    log.turn(2)
    #expect(NodChatPresentation.banner(for: log.transcript) == .contextNearlyFull(percent: 82))

    log.failure("contextFull", "full")
    log.add("compacted", ["fromTurn": 1, "throughTurn": 1])
    log.usage(cost: 0.1, context: 0.3)
    #expect(NodChatPresentation.banner(for: log.transcript) == nil)
    #expect(log.transcript.turns.map(\.isCompacted) == [true, false])

    log.failure("signInExpired", "Copilot sign-in expired.")
    #expect(
      NodChatPresentation.banner(for: log.transcript) == .signInExpired("Copilot sign-in expired."))
    log.session()
    #expect(NodChatPresentation.banner(for: log.transcript) == nil)
  }

  @Test
  func replayedRecordsAreDroppedButANewRunStartsItsOwnSequence() {
    var log = NodLog()
    log.session()
    log.turn(1)
    log.say("once", turn: 1, id: "m1", final: false)

    var transcript = log.transcript
    for record in log.records { transcript.apply(record) }
    guard case .text(let message) = transcript.turns[0].items[0] else {
      Issue.record("expected text")
      return
    }
    #expect(message.text == "once")

    // A resumed runtime opens a new run whose seq starts again at 1.
    var resumed = NodLog(after: log)
    resumed.session()
    resumed.turn(2)
    for record in resumed.records { transcript.apply(record) }
    #expect(transcript.turns.map(\.number) == [1, 2])
    #expect(transcript.turns[0].wasInterrupted)
    #expect(transcript.currentTurn?.number == 2)
  }

  @Test
  func unknownEventsAreSkipped() {
    var log = NodLog()
    log.turn(1)
    log.add("somethingNewer", ["x": 1])
    log.say("still here", turn: 1, id: "m1")
    #expect(log.transcript.turns[0].items.count == 1)
  }

  @Test
  func aTurnPastFiveToolCallsFoldsThemIntoOneWorkBlock() {
    var log = NodLog()
    log.turn(1)
    log.say("Looking.", turn: 1, id: "m1")
    for index in 1...3 {
      log.tool("r\(index)", turn: 1, tool: "Read", title: "Read F\(index).swift", ms: 100)
    }
    log.tool("s1", turn: 1, tool: "Grep", title: "Search \"x\"", ms: 100)
    log.tool("e1", turn: 1, tool: "Bash", title: "swift build", status: "error", summary: "exit 1")
    log.hunk("h1", turn: 1, file: "A.swift", header: "@@", diff: "+a", added: 1, removed: 0)
    log.tool("e2", turn: 1, tool: "Edit", title: "Edit A.swift", ms: 100)
    log.tool("b1", turn: 1, tool: "Bash", title: "swift test", status: nil)

    let blocks = NodChatPresentation.blocks(for: log.transcript.turns[0])
    #expect(blocks.map(\.id) == ["text:m1", "work:1", "tool:e1", "hunk:h1"])
    guard case .work(let work) = blocks[1] else {
      Issue.record("expected the work block second")
      return
    }
    #expect(work.tools.map(\.call.callID) == ["r1", "r2", "r3", "s1", "e2", "b1"])
    #expect(work.line == "read 3 · searched 1 · edited 1 · ran 1")
    #expect(work.running?.call.callID == "b1")
    #expect(work.durationMs == 500)
  }

  @Test
  func fiveToolCallsStayUnfolded() {
    var log = NodLog()
    log.turn(1)
    for index in 1...5 {
      log.tool("r\(index)", turn: 1, tool: "Read", title: "Read F\(index).swift")
    }
    let blocks = NodChatPresentation.blocks(for: log.transcript.turns[0])
    #expect(blocks.count == 5)
    #expect(!blocks.contains { if case .work = $0 { return true } else { return false } })
  }

  @Test
  func theDesignScenarioFoldsToTwoTurnsWithAQueuedNote() {
    let transcript = NodLog.monetization.transcript
    #expect(transcript.session?.engine == .claudeAgentSDK)
    #expect(transcript.turns.map(\.number) == [1, 2])
    #expect(transcript.turns[0].ended?.filesChanged == 1)
    #expect(transcript.currentTurn?.number == 2)
    #expect(transcript.queued.map(\.text) == ["also log when a request is blocked"])
    #expect(transcript.openAsks.map(\.askID) == ["a1"])
    #expect(transcript.activity == "Running swift test --filter UsageCap · 14s")
    #expect(transcript.lastGoalCheck?.clauses.count == 2)
  }
}

extension [NodTranscript.Item] {
  var toolCards: [NodTranscript.ToolCard] {
    compactMap { if case .tool(let card) = $0 { return card } else { return nil } }
  }

  var hunkCards: [NodTranscript.HunkCard] {
    compactMap { if case .hunk(let card) = $0 { return card } else { return nil } }
  }
}

@Suite
struct NodEventTailTests {
  /// The runtime's launcher names the directory with `uuidString` as is; a lowercased copy
  /// would split the pane from the runtime on a case-sensitive volume.
  @Test
  func theStateDirectoryIsTheUppercaseNodeID() throws {
    let id = try #require(UUID(uuidString: "9b3408f9-9b16-447f-a439-fc2aa8c02d06"))
    let url = NodStateDirectory.url(forNode: id, supportDirectory: URL(fileURLWithPath: "/s"))
    #expect(url.path == "/s/nod/9B3408F9-9B16-447F-A439-FC2AA8C02D06")
  }

  @Test
  func aTornLineWaitsForTheRestOfIt() throws {
    let lines = NodLog.monetization.jsonLines
    let cut = lines.count - 20
    var tail = NodEventTail()
    let first = tail.consume(lines.prefix(cut))
    let second = tail.consume(lines.suffix(from: cut))
    #expect(first.count + second.count == NodLog.monetization.records.count)
    #expect(second.count == 1)
    #expect(tail.offset == UInt64(lines.count))
  }

  @Test
  func resetStartsOverFromTheTop() {
    var tail = NodEventTail()
    _ = tail.consume(Data("{\"partial".utf8))
    tail.reset()
    #expect(tail.offset == 0)
    #expect(tail.consume(NodLog.monetization.jsonLines).count == NodLog.monetization.records.count)
  }
}

@Suite
struct NodComposerMenuTests {
  @Test
  func slashOpensOnlyAtTheStartAndAtSignAfterWhitespace() {
    #expect(NodComposerTrigger.detect(in: "/com") == .slash("com"))
    #expect(NodComposerTrigger.detect(in: "/compact now") == nil)
    #expect(NodComposerTrigger.detect(in: "check that @bi") == .mention("bi"))
    #expect(NodComposerTrigger.detect(in: "@") == .mention(""))
    #expect(NodComposerTrigger.detect(in: "mail me@host") == nil)
    #expect(NodComposerTrigger.detect(in: "@Billing done") == nil)
    #expect(NodComposerTrigger.detect(in: "plain") == nil)
  }

  @Test
  func slashCommandsFilterByPrefixAndKeepTheirGroups() {
    #expect(NodSlashCommand.matching("").count == 7)
    #expect(NodSlashCommand.matching("p").map(\.name) == ["plan", "promote"])
    #expect(NodSlashCommand.matching("ha").map(\.group) == [.graph])
  }

  @Test
  func aRunningLoopIsMessagedAndAFinishedOneAttached() {
    let running = NodMention(
      title: "Billing UI", kind: .loop(id: UUID(), isRunning: true, detail: "Turn · running"))
    let done = NodMention(
      title: "Billing migration", kind: .loop(id: UUID(), isRunning: false, detail: "done 3d"))
    #expect(running.defaultActionLabel == "message")
    #expect(done.defaultActionLabel == "attach")
    #expect(NodMention.matching("bi", in: [running, done]).count == 2)
    #expect(NodMention.matching("mig", in: [running, done]) == [done])
  }

  @Test
  func modelLabelsAreFamilyNames() {
    #expect(NodChatPresentation.modelLabel("claude-sonnet-4-5") == "Sonnet")
    #expect(NodChatPresentation.modelLabel("haiku") == "Haiku")
    #expect(NodChatPresentation.modelLabel("gpt-5") == "GPT-5")
    #expect(NodChatPresentation.modelLabel("gemini-2.5-pro") == "gemini-2.5-pro")
  }
}
