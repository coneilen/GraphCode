import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventLog } from "../src/eventLog";
import { GoalEvaluator, parseVerdict, splitGoal } from "../src/goal";
import type { NodEventRecord } from "../src/protocol";

describe("splitGoal", () => {
  test("splits a done-when sentence on its top-level and", () => {
    expect(splitGoal("Done when every paid route enforces the cap and `swift test` passes")).toEqual([
      "every paid route enforces the cap",
      "`swift test` passes",
    ]);
  });

  test("never splits inside backticks, quotes or brackets", () => {
    expect(splitGoal('/export returns 402 with { limit and resetsAt } and the banner reads "limit and reset"')).toEqual([
      "/export returns 402 with { limit and resetsAt }",
      'the banner reads "limit and reset"',
    ]);
    expect(splitGoal("`make lint and test` exits 0")).toEqual(["`make lint and test` exits 0"]);
  });

  test("a fragment too short to be a claim joins the clause before it", () => {
    expect(splitGoal("The 402 body carries limit and resetsAt")).toEqual(["The 402 body carries limit and resetsAt"]);
  });

  test("list items and semicolons each become a clause, even short ones", () => {
    expect(splitGoal("Done when:\n- tests pass\n- the README documents packaging; the PR is open")).toEqual([
      "tests pass",
      "the README documents packaging",
      "the PR is open",
    ]);
  });

  test("only a real prefix is stripped", () => {
    expect(splitGoal("goals page renders the cap")).toEqual(["goals page renders the cap"]);
    expect(splitGoal("Goal: the cap holds")).toEqual(["the cap holds"]);
  });

  test("a goal with nothing to split is one clause", () => {
    expect(splitGoal("Ship it.")).toEqual(["Ship it"]);
  });
});

describe("parseVerdict", () => {
  const clauses = ["routes are gated", "tests pass"];

  test("reads the judge's JSON, even wrapped in prose or a fence", () => {
    const answer = 'Here you go:\n```json\n{"clauses":[{"index":0,"met":true,"evidence":"4 / 4 routes"},{"index":1,"met":false,"evidence":"1 failure"}]}\n```';
    expect(parseVerdict(answer, clauses)).toEqual({
      met: false,
      clauses: [
        { text: "routes are gated", met: true, evidence: "4 / 4 routes" },
        { text: "tests pass", met: false, evidence: "1 failure" },
      ],
    });
  });

  test("anything unreadable or missing counts as not met, never as met", () => {
    expect(parseVerdict("I think it's done!", clauses).met).toBe(false);
    expect(parseVerdict('{"clauses":[{"index":0,"met":true}]}', clauses).clauses[1]).toEqual({
      text: "tests pass",
      met: false,
      evidence: "the evaluator gave no verdict",
    });
    expect(parseVerdict('{"clauses":[{"index":0,"met":"yes"},{"index":1,"met":true}]}', clauses).met).toBe(false);
  });
});

describe("GoalEvaluator", () => {
  function evaluator(goal: string, judge: (prompt: string) => Promise<string>) {
    const log = new EventLog(join(mkdtempSync(join(tmpdir(), "nod-goal-")), "events.jsonl"));
    const records: NodEventRecord[] = [];
    log.onRecord((r) => records.push(r));
    return { goal: new GoalEvaluator(goal, judge, "haiku", log), records };
  }

  test("splits the goal again at every check, so an edited goal is judged as edited", async () => {
    const prompts: string[] = [];
    const { goal, records } = evaluator("a works and b works", async (prompt) => {
      prompts.push(prompt);
      return '{"clauses":[{"index":0,"met":true},{"index":1,"met":true},{"index":2,"met":true}]}';
    });
    await goal.check(1, { lastMessage: "done", toolResults: ["Bash: ok — exit 0"] });
    goal.goal = "a works and b works and c works";
    await goal.check(2, { lastMessage: "done", toolResults: [] });
    expect(prompts[0]).toContain("0. a works\n1. b works");
    expect(prompts[0]).toContain("- Bash: ok — exit 0");
    expect(prompts[1]).toContain("2. c works");
    const checks = records.filter((r) => r.type === "goalCheck");
    expect(checks.map((r) => r.type === "goalCheck" && [r.turn, r.clauses.length, r.met, r.evaluatorModel])).toEqual([
      [1, 2, true, "haiku"],
      [2, 3, true, "haiku"],
    ]);
  });

  test("a judge that throws reads as not met", async () => {
    const { goal } = evaluator("a works", async () => {
      throw new Error("rate limited");
    });
    expect((await goal.check(1, { lastMessage: "", toolResults: [] })).met).toBe(false);
  });

  test("marked done passes without asking the judge", async () => {
    let asked = false;
    const { goal, records } = evaluator("a works and b works", async () => ((asked = true), ""));
    goal.markDone();
    expect((await goal.check(3, { lastMessage: "", toolResults: [] })).met).toBe(true);
    expect(asked).toBe(false);
    expect(records[0]).toMatchObject({ type: "goalCheck", met: true });
  });

  test("the continuation names only the unmet clauses, with their evidence", () => {
    const text = GoalEvaluator.continuation({
      met: false,
      clauses: [
        { text: "routes are gated", met: true },
        { text: "tests pass", met: false, evidence: "1 failure · LegacyExportTests" },
      ],
    });
    expect(text).toContain("- tests pass (1 failure · LegacyExportTests)");
    expect(text).not.toContain("routes are gated");
  });
});
