import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applyHunk, diffLines, hunks, HunkConflict, hunkStats } from "../src/diff";
import { EventLog } from "../src/eventLog";
import { HunkStager } from "../src/hunks";
import type { NodEventRecord } from "../src/protocol";
import { tick } from "./fakeEngine";

const base = Array.from({ length: 40 }, (_, i) => `line ${i + 1}`).join("\n") + "\n";

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "nod-hunks-"));
  const log = new EventLog(join(dir, ".nod", "events.jsonl"));
  const records: NodEventRecord[] = [];
  log.onRecord((r) => records.push(r));
  const file = join(dir, "Sources", "Routes.swift");
  return { dir, log, records, file, stager: new HunkStager(log, dir) };
}

function edit(text: string, replacements: [string, string][]): string {
  return replacements.reduce((acc, [from, to]) => acc.replace(from, to), text);
}

describe("diff", () => {
  test("applying every hunk in turn reproduces the edited text", () => {
    const after = edit(base, [["line 3\n", "line 3\ninserted\n"], ["line 30\n", ""], ["line 38", "changed 38"]]);
    const found = hunks(base, after);
    expect(found.length).toBe(3);
    expect(found.reduce((text, hunk) => applyHunk(text, hunk), base)).toBe(after);
  });

  test("nearby changes share one hunk, as git groups them", () => {
    const after = edit(base, [["line 10", "ten"], ["line 13", "thirteen"]]);
    const [only, ...rest] = hunks(base, after);
    expect(rest).toEqual([]);
    expect(only!.lines.filter((l) => l[0] !== " ")).toEqual(["-line 10", "+ten", "-line 13", "+thirteen"]);
    expect(only!.oldStart).toBe(7);
  });

  test("a hunk applies wherever its context now sits, and reverses cleanly", () => {
    const after = edit(base, [["line 20", "twenty"]]);
    const [hunk] = hunks(base, after);
    const shifted = "new top\nnew top 2\n" + base;
    const applied = applyHunk(shifted, hunk!);
    expect(applied).toBe("new top\nnew top 2\n" + after);
    expect(applyHunk(applied, hunk!, true)).toBe(shifted);
  });

  test("a hunk whose lines are gone is a conflict", () => {
    const [hunk] = hunks(base, edit(base, [["line 20", "twenty"]]));
    expect(() => applyHunk("something else entirely\n", hunk!)).toThrow(HunkConflict);
  });

  test("creating a file is one hunk of additions", () => {
    const [hunk] = hunks("", "a\nb\n");
    expect(hunk!.lines).toEqual(["+a", "+b", "+"]);
    expect(hunks("", "hello nod").map((h) => [h.oldLines, h.newLines])).toEqual([[0, 1]]);
    expect(hunkStats(hunk!)).toEqual({ added: 2, removed: 0 });
    expect(hunkStats(hunks("a\n\n", "")[0]!)).toEqual({ added: 0, removed: 2 });
    expect(applyHunk("", hunk!)).toBe("a\nb\n");
  });

  test("Myers finds a minimal edit script", () => {
    const ops = diffLines(["a", "b", "c", "a", "b", "b", "a"], ["c", "b", "a", "b", "a", "c"]);
    expect(ops.filter((op) => op.kind !== " ").length).toBe(5);
  });
});

describe("HunkStager", () => {
  function seed(file: string, text = base): void {
    mkdirSync(join(file, ".."), { recursive: true });
    writeFileSync(file, text);
  }

  test("review mode writes nothing until every hunk is decided; all accepted, the tool writes", async () => {
    const { stager, file, records } = setup();
    seed(file);
    const after = edit(base, [["line 3", "three"], ["line 30", "thirty"]]);
    let settled = false;
    const outcome = stager.stageEdit(file, after, 1, false).then((o) => ((settled = true), o));
    const staged = records.filter((r) => r.type === "hunkStaged");
    expect(staged.map((r) => r.type === "hunkStaged" && [r.hunkID, r.file, r.added, r.removed, r.autoAccepted])).toEqual([
      ["h1", "Sources/Routes.swift", 1, 1, false],
      ["h2", "Sources/Routes.swift", 1, 1, false],
    ]);
    stager.resolve("h1", "accept");
    await tick(5);
    expect(settled).toBe(false);
    expect(readFileSync(file, "utf8")).toBe(base);
    stager.resolve("h2", "accept");
    const result = await outcome;
    expect(result.allAccepted).toBe(true);
    expect(result.feedback).toBe("");
    // Nothing written by the stager: the engine's own tool writes the whole edit.
    expect(readFileSync(file, "utf8")).toBe(base);
    expect(stager.tally(1)).toEqual({ filesChanged: 1, added: 2, removed: 2 });
  });

  test("a partial accept writes only the accepted hunks and tells the agent about the rest", async () => {
    const { stager, file, records } = setup();
    seed(file);
    const after = edit(base, [["line 3", "three"], ["line 30", "thirty"]]);
    const outcome = stager.stageEdit(file, after, 1, false);
    stager.resolve("h1", "accept");
    stager.resolve("h2", "comment", "use 31 so it's past the cap");
    const result = await outcome;
    expect(result.allAccepted).toBe(false);
    expect(readFileSync(file, "utf8")).toBe(edit(base, [["line 3", "three"]]));
    expect(result.feedback).toContain("accepted 1 of 2 hunks");
    expect(result.feedback).toContain("was sent back: use 31 so it's past the cap");
    expect(records.filter((r) => r.type === "hunkResolved").map((r) => r.type === "hunkResolved" && [r.hunkID, r.decision, r.note])).toEqual([
      ["h1", "accept", undefined],
      ["h2", "comment", "use 31 so it's past the cap"],
    ]);
  });

  test("a partial accept keeps an edit a human made to the file meanwhile", async () => {
    const { stager, file } = setup();
    seed(file);
    const outcome = stager.stageEdit(file, edit(base, [["line 3", "three"], ["line 30", "thirty"]]), 1, false);
    writeFileSync(file, edit(base, [["line 15", "human was here"]]));
    stager.resolve("h1", "accept");
    stager.resolve("h2", "reject");
    await outcome;
    expect(readFileSync(file, "utf8")).toBe(edit(base, [["line 15", "human was here"], ["line 3", "three"]]));
  });

  test("names files relative to the real worktree, however the worktree was opened", async () => {
    const { log, records, dir } = setup();
    const link = `${dir}-link`;
    symlinkSync(dir, link);
    const stager = new HunkStager(log, link);
    void stager.stageEdit(join(realpathSync(dir), "Sources", "A.swift"), "x\n", 1, true);
    expect(records.find((r) => r.type === "hunkStaged")).toMatchObject({ file: "Sources/A.swift", added: 1, removed: 0 });
  });

  test("rejecting everything leaves the file, and a new file, untouched", async () => {
    const { stager, dir } = setup();
    const fresh = join(dir, "New.swift");
    const outcome = stager.stageEdit(fresh, "hello\n", 1, false);
    stager.resolve("h1", "reject", "not needed");
    expect((await outcome).allAccepted).toBe(false);
    expect(existsSync(fresh)).toBe(false);
  });

  test("auto mode stages hunks already accepted, and a late reject reverse-applies one", async () => {
    const { stager, file, records } = setup();
    seed(file);
    const after = edit(base, [["line 3", "three"], ["line 30", "thirty"]]);
    const late: string[] = [];
    stager.onLateDecision = (h) => late.push(h.id);
    const result = await stager.stageEdit(file, after, 2, true);
    expect(result.allAccepted).toBe(true);
    expect(records.filter((r) => r.type === "hunkStaged").every((r) => r.type === "hunkStaged" && r.autoAccepted)).toBe(true);
    writeFileSync(file, after); // the engine's tool writes it
    stager.resolve("h2", "reject", "keep line 30");
    expect(readFileSync(file, "utf8")).toBe(edit(base, [["line 3", "three"]]));
    expect(late).toEqual(["h2"]);
    expect(stager.tally(2)).toEqual({ filesChanged: 1, added: 1, removed: 1 });
  });

  test("auto-accepted hunks stop being reviewable when their turn ends", async () => {
    const { stager, file } = setup();
    seed(file);
    await stager.stageEdit(file, edit(base, [["line 3", "three"]]), 1, true);
    stager.closeTurn(1);
    expect(() => stager.resolve("h1", "reject")).toThrow("no hunk h1");
  });

  test("a decided hunk can't be decided again, and a stopped turn rejects what is pending", async () => {
    const { stager, file } = setup();
    seed(file);
    const outcome = stager.stageEdit(file, edit(base, [["line 3", "three"], ["line 30", "thirty"]]), 1, false);
    stager.resolve("h1", "accept");
    expect(() => stager.resolve("h1", "reject")).toThrow("already accepted");
    stager.rejectPending("the turn was stopped");
    const result = await outcome;
    expect(result.hunks.map((h) => h.state)).toEqual(["accepted", "rejected"]);
    expect(stager.pending()).toEqual([]);
  });
});
