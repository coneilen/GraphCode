import Foundation
import XCTest

@testable import GraphcodeKit

final class ProjectTransferLeaseTests: XCTestCase {
  private func graph() -> LoopGraph {
    LoopGraph(project: ProjectRef(path: "C:\\synthetic\\lease", name: "Lease"))
  }

  private func request(in graph: LoopGraph, memory: Bool = false) -> GraphImportRequest {
    let node = LoopNode(title: "Arriving", loopType: .turnBased, state: .succeeded)
    return GraphImportRequest(
      snapshot: LoopGraph(scope: graph.scope, nodes: [node]),
      memoryByNodeID: memory ? [node.id.uuidString: ["memory"]] : [:])
  }

  func testMemoryCallbackAfterCommitCanInvalidateLease() async {
    let original = graph()
    let lease = ProjectTransferLease()
    let store = GraphStore(graph: original, onAppendMemory: { _, _ in lease.invalidate() })
    let channel = LeaseTestConnection()
    await store.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let activated = await store.activateProjectTransfer(using: lease)
    XCTAssertTrue(activated)
    let token = UUID()
    _ = await store.snapshotForProjectTransfer(connectionID: channel.id, token: token)
    let result = await store.importProjectChecked(
      request(in: original, memory: true), expectedGraphID: original.id,
      snapshotToken: token, connectionID: channel.id)
    guard case .applied(let merged) = result else { return XCTFail("Import failed") }
    XCTAssertEqual(merged.nodes.count, 1)
    XCTAssertFalse(lease.isActive)
    _ = await store.removeConnection(channel.id)
  }

  func testRefusalCallbackCanInvalidateLeaseWithoutDeadlock() async {
    let original = graph()
    let lease = ProjectTransferLease()
    let store = GraphStore(graph: original, onAnnounceError: { _ in lease.invalidate() })
    let channel = LeaseTestConnection()
    await store.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let activated = await store.activateProjectTransfer(using: lease)
    XCTAssertTrue(activated)
    let token = UUID()
    _ = await store.snapshotForProjectTransfer(connectionID: channel.id, token: token)
    let result = await store.importProjectChecked(
      GraphImportRequest(snapshot: LoopGraph(scope: original.scope)),
      expectedGraphID: original.id, snapshotToken: token, connectionID: channel.id)
    guard case .rejected(let message, _) = result else { return XCTFail("Empty import applied") }
    XCTAssertTrue(message.contains("no loops"))
    XCTAssertFalse(lease.isActive)
    _ = await store.removeConnection(channel.id)
  }

  func testInvalidationIsIrreversibleAndReleasedLeaseIsNotRetained() {
    var prior: ProjectTransferLease? = ProjectTransferLease()
    weak var observed = prior
    var commits = 0
    XCTAssertTrue(prior!.withActive { commits += 1 })
    prior!.invalidate()
    prior!.invalidate()
    XCTAssertFalse(prior!.withActive { commits += 1 })
    let replacement = ProjectTransferLease()
    XCTAssertTrue(replacement.withActive { commits += 1 })
    XCTAssertEqual(commits, 2)
    prior = nil
    XCTAssertNil(observed)
  }

  func testGlobalAndRemoteStoresCannotActivateTransferLease() async {
    let global = GraphStore(graph: LoopGraph(scope: .global))
    let remote = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "ssh://host/repository", name: "Remote")))
    let globalActivated = await global.activateProjectTransfer(using: ProjectTransferLease())
    let remoteActivated = await remote.activateProjectTransfer(using: ProjectTransferLease())
    XCTAssertFalse(globalActivated)
    XCTAssertFalse(remoteActivated)
  }

  func testOldActivationCannotOverwriteNewLeaseOrToken() async {
    let original = graph()
    let store = GraphStore(graph: original)
    let channel = LeaseTestConnection()
    await store.addConnection(id: channel.id, connection: channel, mode: .v2(version: 2))
    let old = ProjectTransferLease()
    let initial = await store.activateProjectTransfer(using: old)
    XCTAssertTrue(initial)
    let oldToken = UUID()
    _ = await store.snapshotForProjectTransfer(connectionID: channel.id, token: oldToken)
    old.invalidate()
    let stale = await store.activateProjectTransfer(using: old)
    XCTAssertFalse(stale)
    expectRejected(
      await store.validateProjectTransfer(
        expectedGraphID: original.id, snapshotToken: oldToken, connectionID: channel.id))
    let fresh = ProjectTransferLease()
    let activated = await store.activateProjectTransfer(using: fresh)
    XCTAssertTrue(activated)
    let token = UUID()
    _ = await store.snapshotForProjectTransfer(connectionID: channel.id, token: token)
    let late = await store.activateProjectTransfer(using: old)
    XCTAssertFalse(late)
    guard
      case .applied = await store.validateProjectTransfer(
        expectedGraphID: original.id, snapshotToken: token, connectionID: channel.id)
    else { return XCTFail("Old activation invalidated the new token") }
    expectRejected(
      await store.importProjectChecked(
        request(in: original), expectedGraphID: original.id,
        snapshotToken: oldToken, connectionID: channel.id))
    _ = await store.removeConnection(channel.id)
    fresh.invalidate()
  }

  private func expectRejected(_ result: GraphStoreCommandResult) {
    guard case .rejected(let message, _) = result else { return XCTFail("Unexpected success") }
    XCTAssertFalse(message.isEmpty)
  }
}
private actor LeaseTestConnection: DaemonConnection {
  nonisolated let id = UUID()
  nonisolated let endpoint: DaemonEndpoint = .namedPipe("\\\\.\\pipe\\lease-in-memory")
  func receiveFrame() async throws -> Data { throw Closed.connection }
  func sendFrame(_ data: Data) async throws {}
  func close() async throws {}
  private enum Closed: Error { case connection }
}
