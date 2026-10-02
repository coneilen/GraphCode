import Foundation

/// Finds `graphcode-nod` and the directory a node's runtime keeps its state in.
///
/// Never a PATH lookup. Nod ships inside the app, so the binary a session runs is the one
/// that matches the app's protocol version — a `graphcode-nod` someone put on their PATH
/// could be any version at all.
public enum NodRuntimeLocator {
  /// Tried in order: the development override, the running app's bundle, then the
  /// support directory's `bin`, which is where `graphcoded` (installed out of the bundle)
  /// finds its helpers.
  public static func binaryURL(bundle: Bundle = .main) -> URL? {
    if let path = NodRuntimeLocation.developmentOverride {
      return URL(fileURLWithPath: path)
    }
    let name = CLISessionBackendKind.nod.executableName ?? "graphcode-nod"
    let candidates = [
      bundle.resourceURL?.appendingPathComponent("bin/\(name)"),
      SupportDirectory.binDirectory.appendingPathComponent(name),
    ]
    return candidates.compactMap { $0 }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
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

  public static func environment(forNodeID nodeID: UUID) -> [String: String] {
    [NodProtocol.stateDirectoryVariable: stateDirectory(forNodeID: nodeID).path]
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
