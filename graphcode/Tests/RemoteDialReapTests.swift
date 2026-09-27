import Foundation
import Testing

@testable import GraphcodeKit

/// A remote read must not outlive its limit or its caller (issue #480).
///
/// A Codespace dial is `gh codespace ssh`, and against a codespace that is starting gh
/// polls the Codespaces API for up to five minutes before ssh even runs. Presence reads
/// were already reaped by `GraphStore`'s deadline; activity and summary reads had no
/// limit, so one starting codespace held the poll tick and spent calls the whole time.
/// The dial here is a local `sh` that records its pid and sleeps: what is being proven
/// is the process lifetime, and that needs no host.
@Suite
struct RemoteDialReapTests {
  private func sleeper() throws -> (invocation: [String], pidFile: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-dial-reap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let pidFile = directory.appendingPathComponent("pid")
    let script = "echo $$ > \(RemoteProjectLocation.shellQuoted(pidFile.path)); exec sleep 60"
    return (["/bin/sh", "-c", script], pidFile)
  }

  private func pid(in file: URL) async throws -> pid_t {
    for _ in 0..<100 {
      if let text = try? String(contentsOf: file, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return pid
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw CocoaError(.fileReadNoSuchFile)
  }

  private func isGone(_ pid: pid_t, within limit: Duration = .seconds(5)) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + limit
    while clock.now < end {
      if kill(pid, 0) != 0 { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return kill(pid, 0) != 0
  }

  @Test
  func aTranscriptProbeIsKilledAtItsOwnLimit() async throws {
    let (invocation, pidFile) = try sleeper()
    let started = ContinuousClock.now

    let reply = await RemoteTranscriptProbe.run(invocation, timeout: .milliseconds(500))

    #expect(reply == .nothing)
    #expect(ContinuousClock.now - started < .seconds(10))
    let pid = try await pid(in: pidFile)
    #expect(await isGone(pid))
  }

  @Test
  func aReadAbandonedByADeadlineStillTakesItsDialDown() async throws {
    let (invocation, pidFile) = try sleeper()

    let answer = await withDeadline(.milliseconds(500)) {
      await RemoteTranscriptProbe.run(invocation, timeout: .seconds(60))
    }

    #expect(answer == nil)
    let pid = try await pid(in: pidFile)
    #expect(await isGone(pid))
  }

  @Test
  func aRemoteReadPastItsOwnLimitIsKilled() async throws {
    let (invocation, pidFile) = try sleeper()
    let started = ContinuousClock.now

    let result = await ZmxSessionLauncher.collectRemoteOutput(
      invocation, timeout: .milliseconds(500))

    #expect(result.succeeded == false)
    #expect(ContinuousClock.now - started < .seconds(10))
    let pid = try await pid(in: pidFile)
    #expect(await isGone(pid))
  }

  @Test
  func aRemoteReadInsideItsLimitKeepsItsOutput() async {
    let result = await ZmxSessionLauncher.collectRemoteOutput(
      ["/bin/sh", "-c", "echo gc-reap-ok"], timeout: .seconds(10))

    #expect(result.succeeded)
    #expect(result.output.contains("gc-reap-ok"))
  }

  @Test
  func everyRemoteReadIsBoundedBelowThePresenceDeadline() {
    // The read must be reaped by its own limit before `GraphStore` stops waiting for it,
    // or the store's 45s deadline abandons a dial that is still running.
    #expect(ZmxSessionLauncher.remoteReadTimeout < .seconds(45))
  }
}
