import Foundation

/// A local `/bin/sh` retry loop around two ssh command lines, for the failure it exists
/// to survive: a live surface whose ssh
/// drops (a Codespace idle-stopping, sleep, a network change) died on screen even though
/// the remote zmx session kept the agent running, and recovery meant closing and
/// reopening the loop's terminal by hand.
///
/// `connect` runs once — the create-or-attach dial the surface always made. ssh reserves
/// exit 255 for its own connection errors, so 255 retries `reconnect` (attach-only; see
/// `GhosttyTerminalView.remoteCommand` for why it must never re-run the agent command)
/// with capped exponential backoff, forever — an overnight sleep still resumes. Every
/// other exit passes through, closing the surface exactly like a local shell exit.
///
/// 255 also covers permanent ssh failures (auth, host key, DNS), which therefore retry
/// too; the banner names the exit code and ssh's own error text stays visible above it.
/// Ctrl-C during the wait is the escape hatch — the `trap` makes it deterministic, and
/// while ssh is live the tty is raw so Ctrl-C goes to the remote side instead.
///
/// A Codespace surface uses `codespaceScript` instead, which retries on a schedule rather
/// than forever.
public enum SSHReconnectLoop {
  public static let maxDelaySeconds = 15

  public static func script(connect: String, reconnect: String) -> String {
    let passExit = "; gc_rc=$?; [ \"$gc_rc\" -ne 255 ] && exit \"$gc_rc\""
    return "trap 'exit 130' INT; "
      + connect + passExit + "; "
      + "gc_delay=1; while :; do "
      + #"printf '\033[1;33m── Connection failed (exit %s). Retrying in %ss. "#
      + #"Press Ctrl-C to stop. ──\033[0m\r\n' "$gc_rc" "$gc_delay"; "#
      + "sleep \"$gc_delay\"; gc_delay=$((gc_delay * 2)); "
      + "[ \"$gc_delay\" -gt \(maxDelaySeconds) ] && gc_delay=\(maxDelaySeconds); "
      + reconnect + passExit + "; done"
  }

  /// A Codespace surface's loop: the same dials and exit handling, retried on
  /// `CodespaceDialSchedule` instead of forever, because every gh run spends the human's
  /// Codespaces rate limit (issue #480). Past `schedule.pauseAfter` it waits for Enter,
  /// which also touches `pauseMarker` so `graphcoded`'s `CodespaceDialBreaker` resumes
  /// the codespace's reads and ensures with it.
  ///
  /// The outage clock restarts only after a dial that lasted `upAfter`, longer than the
  /// five minutes gh can spend waiting for a codespace to start before failing — a
  /// shorter dial may never have reached the codespace at all.
  ///
  /// Exit 1 retries as well as 255: `gh` runs ssh but does not propagate its exit code —
  /// every nonzero exit (ssh's 255 *and* the remote scripts' deliberate `exit 255`s)
  /// surfaces as gh's own 1, with only 0 preserved. That also redials a session that
  /// genuinely ended nonzero, which converges: the redial reattaches a live session, and
  /// a gone one takes the reconnect script's session-ended branch to a clean exit 0.
  public static func codespaceScript(
    connect: String, reconnect: String, pauseMarker: String,
    schedule: CodespaceDialSchedule = .standard, upAfter: Int = 330
  ) -> String {
    let marker = quoted(pauseMarker)
    let directory = quoted(URL(fileURLWithPath: pauseMarker).deletingLastPathComponent().path)
    let passExit =
      "; gc_rc=$?; { [ \"$gc_rc\" -ne 255 ] && [ \"$gc_rc\" -ne 1 ]; } && exit \"$gc_rc\""
    let clock =
      "; { [ -z \"$gc_down\" ] || [ $(($(date +%s) - gc_t)) -ge \(upAfter) ]; } "
      + "&& { gc_down=$(date +%s); gc_delay=1; }"
    return "trap 'exit 130' INT; gc_down=; gc_delay=1; gc_t=$(date +%s); "
      + connect + passExit + clock + "; "
      + "while :; do gc_out=$(($(date +%s) - gc_down)); "
      + "if [ \"$gc_out\" -ge \(schedule.pauseAfter) ]; then "
      + #"printf '\033[1;33m── Codespace still unreachable (exit %s). Paused to save your "#
      + #"Codespaces API quota. Press Enter to reconnect, Ctrl-C to close. ──\033[0m\r\n' "#
      + "\"$gc_rc\"; read gc_line || exit 0; "
      + "mkdir -p \(directory) && : > \(marker); gc_down=$(date +%s); gc_delay=1; "
      + "else "
      + "if [ \"$gc_out\" -ge \(schedule.freeRetryWindow) ] "
      + "&& [ \"$gc_out\" -lt \(schedule.holdUntil) ]; then "
      + "gc_wait=$((\(schedule.holdUntil) - gc_out)); else gc_wait=$gc_delay; "
      + "gc_delay=$((gc_delay * 2)); "
      + "[ \"$gc_delay\" -gt \(maxDelaySeconds) ] && gc_delay=\(maxDelaySeconds); fi; "
      + #"printf '\033[1;33m── Connection failed (exit %s). Retrying in %ss. "#
      + #"Press Ctrl-C to stop. ──\033[0m\r\n' "$gc_rc" "$gc_wait"; "#
      + "sleep \"$gc_wait\"; fi; "
      + "gc_t=$(date +%s); " + reconnect + passExit + clock + "; done"
  }

  /// `RemoteProjectLocation.shellQuoted`, repeated because this file also builds in the
  /// portable package, which leaves that type out.
  private static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
