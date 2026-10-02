import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

private actor CommandSink {
  private(set) var commands: [NodCommand] = []
  func append(_ command: NodCommand) { commands.append(command) }
}

@MainActor
@Suite
struct NodChatFeatureTests {
  private static let directory = URL(fileURLWithPath: "/tmp/nod-test")

  private func makeStore(
    log: NodLog = NodLog(), sink: CommandSink = CommandSink(),
    send: (@Sendable (NodCommand) async throws -> Void)? = nil
  ) -> TestStoreOf<NodChatFeature> {
    var state = NodChatFeature.State(
      nodeID: UUID(), stateDirectory: Self.directory, loopTitle: "Monetization",
      loopType: .goalBased, goal: "Done when every paid route enforces the cap")
    state.transcript = log.transcript
    let store = TestStore(initialState: state) {
      NodChatFeature()
    } withDependencies: {
      $0.nodClient.send = { _, command in
        if let send { try await send(command) } else { await sink.append(command) }
      }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func theTailFeedsTheTranscript() async {
    let log = NodLog.monetization
    let store = TestStore(
      initialState: NodChatFeature.State(
        nodeID: UUID(), stateDirectory: Self.directory, loopTitle: "M", loopType: .goalBased)
    ) {
      NodChatFeature()
    } withDependencies: {
      $0.nodClient.events = { directory in
        #expect(directory == Self.directory)
        return AsyncStream { continuation in
          continuation.yield(log.records)
          continuation.finish()
        }
      }
    }
    store.exhaustivity = .off
    await store.send(.task)
    await store.receive(\.eventsReceived)
    #expect(store.state.transcript == log.transcript)
  }

  @Test
  func returnQueuesAndCommandReturnSteersWithTheAttachments() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)
    let file = NodAttachment(kind: .file, reference: "/repo/UsageGate.swift")

    await store.send(.attachmentAdded(file))
    await store.send(.draftChanged("  also log blocks  "))
    await store.send(.returnPressed)
    await store.receive(\.commandFinished)
    #expect(store.state.draft == "")
    #expect(store.state.attachments.isEmpty)

    await store.send(.draftChanged("use the fixture clock"))
    await store.send(.commandReturnPressed)
    await store.receive(\.commandFinished)

    #expect(
      await sink.commands == [
        .send(.init(text: "also log blocks", delivery: .queue, attachments: [file])),
        .send(.init(text: "use the fixture clock", delivery: .steer)),
      ])
  }

  @Test
  func anEmptyDraftSendsNothing() async {
    let sink = CommandSink()
    let store = makeStore(sink: sink)
    await store.send(.draftChanged("   "))
    await store.send(.returnPressed)
    #expect(await sink.commands.isEmpty)
  }

  @Test
  func escapeClosesWhatIsOpenBeforeItStopsNod() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)

    await store.send(.forkMenuToggled(messageID: "m1"))
    await store.send(.escapePressed)
    #expect(store.state.forkMenuMessageID == nil)

    await store.send(.draftChanged("/com"))
    await store.send(.escapePressed)
    #expect(store.state.draft == "")
    #expect(await sink.commands.isEmpty)

    await store.send(.escapePressed)
    await store.receive(\.commandFinished)
    #expect(await sink.commands == [.stop])
  }

  @Test
  func escapeWhileIdleStopsNothing() async {
    let sink = CommandSink()
    var log = NodLog()
    log.turn(1)
    log.endTurn(1)
    let store = makeStore(log: log, sink: sink)
    await store.send(.escapePressed)
    #expect(await sink.commands.isEmpty)
  }

  @Test
  func cardDecisionsGoOutAsCommands() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)

    await store.send(.hunkDecided(hunkID: "h1", .accept))
    await store.receive(\.commandFinished)
    await store.send(.permissionDecided(askID: "a1", .alwaysAllow))
    await store.receive(\.commandFinished)
    await store.send(.markGoalDoneTapped)
    await store.receive(\.commandFinished)
    await store.send(.compactNowTapped)
    await store.receive(\.commandFinished)
    await store.send(.forkChosen(messageID: "m1", asSibling: false))
    await store.receive(\.commandFinished)

    #expect(
      await sink.commands == [
        .resolveHunk(.init(hunkID: "h1", decision: .accept)),
        .resolvePermission(.init(askID: "a1", decision: .alwaysAllow)),
        .markGoalDone,
        .compact,
        .fork(.init(messageID: "m1")),
      ])
  }

  @Test
  func aCommentSendsTheHunkBackWithItsNote() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)

    await store.send(.hunkDecided(hunkID: "h1", .comment))
    await store.receive(\.hunkCommentStarted)
    #expect(store.state.commentingHunkID == "h1")
    await store.send(.hunkCommentChanged("use 51 so it's past the cap"))
    await store.send(.hunkCommentSubmitted)
    await store.receive(\.commandFinished)

    #expect(store.state.commentingHunkID == nil)
    #expect(
      await sink.commands == [
        .resolveHunk(.init(hunkID: "h1", decision: .comment, note: "use 51 so it's past the cap"))
      ])
  }

  @Test
  func graphVerbsAndTheGoalGoUpAsDelegates() async {
    let sink = CommandSink()
    let store = makeStore(log: .monetization, sink: sink)

    await store.send(.draftChanged("/handoff Release notes"))
    await store.send(.returnPressed)
    await store.receive(\.delegate.graphCommand)

    await store.send(.draftChanged("/goal"))
    await store.send(.returnPressed)
    await store.receive(\.delegate.editGoal)

    await store.send(.forkChosen(messageID: "m1", asSibling: true))
    await store.receive(\.delegate.forkAsSibling)

    await store.send(.runPlanTapped(planID: "p1", mode: .composite))
    await store.receive(\.delegate.runPlanAsComposite)

    await store.send(.openInShellTabTapped(command: "swift test --filter UsageCap"))
    await store.receive(\.delegate.openInShellTab)

    #expect(await sink.commands.isEmpty)
  }

  @Test
  func slashCompactIsTheCompactCommand() async {
    let sink = CommandSink()
    let store = makeStore(sink: sink)
    await store.send(.draftChanged("/compact"))
    await store.send(.returnPressed)
    await store.receive(\.commandFinished)
    #expect(await sink.commands == [.compact])
  }

  @Test
  func aRunningLoopIsMessagedAndAFinishedOneAttachedWithTabSwapping() async {
    let running = UUID()
    let done = UUID()
    let store = makeStore()

    await store.send(.draftChanged("check that @bi"))
    await store.send(
      .mentionChosen(
        NodMention(title: "Billing UI", kind: .loop(id: running, isRunning: true, detail: "")),
        alternate: false))
    await store.receive(\.delegate.messageLoop)
    #expect(store.state.draft == "check that @Billing UI ")

    await store.send(.draftChanged("@mig"))
    await store.send(
      .mentionChosen(
        NodMention(
          title: "Billing migration", kind: .loop(id: done, isRunning: false, detail: "")),
        alternate: false))
    #expect(
      store.state.attachments == [
        NodAttachment(kind: .loopTranscript, reference: done.uuidString, label: "Billing migration")
      ])

    await store.send(.draftChanged("@bi"))
    await store.send(
      .mentionChosen(
        NodMention(title: "Billing UI", kind: .loop(id: running, isRunning: true, detail: "")),
        alternate: true))
    #expect(store.state.attachments.count == 2)
  }

  @Test
  func aChosenModelShowsOnceTheRuntimeTakesIt() async {
    let store = makeStore(log: .monetization)
    #expect(store.state.model == "claude-sonnet-4-5")
    await store.send(.modelChosen("opus"))
    await store.receive(\.commandFinished)
    #expect(store.state.model == "opus")
  }

  @Test
  func aRefusedCommandShowsItsError() async {
    let store = makeStore(log: .monetization) { _ in
      throw NodControlError.rejected("no such hunk")
    }
    await store.send(.hunkDecided(hunkID: "nope", .accept))
    await store.receive(\.commandFinished)
    #expect(store.state.sendError == "no such hunk")
    await store.send(.errorDismissed)
    #expect(store.state.sendError == nil)
  }

  @Test
  func failedToolCallsOpenOnTheirOwn() {
    var log = NodLog()
    log.turn(1)
    log.tool("ok", turn: 1, tool: "Bash", title: "ls")
    log.tool("bad", turn: 1, tool: "Bash", title: "swift build", status: "error")
    var state = NodChatFeature.State(nodeID: UUID(), loopTitle: "M", loopType: .sketch)
    state.transcript = log.transcript
    let cards = state.transcript.turns[0].items.toolCards
    #expect(cards.map(state.isToolExpanded) == [false, true])
  }
}

@MainActor
@Suite
struct NodWorkspaceWiringTests {
  private final class TypedBox: @unchecked Sendable {
    var typed: [(UUID, String)] = []
  }

  private func workspace(backend: CLISessionBackendKind) -> LoopWorkspaceFeature.State {
    let node = LoopNode(
      title: "Monetization", loopType: .goalBased,
      goal: GoalSpec(summary: "every paid route enforces the cap"), backend: backend)
    return LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: "/tmp/project",
      projectName: "project")
  }

  @Test
  func onlyAChatLoopGetsAChat() async {
    let store = TestStore(initialState: workspace(backend: .claudeCode)) {
      LoopWorkspaceFeature()
    }
    await store.send(.chatSurfaceAppeared)

    let nod = TestStore(initialState: workspace(backend: .nod)) { LoopWorkspaceFeature() }
    nod.exhaustivity = .off
    await nod.send(.chatSurfaceAppeared)
    #expect(nod.state.nodChat?.goal == "every paid route enforces the cap")
    #expect(nod.state.nodChat?.loopType == .goalBased)
    #expect(nod.state.nodChat?.nodeID == nod.state.node.id)
  }

  @Test
  func openInShellTabTypesIntoAPlainShellTabMakingOneIfNeeded() async {
    let box = TypedBox()
    let store = TestStore(initialState: workspace(backend: .nod)) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.terminalLayoutStore = TerminalLayoutStore(
        baseDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString))
      $0.terminalSurfaceClient.typeText = { id, text in box.typed.append((id, text)) }
    }
    store.exhaustivity = .off
    await store.send(.chatSurfaceAppeared)
    let chatTab = store.state.layout.selectedTabID

    await store.send(.nodChat(.delegate(.openInShellTab(command: "swift test"))))
    #expect(store.state.layout.tabs.count == 2)
    let shellTab = store.state.layout.tabs[1]
    #expect(store.state.layout.selectedTabID == shellTab.id)
    #expect(!shellTab.primary.launchesClaudeCode)
    #expect(box.typed.map(\.0) == [shellTab.primary.id])
    #expect(box.typed.map(\.1) == ["swift test"])

    await store.send(.tabSelected(chatTab))
    await store.send(.nodChat(.delegate(.openInShellTab(command: "make lint"))))
    #expect(store.state.layout.tabs.count == 2)
    #expect(store.state.layout.selectedTabID == shellTab.id)
    #expect(box.typed.map(\.1) == ["swift test", "make lint"])
  }
}

@Suite
struct NodControlSocketTests {
  /// A one-shot runtime stand-in: accepts one connection, reads one line, answers `reply`.
  private func serve(reply: String) throws -> (path: String, received: () -> String) {
    let path = "/tmp/nod-\(UUID().uuidString.prefix(8)).sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(bound == 0)
    listen(fd, 1)
    let lock = NSLock()
    nonisolated(unsafe) var received = ""
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      let client = accept(fd, nil, nil)
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = read(client, &buffer, buffer.count)
      lock.lock()
      received = String(decoding: buffer[0..<max(count, 0)], as: UTF8.self)
      lock.unlock()
      let answer = Array((reply + "\n").utf8)
      _ = write(client, answer, answer.count)
      close(client)
      close(fd)
      unlink(path)
      done.signal()
    }
    return (
      path,
      {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return received
      }
    )
  }

  @Test
  func aCommandIsOneLineAndOkIsSuccess() throws {
    let server = try serve(reply: "{\"ok\":true}")
    try NodControlSocket.send(.send(.init(text: "hi", delivery: .steer)), to: server.path)
    let line = server.received()
    #expect(line.hasSuffix("\n"))
    #expect(line.filter { $0 == "\n" }.count == 1)
    let decoded = try NodProtocol.makeDecoder().decode(NodCommand.self, from: Data(line.utf8))
    #expect(decoded == .send(.init(text: "hi", delivery: .steer)))
  }

  @Test
  func aRefusalCarriesTheRuntimesError() throws {
    let server = try serve(reply: "{\"ok\":false,\"error\":\"no such hunk\"}")
    #expect(throws: NodControlError.rejected("no such hunk")) {
      try NodControlSocket.send(.stop, to: server.path)
    }
    _ = server.received()
  }

  @Test
  func noRuntimeIsUnreachableNotAHang() {
    #expect(throws: NodControlError.self) {
      try NodControlSocket.send(.stop, to: "/tmp/nod-missing-\(UUID().uuidString.prefix(8)).sock")
    }
  }
}
