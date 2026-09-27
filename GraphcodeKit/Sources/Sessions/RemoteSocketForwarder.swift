import Foundation

/// Keeps one `ssh -N -R` alive per remote host, putting the local daemon's socket at
/// the *canonical* path on that host — `~/.graphcode/graphcoded.sock` — so the
/// delivered `graphcode` shim needs no configuration to find it: the same default dial
/// as a local CLI, just answered from across the wire.
///
/// A dedicated persistent connection rather than `-R` on the launch dial, because the
/// dial exits the moment `zmx run` returns and a remote forward lives exactly as long
/// as the connection carrying it. The loop's session outlives every ssh graphcode
/// makes; only a process whose whole job is to stay connected can keep the socket
/// there while the loop works.
///
/// The wrapping shell loop handles the two ways this dies in practice: a dropped
/// connection (retry after a beat, same posture as `SSHReconnectLoop`) and a stale
/// socket left by a crash — sshd refuses to bind over one and, unlike the client-side
/// `StreamLocalBindUnlink`, offers no client-controllable unlink, so each attempt
/// removes the old socket in a short pre-dial and fails fast (`ExitOnForwardFailure`)
/// rather than connecting uselessly. That pre-dial also answers where the socket may
/// bind: `-R` needs an absolute path and nothing local knows the remote home, so the
/// same round-trip prints `$HOME`. The `kill -0 $PPID` guard stops the loop from
/// outliving the daemon that spawned it — a forwarder orphaned by a daemon restart
/// would otherwise fight the replacement's for the bind forever.
public actor RemoteSocketForwarder {
  public static let shared = RemoteSocketForwarder()

  private var forwarders: [String: Process] = [:]

  /// Starts the forwarder for this host unless one is already running. Failures are
  /// quiet on purpose: with no forward, the remote shim's own error says the daemon
  /// is unreachable and why, which is more diagnosable than anything a launcher with
  /// no UI could do from here.
  public func ensureForwarding(to location: RemoteProjectLocation) {
    #if os(Windows)
      _ = location
      return
    #else
      let key = location.authority
      if let existing = forwarders[key], existing.isRunning { return }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [
        "-c", Self.forwardScript(for: location, localSocketPath: DaemonSocketPath.url.path),
      ]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do {
        try process.run()
        forwarders[key] = process
      } catch {}
    #endif
  }

  static func forwardScript(for location: RemoteProjectLocation, localSocketPath: String)
    -> String
  {
    let prepare = location.sshCommandLine(
      remoteCommand: "mkdir -p \"$HOME/.graphcode\" && rm -f"
        + " \"$HOME/.graphcode/graphcoded.sock\""
        + " \"$HOME/.graphcode/bridge-state.json\""
        + " \"$HOME/.graphcode/bridge-state-generation\""
        + " \"$HOME/.graphcode/bridge-state.json.lock\""
        + " && printf %s \"$HOME\"")
    let forward = forwardCommandLine(for: location, localSocketPath: localSocketPath)
    if location.isCodespace {
      return codespaceForwardScript(prepare: prepare, forward: forward)
    }
    return """
      while kill -0 $PPID 2>/dev/null; do \
      H=$(\(prepare)) || { sleep 5; continue; }; \
      \(forward); \
      sleep 5; \
      done
      """
  }

  /// A codespace's loop backs off instead of redialing every five seconds, and gives up
  /// once the codespace has been down for `schedule.pauseAfter` — each attempt is two gh
  /// runs against the human's Codespaces rate limit (issue #480). `ensureForwarding`
  /// starts a fresh one on the next ensure, which `CodespaceDialBreaker` lets through only
  /// on its schedule.
  ///
  /// Only a forward that stayed up past `upAfter` proves the codespace was reachable: a
  /// pre-dial can spend up to five minutes inside gh waiting for a codespace to start and
  /// still fail.
  static func codespaceForwardScript(
    prepare: String, forward: String,
    schedule: CodespaceDialSchedule = .standard, upAfter: Int = 60, maxWait: Int = 60
  ) -> String {
    """
    gc_down=; gc_wait=5; \
    while kill -0 $PPID 2>/dev/null; do \
    if H=$(\(prepare)); then \
    gc_t=$(date +%s); \(forward); \
    [ $(($(date +%s) - gc_t)) -ge \(upAfter) ] && { gc_down=; gc_wait=5; }; \
    fi; \
    gc_now=$(date +%s); gc_down=${gc_down:-$gc_now}; \
    [ $((gc_now - gc_down)) -ge \(schedule.pauseAfter) ] && exit 0; \
    sleep $gc_wait; gc_wait=$((gc_wait * 2)); \
    [ $gc_wait -gt \(maxWait) ] && gc_wait=\(maxWait); \
    done
    """
  }

  /// The `ssh -N -R` line itself, with the remote socket path assembled around the
  /// `$H` the pre-dial captured — which is why this is a shell line and not an argv.
  /// Public for the tests that pin the codespace/ssh split of the dial.
  public static func forwardCommandLine(
    for location: RemoteProjectLocation, localSocketPath: String
  )
    -> String
  {
    var argv: [String]
    if location.isCodespace {
      // gh names the destination itself; `-N` and the forward ride through as
      // ssh-flags, past the `--`.
      argv = [GhLocator.executablePath, "codespace", "ssh", "-c", location.host, "--"]
    } else {
      argv = [SSHExecutableResolver.executableURL()?.path ?? "ssh"]
    }
    argv += [
      "-N",
      "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
    ]
    if !location.isCodespace, let port = location.port { argv += ["-p", String(port)] }
    var quoted =
      argv.map(RemoteProjectLocation.shellQuoted) + [
        "-R",
        "\"$H\""
          + RemoteProjectLocation.shellQuoted("/.graphcode/graphcoded.sock:" + localSocketPath),
      ]
    if !location.isCodespace {
      quoted.append(RemoteProjectLocation.shellQuoted(location.sshDestination))
    }
    return quoted.joined(separator: " ")
  }
}
