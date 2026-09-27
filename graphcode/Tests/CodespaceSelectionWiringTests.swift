import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// Which gestures ask a codespace to reconnect (issue #480): a tap on any of its loops
/// and a Back/Forward step onto one, and never a loop elsewhere. The request itself
/// rides a dependency, so what is proven is the wiring rather than a file.
@MainActor
@Suite
struct CodespaceSelectionWiringTests {
  private static let codespace = ProjectRef(
    path: "codespace://fluffy-space-waddle/workspaces/widget", name: "widget")
  private static let server = ProjectRef(path: "ssh://dev@build-box/srv/widget", name: "widget")

  private func store(
    projects: [ProjectRef], nodes: [LoopNode], history: LoopHistory = LoopHistory(),
    requested: LockIsolated<[String]>
  ) -> TestStoreOf<AppFeature> {
    var state = AppFeature.State()
    for project in projects {
      state.projects.append(
        ProjectFeature.State(
          graph: LoopGraph(project: project, nodes: IdentifiedArray(uniqueElements: nodes))))
    }
    state.selectedProjectPath = projects.first?.path
    state.loopHistory = history
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalLayoutStore = TerminalLayoutStore(
        baseDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true))
      $0.codespaceReconnect.request = { location in
        requested.withValue { $0.append(location.host) }
      }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func tappingACodespaceLoopAsksItToReconnect() async {
    let node = LoopNode(title: "Build", checkDescription: "Green?")
    let requested = LockIsolated<[String]>([])
    let store = store(projects: [Self.codespace], nodes: [node], requested: requested)

    await store.send(.projects(.element(id: Self.codespace.path, action: .nodeTapped(node.id))))
    await store.finish()

    #expect(requested.value == ["fluffy-space-waddle"])
  }

  @Test
  func tappingABlockedCodespaceLoopStillAsks() async {
    var node = LoopNode(title: "Fetch", loopType: .goalBased, goal: GoalSpec(summary: "fetch"))
    node.state = .blocked
    let requested = LockIsolated<[String]>([])
    let store = store(projects: [Self.codespace], nodes: [node], requested: requested)

    await store.send(.projects(.element(id: Self.codespace.path, action: .nodeTapped(node.id))))
    await store.finish()

    #expect(requested.value == ["fluffy-space-waddle"])
  }

  @Test
  func tappingALoopOnAPlainSSHHostAsksNothing() async {
    let node = LoopNode(title: "Build", checkDescription: "Green?")
    let requested = LockIsolated<[String]>([])
    let store = store(projects: [Self.server], nodes: [node], requested: requested)

    await store.send(.projects(.element(id: Self.server.path, action: .nodeTapped(node.id))))
    await store.finish()

    #expect(requested.value.isEmpty)
  }

  @Test
  func steppingBackOntoACodespaceLoopAsksItToReconnect() async {
    let first = LoopNode(title: "First", checkDescription: "Done?")
    let second = LoopNode(title: "Second", checkDescription: "Done?")
    let history = LoopHistory(
      entries: [
        .loop(projectPath: Self.codespace.path, nodeID: first.id),
        .loop(projectPath: Self.codespace.path, nodeID: second.id),
      ],
      cursor: 1)
    let requested = LockIsolated<[String]>([])
    let store = store(
      projects: [Self.codespace], nodes: [first, second], history: history,
      requested: requested)

    await store.send(.historyBackTapped)
    await store.finish()

    #expect(requested.value == ["fluffy-space-waddle"])
  }

  // MARK: - The floor

  @Test
  func repeatedSelectionsAskAtMostOncePerInterval() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codespace-floor-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = try #require(RemoteProjectLocation.parse(projectPath: Self.codespace.path))
    let marker = CodespaceDialBreaker.reconnectMarker(for: location, in: directory)
    let start = Date(timeIntervalSince1970: 2_000_000)
    func touched() throws -> Date? {
      try FileManager.default.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date
    }

    CodespaceDialBreaker.requestReconnect(for: location, in: directory, now: start)
    CodespaceDialBreaker.requestReconnect(
      for: location, in: directory, now: start.addingTimeInterval(10))
    #expect(try touched() == start)

    CodespaceDialBreaker.requestReconnect(
      for: location, in: directory, now: start.addingTimeInterval(31))
    #expect(try touched() == start.addingTimeInterval(31))
  }
}
