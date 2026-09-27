import ComposableArchitecture
import GraphcodeKit

extension AppFeature {
  /// Selecting any loop of a codespace is a human asking for that codespace now (issue
  /// #480): its dialers restart their retry schedule and redial, from a hold or a pause.
  /// Every user selection reaches `.nodeTapped`, blocked loops included, so this runs
  /// there rather than in `openNode`, which returns early for most loops.
  func resumeCodespace(_ projectPath: String) -> Effect<Action> {
    guard let location = Self.codespace(atProjectPath: projectPath) else { return .none }
    return .run { _ in CodespaceDialBreaker.requestReconnect(for: location) }
  }

  static func codespace(atProjectPath projectPath: String) -> RemoteProjectLocation? {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath),
      location.isCodespace
    else { return nil }
    return location
  }
}
