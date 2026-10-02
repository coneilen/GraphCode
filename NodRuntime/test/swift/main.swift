import Foundation

// Decodes events.jsonl written by the TypeScript runtime with the app's own NodProtocol, and
// prints NodCommand JSON encoded by Swift for the TypeScript parser to read back.
let arguments = CommandLine.arguments
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let decoder = NodProtocol.makeDecoder()
var failures = 0
for line in data.split(separator: UInt8(ascii: "\n")) {
  do {
    let record = try decoder.decode(NodEventRecord.self, from: Data(line))
    if case .unknown(let type) = record.event {
      print("UNKNOWN \(type)")
      failures += 1
    } else {
      print("OK \(record.seq) \(record.event.type)")
    }
  } catch {
    print("FAIL \(String(decoding: line, as: UTF8.self)) \(error)")
    failures += 1
  }
}
let encoder = NodProtocol.makeEncoder()
let commands: [NodCommand] = [
  .send(.init(text: "hi", delivery: .steer, attachments: [.init(kind: .loopTranscript, reference: "A1", label: "Pricing")])),
  .stop,
  .resolveHunk(.init(hunkID: "h1", decision: .comment, note: "use 51")),
  .resolvePermission(.init(askID: "p1", decision: .alwaysAllow)),
  .runPlan(.init(planID: "p", steps: [.init(id: "1", text: "do", files: ["A.swift"], size: .small, editedByHuman: true)], mode: .here)),
  .fork(.init(messageID: "m")),
  .sendDraft(.init(draftID: "d", text: "402")),
  .compact,
  .setModel(.init(model: "opus")),
  .markGoalDone,
]
for command in commands {
  print("CMD " + String(decoding: try encoder.encode(command), as: UTF8.self))
}
exit(failures == 0 ? 0 : 1)
