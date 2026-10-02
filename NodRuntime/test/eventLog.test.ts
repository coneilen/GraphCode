import { describe, expect, test } from "bun:test";
import { appendFileSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventLog, lastSeq } from "../src/eventLog";
import { parseCommand, wireDate } from "../src/protocol";

function tempLog(): string {
  return join(mkdtempSync(join(tmpdir(), "nod-log-")), "events.jsonl");
}

function lines(path: string): Record<string, unknown>[] {
  return readFileSync(path, "utf8").trim().split("\n").map((line) => JSON.parse(line));
}

describe("EventLog", () => {
  test("appends one record per line with v, strictly increasing seq and a second-precision date", () => {
    const path = tempLog();
    const log = new EventLog(path, () => new Date("2026-10-01T20:00:00.123Z"));
    log.append({ type: "turnStarted", turn: 1, origin: "user" });
    log.append({ type: "activity", line: "Reading Routes.swift · turn 1" });
    const records = lines(path);
    expect(records).toEqual([
      { v: 1, seq: 1, at: "2026-10-01T20:00:00Z", type: "turnStarted", turn: 1, origin: "user" },
      { v: 1, seq: 2, at: "2026-10-01T20:00:00Z", type: "activity", line: "Reading Routes.swift · turn 1" },
    ]);
  });

  test("leaves optional fields out rather than writing null", () => {
    const path = tempLog();
    new EventLog(path).append({ type: "hunkResolved", hunkID: "h1", decision: "accept", note: undefined });
    expect(readFileSync(path, "utf8")).not.toContain("note");
  });

  test("a resumed runtime continues the numbering of the file it appends to", () => {
    const path = tempLog();
    const first = new EventLog(path);
    first.append({ type: "activity", line: "a" });
    first.append({ type: "activity", line: "b" });
    const second = new EventLog(path);
    expect(second.lastSeq).toBe(2);
    expect(second.append({ type: "activity", line: "c" }).seq).toBe(3);
  });

  test("a torn final line is skipped for numbering and does not swallow the next record", () => {
    const path = tempLog();
    new EventLog(path).append({ type: "activity", line: "whole" });
    appendFileSync(path, '{"v":1,"seq":2,"at":"2026-10-01T20:0');
    const log = new EventLog(path);
    expect(log.lastSeq).toBe(1);
    log.append({ type: "activity", line: "after" });
    const text = readFileSync(path, "utf8").split("\n");
    expect(JSON.parse(text[2]!)).toMatchObject({ seq: 2, line: "after" });
  });

  test("finds the last seq even when one record outgrows the tail window", () => {
    const path = tempLog();
    const log = new EventLog(path);
    log.append({ type: "activity", line: "small" });
    log.append({ type: "toolResult", callID: "c1", status: "ok", summary: "big", output: "x".repeat(200_000) });
    expect(new EventLog(path).lastSeq).toBe(2);
  });

  test("lastSeq ignores foreign lines", () => {
    expect(lastSeq('garbage\n{"seq":4}\n{"seq":"9"}\n{"seq":3}\n')).toBe(4);
  });

  test("notifies listeners with the record it wrote", () => {
    const log = new EventLog(tempLog());
    const seen: number[] = [];
    log.onRecord((record) => seen.push(record.seq));
    log.append({ type: "activity", line: "x" });
    expect(seen).toEqual([1]);
  });

  test("wireDate drops milliseconds, as PROTOCOL.md writes dates", () => {
    expect(wireDate(new Date("2026-10-01T20:00:04.999Z"))).toBe("2026-10-01T20:00:04Z");
  });
});

describe("parseCommand", () => {
  test("reads every command type with its fields flattened beside type", () => {
    expect(parseCommand('{"type":"send","text":"hi","delivery":"steer","attachments":[{"kind":"file","reference":"a.swift"}]}')).toEqual({
      type: "send",
      text: "hi",
      delivery: "steer",
      attachments: [{ kind: "file", reference: "a.swift", label: undefined }],
    });
    expect(parseCommand('{"type":"stop"}')).toEqual({ type: "stop" });
    expect(parseCommand('{"type":"resolveHunk","hunkID":"h1","decision":"comment","note":"use 51"}')).toEqual({
      type: "resolveHunk",
      hunkID: "h1",
      decision: "comment",
      note: "use 51",
    });
    expect(parseCommand('{"type":"resolvePermission","askID":"p1","decision":"alwaysAllow"}')).toMatchObject({ decision: "alwaysAllow" });
    expect(parseCommand('{"type":"setModel","model":"opus"}')).toEqual({ type: "setModel", model: "opus" });
    expect(parseCommand('{"type":"markGoalDone","extra":1}')).toEqual({ type: "markGoalDone" });
    expect(parseCommand('{"type":"runPlan","planID":"p","mode":"here","steps":[{"id":"1","text":"do"}]}')).toMatchObject({
      steps: [{ id: "1", text: "do", files: [], editedByHuman: false }],
    });
  });

  test("defaults a send's delivery to queue and attachments to none", () => {
    expect(parseCommand('{"type":"send","text":"hi"}')).toEqual({ type: "send", text: "hi", delivery: "queue", attachments: [] });
  });

  test("rejects unknown types, bad enums and missing fields", () => {
    expect(() => parseCommand('{"type":"explode"}')).toThrow("unknown Nod command explode");
    expect(() => parseCommand('{"type":"resolveHunk","hunkID":"h1","decision":"maybe"}')).toThrow("bad decision");
    expect(() => parseCommand('{"type":"send"}')).toThrow("missing text");
    expect(() => parseCommand("not json")).toThrow("not JSON");
    expect(() => parseCommand("[1]")).toThrow("not an object");
  });
});

test("fixture lines from PROTOCOL.md round-trip unchanged", () => {
  const path = tempLog();
  const fixture =
    '{"v":1,"seq":1,"at":"2026-10-01T20:00:00Z","type":"sessionStarted","engine":"claude","model":"sonnet","conversationID":"8c1","resumed":false}\n';
  writeFileSync(path, fixture);
  expect(new EventLog(path).lastSeq).toBe(1);
});
