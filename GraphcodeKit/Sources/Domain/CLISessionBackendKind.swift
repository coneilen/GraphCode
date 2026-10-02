/// Which CLI coding-agent backend a `LoopNode` runs inside — see
/// docs/04-cli-backends.md. All five are spiked and share the zmx-backed adapter
/// (`CLISessionBackend.zmxBacked`); what differs per backend is how a session can be
/// asked what it is doing, which is why `presence` and `activity` are the two operations
/// that switch on this and the rest are not.
///
/// A time-based node's recurrence is expressed in its own prompt using whichever looping
/// skill its backend provides (`/loop` for `.claudeCode`), so nothing here needs a
/// per-backend scheduling capability — see `LoopNode.triggerPrompt`.
public enum CLISessionBackendKind: String, Codable, CaseIterable, Sendable {
  case claudeCode
  case copilotCLI
  case codex
  case openCode
  case pi
  /// GraphCode's own chat-native agent, running on the Claude Agent SDK or the GitHub
  /// Copilot SDK — NodRuntime/README.md. Unlike the CLIs it is not a TUI graphcode types
  /// into: the app reads its event stream (`NodEvent`) and renders a chat pane.
  case nod

  /// Whether the daemon can read this backend's own goal verdict.
  public var recordsGoalVerdict: Bool {
    switch self {
    case .claudeCode, .codex, .copilotCLI, .nod: return true
    case .openCode, .pi: return false
    }
  }
}
