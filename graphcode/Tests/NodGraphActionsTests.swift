import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

@Suite
struct NodGraphActionsTests {
  static func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nod-briefs-\(UUID().uuidString)")
  }

  @Test
  func runAsCompositeWritesEachChildsBriefThenCreatesAndPilots() async throws {
    let directory = Self.scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sent = LockIsolated<[GraphCommand]>([])
    let source = LoopNode(title: "Monetization", loopType: .sketch, backend: .nod)
    let plan = NodEditablePlan(
      planID: "p", title: "Usage caps", steps: NodCompositeGroupingTests.usageCapSteps)

    let id = try await NodGraphActions.runAsComposite(
      plan, plannedIn: source, briefDirectory: directory, enabled: true
    ) { command in sent.withValue { $0.append(command) } }

    let commands = sent.value
    #expect(commands.count == 2)
    guard case .createNode(let draft) = commands.first else {
      Issue.record("expected createNode first")
      return
    }
    #expect(draft.id == id)
    #expect(commands.last == .pilotComposite(id))
    let paths = draft.subGraph?.nodes.compactMap(\.lineage?.briefPath) ?? []
    #expect(paths.count == 2)
    for path in paths {
      #expect(path.hasPrefix(directory.path))
      let brief = try NodProtocol.makeDecoder().decode(
        NodBrief.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
      #expect(brief.kind == .compositeChild)
      #expect(brief.fromNodeID == source.id)
    }
  }

  @Test
  func nothingHappensWhileNodIsRampedOff() async {
    let sent = LockIsolated<[GraphCommand]>([])
    let source = LoopNode(title: "M", loopType: .sketch)
    let plan = NodEditablePlan(
      planID: "p", title: "t", steps: NodCompositeGroupingTests.usageCapSteps)
    await #expect(throws: NodGraphActions.Failure.nodUnavailable) {
      try await NodGraphActions.runAsComposite(
        plan, plannedIn: source, briefDirectory: Self.scratch(), enabled: false
      ) { command in sent.withValue { $0.append(command) } }
    }
    await #expect(throws: NodGraphActions.Failure.nodUnavailable) {
      try await NodGraphActions.fork(
        source, in: NodForkTests.graph([source]), atMessage: "m", enabled: false,
        createWorktree: { _ in
          Issue.record("no worktree while off")
          throw CancellationError()
        },
        send: { command in sent.withValue { $0.append(command) } })
    }
    #expect(sent.value.isEmpty)
  }

  @Test
  func forkCreatesItsWorktreeThenTheSiblingBoundToIt() async throws {
    let directory = Self.scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sent = LockIsolated<[GraphCommand]>([])
    let requests = LockIsolated<[NodFork.WorktreeRequest]>([])
    let source = LoopNode(title: "Spike", loopType: .sketch, backend: .nod)

    let id = try await NodGraphActions.fork(
      source, in: NodForkTests.graph([source]), atMessage: "m3", conversationID: "c",
      briefDirectory: directory, enabled: true,
      createWorktree: { request in
        requests.withValue { $0.append(request) }
        return WorktreeRef(
          id: request.branch, repositoryPath: request.repositoryPath,
          worktreePath: request.worktreePath, branch: request.branch)
      },
      send: { command in sent.withValue { $0.append(command) } })

    #expect(requests.value.map(\.branch) == ["nod/Spike-fork2"])
    guard case .createNode(let draft) = sent.value.first, sent.value.count == 1 else {
      Issue.record("expected exactly one createNode")
      return
    }
    #expect(draft.id == id)
    #expect(draft.worktree?.branch == "nod/Spike-fork2")
    #expect(draft.lineage?.kind == .fork)
    let path = try #require(draft.lineage?.briefPath)
    let brief = try NodProtocol.makeDecoder().decode(
      NodBrief.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(brief.fork == NodBrief.ForkPoint(conversationID: "c", messageID: "m3"))
  }

  @Test
  func aRealForkWorktreeBranchesFromTheSourcesBranch() async throws {
    let root = Self.scratch()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    func git(_ arguments: String...) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments =
        ["-C", repo.path, "-c", "user.name=t", "-c", "user.email=t@t"] + arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
    }
    try git("init", "-q", "-b", "main")
    try git("commit", "-q", "--allow-empty", "-m", "base")
    try git("checkout", "-q", "-b", "loop/a")
    try "x".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try git("add", "a.txt")
    try git("commit", "-q", "-m", "on the loop branch")
    try git("checkout", "-q", "main")

    let ref = try await NodGraphActions.gitWorktree(
      NodFork.WorktreeRequest(
        repositoryPath: repo.path, worktreePath: root.appendingPathComponent("repo-fork").path,
        branch: "loop/a-fork2", startPoint: "loop/a"))
    #expect(ref.branch == "loop/a-fork2")
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("repo-fork/a.txt").path))
  }
}
