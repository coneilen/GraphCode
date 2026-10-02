import Foundation
import GraphcodeKit

/// Performs the graph-changing actions a Nod conversation offers: Run as Composite and
/// Fork as a new sibling. The app does these rather than the runtime because creating a
/// worktree and writing briefs are the app's jobs, as they are for the node form.
///
/// Top-level loops only; a loop inside a composite is addressed through its parent.
enum NodGraphActions {
  enum Failure: Error, Equatable {
    case nodUnavailable
    case nothingToRun
    case worktree(String)
  }

  typealias Send = @Sendable (GraphCommand) async throws -> Void

  static var briefDirectory: URL {
    SupportDirectory.url.appendingPathComponent("nod/briefs", isDirectory: true)
  }

  static func briefPath(for id: UUID, in directory: URL = briefDirectory) -> String {
    directory.appendingPathComponent("\(id.uuidString).json").path
  }

  static func write(_ brief: NodBrief, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try NodProtocol.makeEncoder().encode(brief).write(to: url, options: .atomic)
  }

  /// Creates the composite and pilots it, so its children start. Returns its id.
  @discardableResult
  static func runAsComposite(
    _ plan: NodEditablePlan, plannedIn source: LoopNode,
    briefDirectory: URL = briefDirectory,
    enabled: Bool = FeatureRamps.isEnabled(.nod), send: Send
  ) async throws -> UUID {
    guard enabled else { throw Failure.nodUnavailable }
    let composite = NodCompositePlan(title: plan.title, steps: plan.steps)
    guard !composite.groups.isEmpty else { throw Failure.nothingToRun }
    let made = composite.makeComposite(plannedIn: source) {
      briefPath(for: $0, in: briefDirectory)
    }
    for (path, brief) in made.briefs { try write(brief, to: path) }
    try await send(.createNode(made.draft))
    try await send(.pilotComposite(made.draft.id))
    return made.draft.id
  }

  /// Creates the fork's worktree on a branch cut from the source's, writes its brief, and
  /// creates it beside the source. Returns its id.
  @discardableResult
  static func fork(
    _ source: LoopNode, in graph: LoopGraph, atMessage messageID: String,
    conversationID: String? = nil, approach: String? = nil,
    briefDirectory: URL = briefDirectory,
    enabled: Bool = FeatureRamps.isEnabled(.nod),
    createWorktree: @Sendable (NodFork.WorktreeRequest) async throws -> WorktreeRef =
      gitWorktree,
    send: Send
  ) async throws -> UUID {
    guard enabled else { throw Failure.nodUnavailable }
    let briefID = UUID()
    let path = briefPath(for: briefID, in: briefDirectory)
    let fork = NodFork(
      of: source, in: graph, atMessage: messageID, conversationID: conversationID,
      approach: approach, briefPath: path)
    var draft = fork.draft
    draft.worktree = try await createWorktree(fork.worktree)
    try write(fork.brief, to: path)
    try await send(.createNode(draft))
    return draft.id
  }

  /// `git worktree add -b <branch> -- <path> [<start>]`.
  @Sendable
  static func gitWorktree(_ request: NodFork.WorktreeRequest) async throws -> WorktreeRef {
    var arguments = [
      "-C", request.repositoryPath, "worktree", "add", "-b", request.branch, "--",
      request.worktreePath,
    ]
    if let start = request.startPoint { arguments.append(start) }
    let (status, output) = try await run("/usr/bin/git", arguments)
    guard status == 0 else { throw Failure.worktree(output) }
    return WorktreeRef(
      id: request.branch, repositoryPath: request.repositoryPath,
      worktreePath: request.worktreePath, branch: request.branch)
  }

  /// Awaited through `terminationHandler`: `waitUntilExit` on a cooperative thread can
  /// deadlock the executor.
  private static func run(_ executable: String, _ arguments: [String]) async throws -> (
    Int32, String
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { process in
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        continuation.resume(
          returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}
