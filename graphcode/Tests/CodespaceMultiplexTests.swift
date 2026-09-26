import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// A Codespace dial that reuses one connection (issue #480): plain ssh with gh as its
/// `ProxyCommand`, so gh — and its Codespaces API call — runs only when a master has to
/// be established, not on every presence, activity and summary read.
@Suite
struct CodespaceMultiplexTests {
  private let codespace = RemoteProjectLocation(
    host: "fluffy-space-waddle", remotePath: "/workspaces/widget", isCodespace: true)

  private func option(_ name: String, in invocation: [String]) -> String? {
    invocation.first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
  }

  @Test
  func aKnownUserDialsPlainSSHThroughAReusedConnection() throws {
    let invocation = codespace.sshInvocation(
      remoteCommand: "zmx get x", interactive: false, codespaceUser: "codespace")

    #expect(invocation.first?.hasSuffix("ssh") == true)
    #expect(!invocation.contains("-t"))
    #expect(option("ControlMaster", in: invocation) == "auto")
    #expect(option("ControlPersist", in: invocation) == "43200")
    #expect(
      option("ControlPath", in: invocation)
        == "\(RemoteProjectLocation.controlSocketDirectory.path)/%C")
    #expect(option("User", in: invocation) == "codespace")
    #expect(option("BatchMode", in: invocation) == "yes")
    #expect(option("ServerAliveInterval", in: invocation) == "5")
    // The fixed destination is what makes `%C` — and so the master — match next time.
    let destination = try #require(invocation.firstIndex(of: "cs.fluffy-space-waddle"))
    #expect(invocation[destination + 1] == "--")
    #expect(invocation.last == "zmx get x")

    let proxy = try #require(option("ProxyCommand", in: invocation))
    #expect(proxy.contains("'codespace' 'ssh' '-c' 'fluffy-space-waddle' '--stdio'"))
    // Naming gh's automatic key is what makes gh create and authorize it, and ssh then
    // offers that same key.
    #expect(proxy.contains("'-i' '\(RemoteProjectLocation.codespaceIdentityFile)'"))
    #expect(option("IdentityFile", in: invocation) == RemoteProjectLocation.codespaceIdentityFile)
  }

  @Test
  func anInteractiveSurfaceStillGetsATTY() {
    let invocation = codespace.sshInvocation(
      remoteCommand: "zmx attach x", interactive: true, codespaceUser: "codespace")

    #expect(invocation.dropFirst().first == "-t")
  }

  @Test
  func anUnknownUserKeepsThePlainGhDial() {
    let invocation = codespace.sshInvocation(
      remoteCommand: "zmx get x", interactive: false, codespaceUser: nil)

    #expect(
      Array(invocation.prefix(6)) == [
        GhLocator.executablePath, "codespace", "ssh", "-c", "fluffy-space-waddle", "--",
      ])
    #expect(!invocation.contains { $0.hasPrefix("ControlMaster") })
  }

  @Test
  func plainSSHHostsIgnoreTheCodespaceUser() {
    let host = RemoteProjectLocation(user: "dev", host: "build-box", remotePath: "/srv")

    let invocation = host.sshInvocation(
      remoteCommand: "true", interactive: false, codespaceUser: "codespace")

    #expect(invocation.contains("dev@build-box"))
    #expect(!invocation.contains { $0.hasPrefix("ProxyCommand") })
  }

  @Test
  func openSSHResolvesTheReusedDialAsIntended() async throws {
    // `ssh -G` resolves the configuration without connecting: proof the options survive
    // OpenSSH's own parser, quoting included, rather than only our string building.
    let invocation = codespace.sshInvocation(
      remoteCommand: "true", interactive: false, codespaceUser: "codespace")
    let separator = try #require(invocation.firstIndex(of: "--"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: invocation[0])
    process.arguments = ["-G"] + Array(invocation[1..<separator])
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    process.waitUntilExit()
    let lines = Set((output ?? "").split(whereSeparator: \.isNewline).map(String.init))

    #expect(process.terminationStatus == 0)
    #expect(lines.contains("user codespace"))
    #expect(lines.contains("hostname cs.fluffy-space-waddle"))
    #expect(lines.contains("controlmaster auto"))
    #expect(lines.contains("batchmode yes"))
    let proxy = try #require(lines.first { $0.hasPrefix("proxycommand ") })
    #expect(proxy.contains("--stdio"))
    #expect(proxy.contains("'fluffy-space-waddle'"))
  }

  // MARK: - Learning the user

  @Test
  func theUserIsLearnedOverThePlainGhDialWithGhsAutomaticKey() {
    let invocation = CodespaceSSHUser.learnInvocation(for: codespace)

    #expect(
      Array(invocation.prefix(6)) == [
        GhLocator.executablePath, "codespace", "ssh", "-c", "fluffy-space-waddle", "--",
      ])
    #expect(invocation.contains(RemoteProjectLocation.codespaceIdentityFile))
    #expect(invocation.last == "id -un")
  }

  @Test
  func theLearnedUserIsTheReplysLastPlausibleLine() {
    #expect(CodespaceSSHUser.parseUser("Welcome to Codespaces!\r\ncodespace\r\n") == "codespace")
    #expect(CodespaceSSHUser.parseUser("vscode") == "vscode")
    #expect(CodespaceSSHUser.parseUser("") == nil)
    #expect(CodespaceSSHUser.parseUser("rm -rf ~") == nil)
    #expect(CodespaceSSHUser.parseUser("a;b") == nil)
    #expect(CodespaceSSHUser.parseUser("-oProxyCommand=x") == nil)
  }

  // MARK: - The ramp

  @Test
  func theRampShipsToBetaOnly() {
    #expect(
      FeatureRamps.Feature.codespaceMultiplex.defaultPercents == ["beta": 100, "stable": 0])
  }

  @Test
  func theRampIsMirroredIntoTheDaemonsFlag() throws {
    let flag = FileManager.default.temporaryDirectory
      .appendingPathComponent("ramp-\(UUID().uuidString)/codespace-dials/multiplex.on")

    FeatureRamps.publishCodespaceMultiplexFlag(enabled: true, flag: flag)
    #expect(FileManager.default.fileExists(atPath: flag.path))

    FeatureRamps.publishCodespaceMultiplexFlag(enabled: false, flag: flag)
    #expect(!FileManager.default.fileExists(atPath: flag.path))
  }
}
