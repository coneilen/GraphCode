import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventLog } from "../src/eventLog";
import { parseCommand, type NodEvent } from "../src/protocol";

const protocolSwift = join(import.meta.dir, "..", "..", "GraphcodeKit", "Sources", "Domain", "NodProtocol.swift");
const swiftc = Bun.which("swiftc");

const everyEvent: NodEvent[] = [
  { type: "sessionStarted", engine: "copilot", model: "gpt-5", conversationID: "c", resumed: true },
  { type: "turnStarted", turn: 1, origin: "goalCheck" },
  { type: "userMessage", id: "u", text: "hi", delivery: "queue", attachments: [{ kind: "file", reference: "A.swift" }], fromNodeID: "9B3408F9-9B16-447F-A439-FC2AA8C02D06" },
  { type: "assistantText", turn: 1, messageID: "m", delta: "Found it.", final: true },
  { type: "toolCall", turn: 1, callID: "c1", tool: "Grep", title: 'Search "UsageGate"' },
  { type: "toolResult", callID: "c1", status: "ok", summary: "6 hits", output: "…", durationMs: 400 },
  { type: "hunkStaged", turn: 1, hunkID: "h1", file: "A.swift", header: "@@ -1,1 +1,1 @@", diff: "@@\n-a\n+b", added: 1, removed: 1, autoAccepted: false },
  { type: "hunkResolved", hunkID: "h1", decision: "comment", note: "use 51" },
  { type: "permissionAsked", askID: "p1", kind: "editOutsideWorktree", subject: "/etc/hosts", reason: "r", answerableFromCard: false },
  { type: "permissionResolved", askID: "p1", decision: "alwaysAllow" },
  { type: "goalCheck", turn: 1, evaluatorModel: "haiku", clauses: [{ text: "a", met: true, evidence: "e" }, { text: "b", met: false }], met: false },
  { type: "turnEnded", turn: 1, filesChanged: 1, added: 2, removed: 1, summary: "s" },
  { type: "usage", inputTokens: 10, outputTokens: 5, costUSD: 0.01, premiumRequests: 1, contextUsed: 0.42 },
  { type: "planProposed", planID: "p", title: "t", steps: [{ id: "1", text: "x", files: [], editedByHuman: false }] },
  { type: "mailDraft", draftID: "d", toNodeID: "9B3408F9-9B16-447F-A439-FC2AA8C02D06", text: "402" },
  { type: "compacted", fromTurn: 1, throughTurn: 9 },
  { type: "activity", line: "Running swift test · turn 4" },
  { type: "failure", kind: "spendCap", message: "m" },
];

test.skipIf(!swiftc)(
  "the app's NodProtocol.swift decodes every event the runtime writes, and the runtime parses every command the app sends",
  () => {
    const dir = mkdtempSync(join(tmpdir(), "nod-contract-"));
    const log = new EventLog(join(dir, "events.jsonl"));
    for (const event of everyEvent) log.append(event);
    const binary = join(dir, "contract");
    const build = Bun.spawnSync([swiftc!, "-O", "-module-name", "Contract", protocolSwift, join(import.meta.dir, "swift", "main.swift"), "-o", binary]);
    expect(build.stderr.toString()).not.toContain("error:");
    expect(build.exitCode).toBe(0);
    const run = Bun.spawnSync([binary, log.path]);
    const out = run.stdout.toString().trim().split("\n");
    expect(out.filter((l) => !l.startsWith("OK") && !l.startsWith("CMD"))).toEqual([]);
    expect(out.filter((l) => l.startsWith("OK")).length).toBe(everyEvent.length);
    expect(run.exitCode).toBe(0);
    const commands = out.filter((l) => l.startsWith("CMD ")).map((l) => parseCommand(l.slice(4)));
    expect(commands.map((c) => c.type)).toEqual([
      "send", "stop", "resolveHunk", "resolvePermission", "runPlan", "fork", "sendDraft", "compact", "setModel", "markGoalDone",
    ]);
    expect(commands[0]).toMatchObject({ delivery: "steer", attachments: [{ kind: "loopTranscript", reference: "A1", label: "Pricing" }] });
    expect(commands[4]).toMatchObject({ steps: [{ files: ["A.swift"], size: "small", editedByHuman: true }] });
  },
  180_000,
);
