import Foundation
import Testing

@testable import GraphcodeKit

/// Copilot takes the graph briefing through `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` rather than
/// a read-this-file preamble. What every launch path has to carry for that to hold, since
/// the failure — a loop that never learns it is in a graph — is silent (issue #2).
@Suite
struct CopilotInstructionsDeliveryTests {
  private let variable = SessionBriefing.copilotInstructionsDirectoryVariable

  private func goalNode(_ backend: CLISessionBackendKind) -> LoopNode {
    LoopNode(
      title: "Copilot", loopType: .goalBased, goal: GoalSpec(summary: "work"), backend: backend)
  }

  @Test
  func theVariableIsTheDocumentedPluralSpelling() {
    // `COPILOT_CUSTOM_INSTRUCTION_DIRS` (singular) loads nothing, on every version measured.
    #expect(variable == "COPILOT_CUSTOM_INSTRUCTIONS_DIRS")
    #expect(SessionBriefing.copilotInstructionsFile.hasSuffix(".instructions.md"))
  }

  @Test
  func theLoginShellAppendsTheBriefingAfterTheUsersOwnDirectories() throws {
    let value = try #require(
      SessionBriefing.copilotInstructionsEnvironment(
        briefingPath: "/b/briefings/p/AGENTS.md")[variable])
    func expanded(existing: String?) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-f", "-c", "print -r -- \"\(value)\""]
      process.environment = existing.map { [variable: $0] } ?? [:]
      let output = Pipe()
      process.standardOutput = output
      try process.run()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
    }
    #expect(try expanded(existing: nil) == "/b/briefings/p")
    #expect(try expanded(existing: "") == "/b/briefings/p")
    #expect(try expanded(existing: "/mine,/theirs") == "/mine,/theirs,/b/briefings/p")
  }

  @Test
  func aRemoteBriefingIsFoundUnderTheHostsOwnHome() throws {
    // A double-quoted `~` never expands, and nothing local knows the remote home.
    let value = try #require(
      SessionBriefing.copilotInstructionsEnvironment(
        briefingPath: "~/.graphcode/briefings/p/AGENTS.md")[variable])
    #expect(value.hasSuffix(",}$HOME/.graphcode/briefings/p"))
  }

  @Test
  func onlyCopilotIsGivenTheVariable() {
    for backend in CLISessionBackendKind.allCases where backend != .copilotCLI {
      #expect(backend.briefingEnvironment(briefingPath: "/b/p/AGENTS.md").isEmpty, "\(backend)")
    }
    #expect(CLISessionBackendKind.copilotCLI.briefingEnvironment(briefingPath: nil).isEmpty)
  }

  @Test
  func theBriefingIsWrittenWhereCopilotSearches() throws {
    let url = try #require(SessionBriefing.write(projectPath: "/tmp/copilot-instructions"))
    let copy = url.deletingLastPathComponent()
      .appendingPathComponent(SessionBriefing.copilotInstructionsFile)
    #expect(
      try String(contentsOf: copy, encoding: .utf8) == String(contentsOf: url, encoding: .utf8))
  }

  @Test
  func aResumedCopilotLoopIsBriefedAgain() throws {
    // Measured: `--resume` rebuilds the system message from the resuming process's
    // environment, and drops the instructions when the variable is missing.
    let briefed = GraphcodeSettings(briefsSessionsAboutTheGraph: true)
    for projectPath in ["/tmp/copilot-instructions", "ssh://someone@box/~/project"] {
      let resumed = try #require(
        ZmxSessionLauncher.resumeArguments(
          forNode: goalNode(.copilotCLI), sessionID: "abc", projectPath: projectPath,
          settings: briefed))
      let script = try #require(resumed.first { $0.hasPrefix("exec ") })
      #expect(script.hasPrefix("exec env \(variable)=\""), "\(projectPath)")
      #expect(ZmxSessionLauncher.fitsInATypedCommandLine(resumed), "\(projectPath)")
    }
    let unbriefed = try #require(
      ZmxSessionLauncher.resumeArguments(
        forNode: goalNode(.copilotCLI), sessionID: "abc", projectPath: "/tmp/copilot-instructions",
        settings: GraphcodeSettings(briefsSessionsAboutTheGraph: false)))
    #expect(!unbriefed.contains { $0.contains(variable) })
  }

  @Test
  func aRemoteCopilotLoopIsDeliveredTheCopyItSearchesFor() throws {
    let location = try #require(
      RemoteProjectLocation.parse(projectPath: "ssh://someone@box/~/project"))
    let settings = GraphcodeSettings(briefsSessionsAboutTheGraph: true)
    let copy = RemoteGraphAccess.copilotInstructionsPath(forProjectPath: location.projectPath)
    #expect(
      ZmxSessionLauncher.remoteDeliveryFiles(
        forNode: goalNode(.copilotCLI), at: location, settings: settings)[copy] != nil)
    #expect(
      ZmxSessionLauncher.remoteDeliveryFiles(
        forNode: nil, backend: .copilotCLI, at: location, settings: settings)[copy] != nil)
    for backend in CLISessionBackendKind.allCases where backend != .copilotCLI {
      #expect(
        ZmxSessionLauncher.remoteDeliveryFiles(
          forNode: goalNode(backend), at: location, settings: settings)[copy] == nil)
    }
  }
}
