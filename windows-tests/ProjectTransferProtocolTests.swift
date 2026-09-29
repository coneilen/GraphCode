import Foundation
import IdentifiedCollections
import XCTest

@testable import GraphcodeKit

final class ProjectTransferProtocolTests: XCTestCase {
  private func project() -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "C:\\synthetic\\transfer", name: "Transfer"),
      nodes: IdentifiedArrayOf(uniqueElements: [
        LoopNode(title: "Existing", loopType: .turnBased, firstInstruction: "Stay")
      ]))
  }

  private func arriving() -> GraphImportRequest {
    GraphImportRequest(
      snapshot: LoopGraph(
        project: ProjectRef(path: "C:\\synthetic\\source", name: "Source"),
        nodes: IdentifiedArrayOf(uniqueElements: [
          LoopNode(title: "Arriving", loopType: .turnBased, firstInstruction: "Join")
        ])))
  }

  func testDistinctCheckedWireCommandsRoundTrip() throws {
    let token = UUID()
    let graphID = UUID()
    let request = arriving()
    let commands: [DaemonCommand] = [
      .projectSnapshot(path: "C:\\synthetic\\transfer", token: token),
      .validateProjectTransfer(
        path: "C:\\synthetic\\transfer", expectedGraphID: graphID, snapshotToken: token),
      .importProjectChecked(
        path: "C:\\synthetic\\transfer", expectedGraphID: graphID,
        snapshotToken: token, request: request),
    ]
    for command in commands {
      let data = try JSONEncoder().encode(command)
      XCTAssertEqual(try JSONDecoder().decode(DaemonCommand.self, from: data), command)
    }
    let legacy = DaemonCommand.graphCommand(
      projectPath: "C:\\synthetic\\transfer", command: .importNodes(request))
    XCTAssertNotEqual(try JSONEncoder().encode(commands[2]), try JSONEncoder().encode(legacy))
    XCTAssertThrowsError(
      try JSONDecoder().decode(GraphCommand.self, from: JSONEncoder().encode(commands[2])))
  }

  func testSnapshotValidationAndCheckedImportAreConnectionBoundAndSingleUse() async {
    let original = project()
    let store = GraphStore(graph: original)
    let first = ProjectTransferMemoryConnection()
    let second = ProjectTransferMemoryConnection()
    await store.addConnection(id: first.id, connection: first, mode: .v2(version: 2))
    await store.addConnection(id: second.id, connection: second, mode: .v2(version: 2))
    let lease = ProjectTransferLease()
    let activated = await store.activateProjectTransfer(using: lease)
    XCTAssertTrue(activated)
    let token = UUID()
    guard
      case .applied(let snapshot) = await store.snapshotForProjectTransfer(
        connectionID: first.id, token: token)
    else { return XCTFail("Snapshot was refused") }
    XCTAssertEqual(snapshot.id, original.id)
    let unchanged = await store.graph
    let firstFrames = await first.frames
    let secondFrames = await second.frames
    XCTAssertEqual(unchanged.nodes, original.nodes)
    XCTAssertEqual(firstFrames, 1, "Snapshot must not broadcast a change")
    XCTAssertEqual(secondFrames, 1)
    expectRejected(
      await store.validateProjectTransfer(
        expectedGraphID: original.id, snapshotToken: token, connectionID: second.id))
    for _ in 0..<2 {
      guard
        case .applied = await store.validateProjectTransfer(
          expectedGraphID: original.id, snapshotToken: token, connectionID: first.id)
      else { return XCTFail("Validation consumed the token") }
    }
    guard
      case .applied(let merged) = await store.importProjectChecked(
        arriving(), expectedGraphID: original.id, snapshotToken: token, connectionID: first.id)
    else { return XCTFail("Checked import failed") }
    XCTAssertEqual(merged.nodes.count, 2)
    XCTAssertNotNil(merged.nodes[id: original.nodes[0].id])
    expectRejected(
      await store.importProjectChecked(
        arriving(), expectedGraphID: original.id, snapshotToken: token, connectionID: first.id))
    let final = await store.graph
    XCTAssertEqual(final.nodes.count, 2)
    _ = await store.removeConnection(first.id)
    _ = await store.removeConnection(second.id)
    lease.invalidate()
  }

  func testLegacyImportStillWorksButLegacyConnectionCannotTransfer() async {
    let original = project()
    let store = GraphStore(graph: original)
    let channel = ProjectTransferMemoryConnection()
    await store.addConnection(id: channel.id, connection: channel)
    let lease = ProjectTransferLease()
    let activated = await store.activateProjectTransfer(using: lease)
    XCTAssertTrue(activated)
    expectRejected(await store.snapshotForProjectTransfer(connectionID: channel.id, token: UUID()))
    guard case .applied(let updated) = await store.handle(.importNodes(arriving())) else {
      return XCTFail("Legacy import was broken")
    }
    XCTAssertEqual(updated.nodes.count, 2)
    _ = await store.removeConnection(channel.id)
    lease.invalidate()
  }

  func testGraphIdentityAndReconnectionInvalidateSnapshotAuthorization() async {
    let original = project()
    let store = GraphStore(graph: original)
    let channel = ProjectTransferMemoryConnection()
    await store.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let lease = ProjectTransferLease()
    let activated = await store.activateProjectTransfer(using: lease)
    XCTAssertTrue(activated)
    let token = UUID()
    _ = await store.snapshotForProjectTransfer(connectionID: channel.id, token: token)
    expectRejected(
      await store.validateProjectTransfer(
        expectedGraphID: UUID(), snapshotToken: token, connectionID: channel.id))
    expectRejected(
      await store.validateProjectTransfer(
        expectedGraphID: original.id, snapshotToken: UUID(), connectionID: channel.id))
    _ = await store.removeConnection(channel.id)
    let replacement = ProjectTransferMemoryConnection()
    await store.addConnection(id: channel.id, connection: replacement, mode: .v2(version: 2))
    expectRejected(
      await store.importProjectChecked(
        arriving(), expectedGraphID: original.id, snapshotToken: token, connectionID: channel.id))
    _ = await store.removeConnection(channel.id)
    lease.invalidate()
  }

  func testOversizedCheckedResultRejectsWithoutMutationOrBroadcast() async {
    let original = project()
    let store = GraphStore(graph: original)
    let channel = ProjectTransferMemoryConnection()
    await store.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let lease = ProjectTransferLease()
    let activated = await store.activateProjectTransfer(using: lease)
    XCTAssertTrue(activated)
    let token = UUID()
    _ = await store.snapshotForProjectTransfer(connectionID: channel.id, token: token)
    let huge = LoopNode(
      title: "Oversized", loopType: .turnBased,
      firstInstruction: String(repeating: "x", count: FramedMessageIO.v2MaxPayloadBytes))
    let request = GraphImportRequest(
      snapshot: LoopGraph(
        project: original.project, nodes: IdentifiedArrayOf(uniqueElements: [huge])))
    expectRejected(
      await store.importProjectChecked(
        request, expectedGraphID: original.id, snapshotToken: token, connectionID: channel.id))
    let unchanged = await store.graph
    let frames = await channel.frames
    XCTAssertEqual(unchanged, original)
    XCTAssertEqual(frames, 1)
    guard
      case .applied = await store.validateProjectTransfer(
        expectedGraphID: original.id, snapshotToken: token, connectionID: channel.id)
    else { return XCTFail("Oversize rejection consumed authorization") }
    _ = await store.removeConnection(channel.id)
    lease.invalidate()
  }

  func testOversizedRequestMemoryRejectsEvenWhenResultWouldFit() async {
    let original = project()
    let store = GraphStore(graph: original)
    let channel = ProjectTransferMemoryConnection()
    await store.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let lease = ProjectTransferLease()
    let activated = await store.activateProjectTransfer(using: lease)
    XCTAssertTrue(activated)
    let token = UUID()
    _ = await store.snapshotForProjectTransfer(connectionID: channel.id, token: token)
    var request = arriving()
    request.memoryByNodeID[request.snapshot.nodes[0].id.uuidString] = [
      String(repeating: "x", count: FramedMessageIO.v2MaxPayloadBytes)
    ]
    guard
      case .rejected(let reason, _) = await store.importProjectChecked(
        request, expectedGraphID: original.id, snapshotToken: token, connectionID: channel.id)
    else { return XCTFail("Oversized request applied") }
    XCTAssertTrue(reason.contains("request exceeds"), reason)
    let unchanged = await store.graph
    let frames = await channel.frames
    XCTAssertEqual(unchanged, original)
    XCTAssertEqual(frames, 1)
    _ = await store.removeConnection(channel.id)
    lease.invalidate()
  }

  func testRegistryRequiresJoinedCanonicalLocalRootAndRevokesOnClose() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-transfer-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let channel = ProjectTransferMemoryConnection()
    let outsider = ProjectTransferMemoryConnection()
    await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    await registry.addConnection(id: outsider.id, connection: outsider, mode: .v2(version: 2))
    let path = ProjectRegistry.canonicalize(folder.path)
    guard
      case .graphChanged(let opened)? = await registry.apply(
        .openProject(path: path), connectionID: channel.id)?.response
    else { return XCTFail("Could not open fixture root") }
    let token = UUID()
    expectRegistryRefusal(
      await registry.apply(
        .projectSnapshot(path: path + "\\child", token: token), connectionID: channel.id))
    expectRegistryRefusal(
      await registry.apply(
        .projectSnapshot(path: LoopGraphScope.globalPath, token: token),
        connectionID: channel.id))
    expectRegistryRefusal(
      await registry.apply(
        .projectSnapshot(path: "ssh://host/repository", token: token),
        connectionID: channel.id))
    expectRegistryRefusal(
      await registry.apply(
        .projectSnapshot(path: path, token: token), connectionID: outsider.id))
    guard
      case .graphChanged(let snapshot)? = await registry.apply(
        .projectSnapshot(path: path, token: token), connectionID: channel.id)?.response
    else { return XCTFail("Joined root snapshot failed") }
    XCTAssertEqual(snapshot.id, opened.id)
    _ = await registry.apply(.closeProject(path: path), connectionID: channel.id)
    expectRegistryRefusal(
      await registry.apply(
        .validateProjectTransfer(
          path: path, expectedGraphID: opened.id, snapshotToken: token),
        connectionID: channel.id))
    guard
      case .graphChanged? = await registry.apply(
        .openProject(path: path), connectionID: channel.id)?.response
    else { return XCTFail("Explicit reopen failed") }
    expectRegistryRefusal(
      await registry.apply(
        .importProjectChecked(
          path: path, expectedGraphID: opened.id, snapshotToken: token, request: arriving()),
        connectionID: channel.id))
    await registry.removeConnection(channel.id)
    await registry.removeConnection(outsider.id)
    registry.flushPersistence()
  }

  func testForgetAndDeleteInvalidateOldLeaseAndRecreatedGraph() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-transfer-delete-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let channel = ProjectTransferMemoryConnection()
    await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let path = ProjectRegistry.canonicalize(folder.path)
    guard
      case .graphChanged(let first)? = await registry.apply(
        .openProject(path: path), connectionID: channel.id)?.response
    else { return XCTFail("Could not open root") }
    let oldToken = UUID()
    _ = await registry.apply(
      .projectSnapshot(path: path, token: oldToken), connectionID: channel.id)
    _ = await registry.apply(.forgetProject(path: path), connectionID: channel.id)
    expectRegistryRefusal(
      await registry.apply(
        .validateProjectTransfer(
          path: path, expectedGraphID: first.id, snapshotToken: oldToken),
        connectionID: channel.id))
    guard
      case .graphChanged? = await registry.apply(
        .openProject(path: path), connectionID: channel.id)?.response
    else { return XCTFail("Could not reopen forgotten root") }
    _ = await registry.apply(.deleteProjectGraph(path: path), connectionID: channel.id)
    expectRegistryRefusal(
      await registry.apply(
        .validateProjectTransfer(
          path: path, expectedGraphID: first.id, snapshotToken: oldToken),
        connectionID: channel.id))
    guard
      case .graphChanged(let recreated)? = await registry.apply(
        .openProject(path: path), connectionID: channel.id)?.response
    else { return XCTFail("Could not reopen deleted root") }
    XCTAssertNotEqual(recreated.id, first.id)
    expectRegistryRefusal(
      await registry.apply(
        .importProjectChecked(
          path: path, expectedGraphID: first.id, snapshotToken: oldToken,
          request: arriving()), connectionID: channel.id))
    await registry.removeConnection(channel.id)
    registry.flushPersistence()
  }

  func testRemoteOpenStillWorksWithoutTransferAuthorization() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-transfer-remote-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = fixtureRegistry(at: root)
    let channel = ProjectTransferMemoryConnection()
    await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let path = ProjectRegistry.canonicalize("ssh://host/repository")
    let opened = await registry.apply(.openProject(path: path), connectionID: channel.id)
    guard
      case .graphChanged(let graph)? = opened?.response
    else { return XCTFail("Remote project no longer opens: \(opened?.error ?? "no result")") }
    XCTAssertEqual(graph.project.path, path)
    expectRegistryRefusal(
      await registry.apply(
        .projectSnapshot(path: path, token: UUID()), connectionID: channel.id))
    _ = await registry.apply(.closeProject(path: path), connectionID: channel.id)
    guard
      case .graphChanged? = await registry.apply(
        .openProject(path: path), connectionID: channel.id)?.response
    else { return XCTFail("Remote project no longer reopens") }
    await registry.removeConnection(channel.id)
    registry.flushPersistence()
  }

  func testSuspendedOpenCannotReactivateCompletedClose() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-transfer-race-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let entered = expectation(description: "open snapshot reached transport")
    let closed = expectation(description: "close completed while open was suspended")
    let channel = ProjectTransferMemoryConnection(onFirstSend: { entered.fulfill() })
    let registry = fixtureRegistry(at: root)
    await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let path = ProjectRegistry.canonicalize(folder.path)
    let pending = Task { await registry.apply(.openProject(path: path), connectionID: channel.id) }
    await fulfillment(of: [entered], timeout: 5)
    let closing = Task {
      let result = await registry.apply(.closeProject(path: path), connectionID: channel.id)
      closed.fulfill()
      return result
    }
    await fulfillment(of: [closed], timeout: 5)
    await channel.unblock()
    _ = await closing.value
    expectRegistryRefusal(await pending.value)
    let persistence = ProjectPersistence(
      baseDirectory: root.appendingPathComponent("persistence"))
    XCTAssertFalse(persistence.loadOpenProjects().contains(path))
    XCTAssertFalse(persistence.loadRecentProjects().contains(where: { $0.path == path }))
    expectRegistryRefusal(
      await registry.apply(
        .projectSnapshot(path: path, token: UUID()), connectionID: channel.id))
    guard
      case .graphChanged? = await registry.apply(
        .openProject(path: path), connectionID: channel.id)?.response
    else { return XCTFail("Fresh reopen was blocked") }
    await registry.removeConnection(channel.id)
    registry.flushPersistence()
  }

  func testCloseDuringSidebarJoinStopsStaleRecipientsAndKeepsSubscribers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-transfer-sidebars-\(UUID().uuidString)", isDirectory: true)
    let firstFolder = root.appendingPathComponent("first", isDirectory: true)
    let secondFolder = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let entered = expectation(description: "first sidebar join reached transport")
    let registry = fixtureRegistry(at: root)
    let opener = ProjectTransferMemoryConnection()
    let first = ProjectTransferMemoryConnection(onFirstSend: { entered.fulfill() })
    let second = ProjectTransferMemoryConnection(onFirstSend: { entered.fulfill() })
    for channel in [opener, first, second] {
      await registry.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    }
    _ = await registry.apply(.restoreOpenProjects, connectionID: first.id)
    _ = await registry.apply(.restoreOpenProjects, connectionID: second.id)
    let path = ProjectRegistry.canonicalize(firstFolder.path)
    let pending = Task { await registry.apply(.openProject(path: path), connectionID: opener.id) }
    await fulfillment(of: [entered], timeout: 5)
    _ = await registry.apply(.closeProject(path: path), connectionID: opener.id)
    await first.unblock()
    await second.unblock()
    expectRegistryRefusal(await pending.value)
    let joinedFirst = await first.frames
    let joinedSecond = await second.frames
    XCTAssertEqual(joinedFirst + joinedSecond, 1, "Stale join reached another sidebar")

    let other = ProjectRegistry.canonicalize(secondFolder.path)
    guard
      case .graphChanged? = await registry.apply(
        .openProject(path: other), connectionID: opener.id)?.response
    else { return XCTFail("Other project did not open") }
    let firstAfter = await first.frames
    let secondAfter = await second.frames
    XCTAssertGreaterThan(firstAfter, joinedFirst)
    XCTAssertGreaterThan(secondAfter, joinedSecond)
    for channel in [opener, first, second] {
      await registry.removeConnection(channel.id)
    }
    registry.flushPersistence()
  }

  func testQueuedCheckedImportRefusesLeaseInvalidatedBeforeCommit() async {
    let source = UUID()
    let destination = UUID()
    let parent = UUID()
    let child = LoopGraph(
      project: ProjectRef(path: "C:\\synthetic\\child", name: "Child"),
      nodes: IdentifiedArrayOf(uniqueElements: [
        LoopNode(id: source, title: "Source", loopType: .turnBased, state: .running),
        LoopNode(id: destination, title: "Destination", loopType: .turnBased, state: .running),
      ]),
      edges: IdentifiedArrayOf(uniqueElements: [
        LoopEdge(
          from: source, to: destination,
          spec: EdgeSpec(kind: .message, payloadTransform: .template("inert")))
      ]))
    let root = LoopGraph(
      project: ProjectRef(path: "C:\\synthetic\\queued", name: "Queued"),
      nodes: IdentifiedArrayOf(uniqueElements: [
        LoopNode(id: parent, title: "Parent", loopType: .composite, subGraph: child)
      ]))
    let entered = expectation(description: "legacy child writeback paused in delivery")
    let gate = ProjectTransferGate()
    let store = GraphStore(
      graph: root,
      onDeliverMessage: { _, _, _ in
        entered.fulfill()
        await gate.wait()
        return true
      })
    let channel = ProjectTransferMemoryConnection()
    await store.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let lease = ProjectTransferLease()
    let activated = await store.activateProjectTransfer(using: lease)
    XCTAssertTrue(activated)
    let token = UUID()
    _ = await store.snapshotForProjectTransfer(connectionID: channel.id, token: token)
    let legacy = Task {
      await store.handle(.subGraphCommand(nodeID: parent, command: .nodeCheckApproved(source)))
    }
    await fulfillment(of: [entered], timeout: 5)
    let pending = Task {
      await store.importProjectChecked(
        arriving(), expectedGraphID: root.id, snapshotToken: token, connectionID: channel.id)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
      if await store.queuedCommandSequence >= 2 { break }
      await Task.yield()
    }
    let queued = await store.queuedCommandSequence
    lease.invalidate()
    await gate.open()
    _ = await legacy.value
    expectRejected(await pending.value)
    XCTAssertEqual(queued, 2)
    let updated = await store.graph
    XCTAssertEqual(updated.nodes.count, 1)
    XCTAssertEqual(updated.nodes[id: parent]?.subGraph?.edges[0].fireCount, 1)
    _ = await store.removeConnection(channel.id)
  }

  private func fixtureRegistry(at root: URL) -> ProjectRegistry {
    ProjectRegistry(
      persistenceDirectory: root.appendingPathComponent("persistence"),
      ensureSession: nil, restoreRebootedSessions: nil, terminateSession: nil,
      restartSession: nil, evaluatePredicate: nil, checkPredicate: nil,
      deliverMessage: nil, captureScript: nil, readUsage: nil, readGoalVerdict: nil,
      readActivity: nil, readSummary: nil, readPresence: nil, sessionAlive: nil,
      composeBoard: nil,
      startQuickChat: { _, _ in .failure(.unavailable("test fixture")) },
      terminateQuickChat: { _, _ in .failure(.unavailable("test fixture")) },
      quickChatExists: { _, _ in false }, enumerateQuickChatSessions: { [] })
  }

  private func expectRegistryRefusal(
    _ result: ProjectRegistryCommandResult?,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertNotNil(result?.error, file: file, line: line)
    XCTAssertFalse(result?.succeeded ?? true, file: file, line: line)
  }

  private func expectRejected(
    _ result: GraphStoreCommandResult,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard case .rejected(let message, _) = result else {
      XCTFail("Expected refusal", file: file, line: line)
      return
    }
    XCTAssertFalse(message.isEmpty, file: file, line: line)
  }
}
private actor ProjectTransferMemoryConnection: DaemonConnection {
  nonisolated let id = UUID()
  nonisolated let endpoint: DaemonEndpoint = .namedPipe("\\\\.\\pipe\\transfer-in-memory")
  private let onFirstSend: (@Sendable () -> Void)?
  private var firstSend: CheckedContinuation<Void, Never>?
  private var blockFirstSend: Bool
  private(set) var frames = 0

  init(onFirstSend: (@Sendable () -> Void)? = nil) {
    self.onFirstSend = onFirstSend
    blockFirstSend = onFirstSend != nil
  }

  func receiveFrame() async throws -> Data { throw Closed.connection }
  func sendFrame(_ data: Data) async throws {
    frames += 1
    if frames == 1, blockFirstSend, let onFirstSend {
      onFirstSend()
      await withCheckedContinuation { firstSend = $0 }
    }
  }
  func unblock() {
    blockFirstSend = false
    firstSend?.resume()
    firstSend = nil
  }
  func close() async throws {}

  private enum Closed: Error { case connection }
}
private actor ProjectTransferGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false

  func wait() async {
    if opened { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    opened = true
    continuation?.resume()
    continuation = nil
  }
}
