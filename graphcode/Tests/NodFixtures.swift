import Foundation
import GraphcodeKit

@testable import graphcode

/// Builds `events.jsonl` records the way the runtime writes them — JSON on the wire, so
/// the tests go through the same decoder the pane does and never need the payloads'
/// (internal) memberwise inits.
struct NodLog {
  private(set) var records: [NodEventRecord] = []
  private var seq = 0
  private var clock: Date

  init(startingAt start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
    clock = start
  }

  /// The next run of the same runtime: seq starts again, the clock carries on.
  init(after previous: NodLog) {
    clock = previous.clock + 60
  }

  @discardableResult
  mutating func add(_ type: String, _ fields: [String: Any] = [:]) -> NodEventRecord {
    seq += 1
    clock += 1
    var object = fields
    object["v"] = 1
    object["seq"] = seq
    object["at"] = ISO8601DateFormatter().string(from: clock)
    object["type"] = type
    let data = try! JSONSerialization.data(withJSONObject: object)
    let record = try! NodProtocol.makeDecoder().decode(NodEventRecord.self, from: data)
    records.append(record)
    return record
  }

  var jsonLines: Data {
    let encoder = NodProtocol.makeEncoder()
    return records.reduce(into: Data()) { data, record in
      data.append(try! encoder.encode(record))
      data.append(UInt8(ascii: "\n"))
    }
  }

  var transcript: NodTranscript { NodTranscript(replaying: records) }

  mutating func session(model: String = "claude-sonnet-4-5", engine: String = "claude") {
    add(
      "sessionStarted",
      ["engine": engine, "model": model, "conversationID": "c-1", "resumed": false])
  }

  mutating func user(_ text: String, id: String, delivery: String = "queue") {
    add("userMessage", ["id": id, "text": text, "delivery": delivery, "attachments": []])
  }

  mutating func turn(_ number: Int, origin: String = "user") {
    add("turnStarted", ["turn": number, "origin": origin])
  }

  mutating func say(_ text: String, turn: Int, id: String, final: Bool = true) {
    add("assistantText", ["turn": turn, "messageID": id, "delta": text, "final": final])
  }

  mutating func tool(
    _ id: String, turn: Int, tool: String, title: String, status: String? = "ok",
    summary: String = "", output: String? = nil, ms: Int? = nil
  ) {
    add("toolCall", ["turn": turn, "callID": id, "tool": tool, "title": title])
    guard let status else { return }
    var result: [String: Any] = ["callID": id, "status": status, "summary": summary]
    if let output { result["output"] = output }
    if let ms { result["durationMs"] = ms }
    add("toolResult", result)
  }

  mutating func hunk(
    _ id: String, turn: Int, file: String, header: String, diff: String, added: Int,
    removed: Int, auto: Bool = false
  ) {
    add(
      "hunkStaged",
      [
        "turn": turn, "hunkID": id, "file": file, "header": header, "diff": diff,
        "added": added, "removed": removed, "autoAccepted": auto,
      ])
  }

  mutating func ask(_ id: String, kind: String = "shell", subject: String, reason: String) {
    add(
      "permissionAsked",
      [
        "askID": id, "kind": kind, "subject": subject, "reason": reason,
        "answerableFromCard": false,
      ])
  }

  mutating func goalCheck(turn: Int, met: Bool, clauses: [(String, Bool, String?)]) {
    add(
      "goalCheck",
      [
        "turn": turn, "evaluatorModel": "claude-haiku-4-5", "met": met,
        "clauses": clauses.map { text, met, evidence -> [String: Any] in
          var clause: [String: Any] = ["text": text, "met": met]
          if let evidence { clause["evidence"] = evidence }
          return clause
        },
      ])
  }

  mutating func endTurn(_ number: Int, files: Int = 0, added: Int = 0, removed: Int = 0) {
    add("turnEnded", ["turn": number, "filesChanged": files, "added": added, "removed": removed])
  }

  mutating func usage(cost: Double? = nil, premium: Int? = nil, context: Double) {
    var fields: [String: Any] = ["inputTokens": 1000, "outputTokens": 200, "contextUsed": context]
    if let cost { fields["costUSD"] = cost }
    if let premium { fields["premiumRequests"] = premium }
    add("usage", fields)
  }

  mutating func failure(_ kind: String, _ message: String) {
    add("failure", ["kind": kind, "message": message])
  }

  /// The design's running example (1a): a Goal loop fixing the /export usage cap, in turn
  /// 2 with a staged hunk, a test run in flight and a note queued behind it.
  static var monetization: NodLog {
    var log = NodLog()
    log.session()
    log.user(
      "The cap isn't enforced on /export. Fix it and add a test that hits the limit.", id: "u1")
    log.turn(1)
    log.say(
      "Found it. `ExportRoute` is registered before `UsageGate` runs, so the middleware never sees it.",
      turn: 1, id: "m1")
    log.tool(
      "c1", turn: 1, tool: "Read", title: "Read UsageGate.swift", summary: "84 lines", ms: 120)
    log.tool(
      "c2", turn: 1, tool: "Grep", title: "Search \"UsageGate\"", summary: "6 hits in 4 files",
      ms: 400)
    log.hunk(
      "h1", turn: 1, file: "Sources/Server/Routes.swift",
      header: "@@ 41,6 @@ func routes(_ app: Application)",
      diff: """
          let paid = app.grouped(UsageGate())
        - app.post("export", use: ExportRoute.handle)
        + paid.post("export", use: ExportRoute.handle)
        + // export counts toward the cap like every paid route
        """, added: 3, removed: 1)
    log.tool(
      "c3", turn: 1, tool: "Bash", title: "swift test --filter UsageCap", status: "ok",
      summary: "exit 0",
      output: """
        Test Suite 'UsageCapTests' started
        ✓ testPaidRoutesAreGated (0.02s)
        ✓ testExportBlocksPastCap (0.04s)
        ✓ testCapResetsMonthly (0.01s)
        Executed 3 tests, with 0 failures
        """, ms: 14000)
    log.goalCheck(
      turn: 1, met: false,
      clauses: [
        ("Every paid route goes through UsageGate", true, "4 / 4 routes"),
        ("swift test passes", false, "1 failure · LegacyExportTests"),
      ])
    log.endTurn(1, files: 1, added: 3, removed: 1)
    log.usage(cost: 0.42, context: 0.31)
    log.turn(2, origin: "goalCheck")
    log.say("LegacyExportTests still posts to /export without a plan. Updating it.", turn: 2, id: "m2")
    log.ask(
      "a1", subject: "swift package resolve",
      reason: "Fetches dependencies over the network. Not in this project's allowlist.")
    log.tool("c4", turn: 2, tool: "Bash", title: "swift test --filter UsageCap", status: "running")
    log.add("activity", ["line": "Running swift test --filter UsageCap · 14s"])
    log.user("also log when a request is blocked", id: "u2")
    return log
  }
}
