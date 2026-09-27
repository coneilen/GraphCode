import Foundation

/// When a codespace that stopped answering may be dialed again (issue #480).
///
/// Every Codespace dial is `gh codespace ssh`, and every gh run costs calls against the
/// human's per-user Codespaces rate limit — around a hundred while a codespace is
/// starting. Retrying on each reader's own clock spent that limit during every outage,
/// so all dialers share this one schedule, counted from the first failure: retry freely
/// for a minute, hold until the third, retry again until the fourth, then pause until a
/// human asks to reconnect.
///
/// The daemon applies it in `CodespaceDialBreaker`; a terminal pane applies the same
/// numbers inside its shell loop (`SSHReconnectLoop`), which runs in another process.
public struct CodespaceDialSchedule: Equatable, Sendable {
  public var freeRetryWindow: Int
  public var holdUntil: Int
  public var pauseAfter: Int

  public init(freeRetryWindow: Int = 60, holdUntil: Int = 180, pauseAfter: Int = 240) {
    self.freeRetryWindow = freeRetryWindow
    self.holdUntil = holdUntil
    self.pauseAfter = pauseAfter
  }

  public static let standard = CodespaceDialSchedule()

  public enum Verdict: Equatable, Sendable {
    case dial
    case hold
    case paused
  }

  /// `secondsDown` is how long the codespace has been failing; `nil` means it is not.
  public func verdict(secondsDown: TimeInterval?) -> Verdict {
    guard let secondsDown else { return .dial }
    if secondsDown >= TimeInterval(pauseAfter) { return .paused }
    if secondsDown >= TimeInterval(freeRetryWindow), secondsDown < TimeInterval(holdUntil) {
      return .hold
    }
    return .dial
  }
}
