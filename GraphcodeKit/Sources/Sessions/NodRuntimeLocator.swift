import Foundation

/// Finds `graphcode-nod` and the directory a node's runtime keeps its state in.
///
/// Never a PATH lookup. Nod ships inside the app, so the binary a session runs is the one
/// that matches the app's protocol version — a `graphcode-nod` someone put on their PATH
/// could be any version at all.
public enum NodRuntimeLocator {
  /// Wins over everything below. A `var` only so tests can launch against a fixture
  /// without touching the process environment the rest of the suite reads.
  static var binaryOverride: URL?

  /// The runtime's directory inside the app bundle — `graphcode-nod` with what it loads
  /// beside it (NodRuntime/scripts/package.sh).
  public static let bundledDirectory = "Contents/Helpers/nod"
  /// Where `DaemonBootstrap` copies that directory, under the support directory's `bin`.
  public static let installedDirectory = "nod"

  /// Tried in order: the development override, the running app's bundle, then the copy
  /// `DaemonBootstrap` installs under the support directory's `bin` — the only one
  /// `graphcoded` can see, since it runs from there with no bundle of its own.
  public static func binaryURL(bundle: Bundle = .main) -> URL? {
    if let binaryOverride { return binaryOverride }
    if let path = NodRuntimeLocation.developmentOverride {
      return URL(fileURLWithPath: path)
    }
    let name = CLISessionBackendKind.nod.executableName ?? "graphcode-nod"
    let candidates = [
      bundle.bundleURL.appendingPathComponent("\(bundledDirectory)/\(name)"),
      SupportDirectory.binDirectory.appendingPathComponent("\(installedDirectory)/\(name)"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  /// `$NOD_STATE` for a node — under the support directory, so a moved workspace keeps
  /// its Nod state with everything else it owns.
  public static func stateDirectory(forNodeID nodeID: UUID) -> URL {
    SupportDirectory.url.appendingPathComponent("nod", isDirectory: true)
      .appendingPathComponent(nodeID.uuidString, isDirectory: true)
  }

  public static func eventsFile(forNodeID nodeID: UUID) -> URL {
    stateDirectory(forNodeID: nodeID).appendingPathComponent(NodProtocol.eventsFileName)
  }

  public static func controlSocket(forNodeID nodeID: UUID) -> URL {
    stateDirectory(forNodeID: nodeID).appendingPathComponent(NodProtocol.controlSocketName)
  }

  /// The session's environment: its state directory, which node it is, and its project.
  public static func environment(forNodeID nodeID: UUID, projectPath: String? = nil)
    -> [String: String]
  {
    var environment = [
      NodProtocol.stateDirectoryVariable: stateDirectory(forNodeID: nodeID).path,
      NodProtocol.nodeIDVariable: nodeID.uuidString,
    ]
    environment[NodProtocol.projectPathVariable] = projectPath
    return environment
  }

  /// Writes a goal loop's condition where `--goal-file` points, or `nil` for a node with
  /// no goal. Rewritten every launch, so a goal edited between passes is the one evaluated.
  public static func writeGoal(of node: LoopNode) -> URL? {
    guard node.loopType == .goalBased, let goal = node.goal else { return nil }
    let directory = stateDirectory(forNodeID: node.id)
    let file = directory.appendingPathComponent(NodProtocol.goalFileName)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(goal.summary.utf8).write(to: file, options: .atomic)
      return file
    } catch {
      return nil
    }
  }
}
