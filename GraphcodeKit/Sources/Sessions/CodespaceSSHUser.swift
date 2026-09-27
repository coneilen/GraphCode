import Foundation

/// Learns and caches the ssh user a codespace is dialed as, which is all a reused
/// connection needs that the plain gh dial does not (`multiplexedCodespaceInvocation`).
///
/// Learned by the plain gh path the codespace just answered on — one `id -un` naming gh's
/// automatic key, so the key a reused connection offers is the one gh authorized — and
/// only after a dial succeeded, because gh starts a stopped codespace it is pointed at.
/// Forgotten when a dial fails, so a rebuilt devcontainer with a different user costs one
/// failure and one relearn rather than a codespace that can never be reached again.
actor CodespaceSSHUser {
  static let shared = CodespaceSSHUser()

  private var learning: Set<String> = []

  func learnIfNeeded(_ location: RemoteProjectLocation) async {
    guard location.isCodespace,
      FileManager.default.fileExists(atPath: RemoteProjectLocation.codespaceMultiplexFlag.path),
      location.multiplexedCodespaceUser == nil,
      learning.insert(location.host).inserted
    else { return }
    defer { learning.remove(location.host) }
    let (succeeded, output) = await ZmxSessionLauncher.collectRemoteOutput(
      Self.learnInvocation(for: location))
    guard succeeded, let user = Self.parseUser(output) else { return }
    let file = RemoteProjectLocation.codespaceUserFile(forCodespace: location.host)
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(user.utf8).write(to: file, options: .atomic)
  }

  static func forget(_ location: RemoteProjectLocation) {
    guard location.isCodespace else { return }
    try? FileManager.default.removeItem(
      at: RemoteProjectLocation.codespaceUserFile(forCodespace: location.host))
  }

  static func learnInvocation(for location: RemoteProjectLocation) -> [String] {
    [
      GhLocator.executablePath, "codespace", "ssh", "-c", location.host, "--",
      "-i", RemoteProjectLocation.codespaceIdentityFile,
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "id -un",
    ]
  }

  /// The last non-empty line: a login banner may print first, and over a PTY every line
  /// carries a carriage return.
  static func parseUser(_ output: String) -> String? {
    guard
      let line = output.split(whereSeparator: \.isNewline)
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .last(where: { !$0.isEmpty }),
      RemoteProjectLocation.isPlausibleSSHUser(line)
    else { return nil }
    return line
  }
}
