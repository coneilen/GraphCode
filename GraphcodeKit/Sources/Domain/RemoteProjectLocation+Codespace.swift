import Foundation

/// A Codespace dial that reuses one connection (issue #480).
///
/// `gh codespace ssh -- <command>` spends a Codespaces API call on every run, and gh opens
/// its tunnel on a random local port, so an ssh `ControlMaster` behind it never matched
/// again. Every presence, activity and summary read was therefore a fresh gh run against
/// the human's per-user rate limit. Plain `ssh` with gh as its `ProxyCommand` — the shape
/// `gh codespace ssh --config` itself writes — fixes the destination at `cs.<name>`, so
/// `%C` is stable and every dial after the first is a channel on the master: gh runs only
/// when a master has to be (re)established.
///
/// It needs the codespace's ssh user, which gh learns inside its tunnel and never prints.
/// `CodespaceSSHUser` learns it once per codespace with one gh dial and caches it; until
/// then, and whenever the `codespaceMultiplex` ramp is off (the app mirrors it into
/// `codespaceMultiplexFlag`), dials take the plain gh path.
extension RemoteProjectLocation {
  public static var codespaceStateDirectory: URL {
    SupportDirectory.url.appendingPathComponent("codespace-dials", isDirectory: true)
  }

  public static var codespaceMultiplexFlag: URL {
    codespaceStateDirectory.appendingPathComponent("multiplex.on")
  }

  static func codespaceUserFile(forCodespace name: String) -> URL {
    codespaceStateDirectory.appendingPathComponent("\(name).user")
  }

  /// gh's automatic key. Naming it with `-i` is what makes gh create it if missing and
  /// authorize it in the codespace, so ssh can then offer the same key itself.
  static var codespaceIdentityFile: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ssh/codespaces.auto").path
  }

  /// The user to dial as over a reused connection, or `nil` for the plain gh path.
  var multiplexedCodespaceUser: String? {
    guard isCodespace,
      FileManager.default.fileExists(atPath: Self.codespaceMultiplexFlag.path),
      let text = try? String(
        contentsOf: Self.codespaceUserFile(forCodespace: host), encoding: .utf8)
    else { return nil }
    let user = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return Self.isPlausibleSSHUser(user) ? user : nil
  }

  static func isPlausibleSSHUser(_ user: String) -> Bool {
    SafeArgument.isSafeSSHComponent(user)
      && user.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
      }
  }

  /// Host keys are not checked, as in gh's own `--config`: the host is reached only
  /// through gh's authenticated tunnel, and a codespace's host key changes on rebuild.
  /// `ConnectTimeout` also bounds the `ProxyCommand` (measured: OpenSSH 10.3 exits 255
  /// and reaps it), so a codespace that is still starting costs seconds of gh polling
  /// per attempt rather than gh's five-minute wait.
  func multiplexedCodespaceInvocation(
    user: String, remoteCommand: String, interactive: Bool
  ) -> [String] {
    let key = Self.codespaceIdentityFile
    let proxy = [
      GhLocator.executablePath, "codespace", "ssh", "-c", host, "--stdio", "--", "-i", key,
    ]
    .map(Self.shellQuoted).joined(separator: " ")
    var invocation = [SSHExecutableResolver.executableURL()?.path ?? "ssh"]
    if interactive { invocation.append("-t") }
    invocation += [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
      "-o", "ControlMaster=auto", "-o", "ControlPath=\(Self.controlSocketDirectory.path)/%C",
      "-o", "ControlPersist=43200",
      "-o", "ProxyCommand=\(proxy.replacingOccurrences(of: "%", with: "%%"))",
      "-o", "User=\(user)", "-o", "IdentityFile=\(key)", "-o", "IdentitiesOnly=yes",
      "-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no",
      "-o", "LogLevel=ERROR",
      "cs.\(host)", "--", remoteCommand,
    ]
    return invocation
  }
}
