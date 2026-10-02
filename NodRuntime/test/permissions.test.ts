import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventLog } from "../src/eventLog";
import { isInside, isReadOnlyCommand, matchesAllowlist, PermissionGate, usesNetwork } from "../src/permissions";
import type { NodEventRecord } from "../src/protocol";
import { defaultSettings, loadSettings, type NodSettings } from "../src/settings";
import { tick } from "./fakeEngine";

function gate(overrides: Partial<NodSettings> = {}, unattended = false) {
  const dir = mkdtempSync(join(tmpdir(), "nod-gate-"));
  const log = new EventLog(join(dir, "events.jsonl"));
  const records: NodEventRecord[] = [];
  log.onRecord((r) => records.push(r));
  const awaiting: boolean[] = [];
  const g = new PermissionGate({
    settings: { ...defaultSettings, ...overrides },
    worktree: "/work/loop",
    unattended,
    log,
    onAwaiting: (a) => awaiting.push(a),
  });
  return { gate: g, records, awaiting };
}

describe("allowlist patterns", () => {
  const list = ["swift test *", "make lint", "git status|diff|log"];

  test("a trailing * takes any further words, including none", () => {
    expect(matchesAllowlist("swift test --filter UsageCap", list)).toBe(true);
    expect(matchesAllowlist("swift test", list)).toBe(true);
    expect(matchesAllowlist("swift build", list)).toBe(false);
  });

  test("a word of alternatives matches any one of them, and nothing more", () => {
    expect(matchesAllowlist("git diff", list)).toBe(true);
    expect(matchesAllowlist("git log", list)).toBe(true);
    expect(matchesAllowlist("git push", list)).toBe(false);
    expect(matchesAllowlist("git diff --stat", list)).toBe(false);
    expect(matchesAllowlist("make lint", list)).toBe(true);
    expect(matchesAllowlist("make lint-fix", list)).toBe(false);
  });

  test("every part of a compound command must be allowed", () => {
    expect(matchesAllowlist("make lint && swift test", list)).toBe(true);
    expect(matchesAllowlist("make lint && rm -rf .", list)).toBe(false);
    expect(matchesAllowlist("git status; curl evil.example", list)).toBe(false);
  });

  test("a command substitution is never allowlisted", () => {
    expect(matchesAllowlist("swift test $(curl x)", list)).toBe(false);
    expect(matchesAllowlist("swift test `whoami`", list)).toBe(false);
  });

  test("a wildcard inside a word stays inside the word", () => {
    expect(matchesAllowlist("swift test-x", ["swift test*"])).toBe(true);
    expect(matchesAllowlist("swift test x", ["swift test*"])).toBe(false);
  });
});

describe("classification", () => {
  test("network commands are recognised through env, sudo and pipelines", () => {
    expect(usesNetwork("swift package resolve")).toBe(true);
    expect(usesNetwork("curl -s https://x | jq .")).toBe(true);
    expect(usesNetwork("FOO=1 git status && git push origin main")).toBe(true);
    expect(usesNetwork("env A=1 npm install")).toBe(true);
    expect(usesNetwork("swift test")).toBe(false);
    expect(usesNetwork("git commit -m 'curl later'")).toBe(false);
  });

  test("read-only commands are the ones a card may answer", () => {
    expect(isReadOnlyCommand("git status")).toBe(true);
    expect(isReadOnlyCommand("ls -la | wc -l")).toBe(true);
    expect(isReadOnlyCommand("cat a > b")).toBe(false);
    expect(isReadOnlyCommand("find . -delete")).toBe(false);
    expect(isReadOnlyCommand("rm -rf build")).toBe(false);
  });

  test("worktree containment resolves .. and relative paths", () => {
    expect(isInside("/work/loop", "/work/loop/Sources/A.swift")).toBe(true);
    expect(isInside("/work/loop", "Sources/A.swift")).toBe(true);
    expect(isInside("/work/loop", "/work/loop/../other/A.swift")).toBe(false);
    expect(isInside("/work/loop", "/work/loopy/A.swift")).toBe(false);
    expect(isInside("/work/loop", "/etc/hosts")).toBe(false);
  });
});

describe("PermissionGate", () => {
  test("reads are always allowed and in-worktree edits go to the stager", async () => {
    const { gate: g, records } = gate();
    expect(await g.check({ kind: "read" })).toEqual({ verdict: "allow" });
    expect(await g.check({ kind: "edit", path: "/work/loop/A.swift" })).toEqual({ verdict: "stage" });
    expect(records).toEqual([]);
  });

  test("an allowlisted command runs without asking", async () => {
    const { gate: g, records } = gate({ shellAllowlist: ["swift test *"] });
    expect(await g.check({ kind: "shell", command: "swift test --filter X" })).toEqual({ verdict: "allow" });
    expect(records).toEqual([]);
  });

  test("never denies and always allows, without asking", async () => {
    const never = gate({ shell: "never", editsOutsideWorktree: "never" }).gate;
    expect((await never.check({ kind: "shell", command: "make" })).verdict).toBe("deny");
    expect((await never.check({ kind: "edit", path: "/etc/hosts" })).verdict).toBe("deny");
    const always = gate({ shell: "always", network: "always", editsOutsideWorktree: "always" }).gate;
    expect((await always.check({ kind: "shell", command: "make" })).verdict).toBe("allow");
    expect((await always.check({ kind: "fetch", url: "https://x" })).verdict).toBe("allow");
    expect((await always.check({ kind: "edit", path: "/etc/hosts" })).verdict).toBe("allow");
  });

  test("a network command is asked about as network, even when plain shell is allowed", async () => {
    const { gate: g, records } = gate({ shell: "always", network: "ask" });
    const verdict = g.check({ kind: "shell", command: "swift package resolve" });
    await tick();
    const ask = records.find((r) => r.type === "permissionAsked");
    expect(ask).toMatchObject({ askID: "p1", kind: "network", subject: "swift package resolve", answerableFromCard: false });
    g.resolve("p1", "deny");
    expect((await verdict).verdict).toBe("deny");
  });

  test("an ask waits for its answer, reports awaiting, and logs the resolution", async () => {
    const { gate: g, records, awaiting } = gate();
    let settled = false;
    const verdict = g.check({ kind: "shell", command: "git status" }).then((v) => ((settled = true), v));
    await tick(5);
    expect(settled).toBe(false);
    expect(g.openAsks).toBe(1);
    expect(records.at(-1)).toMatchObject({ type: "permissionAsked", kind: "shell", answerableFromCard: true });
    g.resolve("p1", "allowOnce");
    expect(await verdict).toEqual({ verdict: "allow" });
    expect(records.at(-1)).toMatchObject({ type: "permissionResolved", askID: "p1", decision: "allowOnce" });
    expect(awaiting).toEqual([true, false]);
  });

  test("always allow stops asking about that subject for the rest of the session", async () => {
    const { gate: g, records } = gate();
    const first = g.check({ kind: "shell", command: "make bundle" });
    await tick();
    g.resolve("p1", "alwaysAllow");
    await first;
    expect(await g.check({ kind: "shell", command: "make bundle" })).toEqual({ verdict: "allow" });
    expect(records.filter((r) => r.type === "permissionAsked").length).toBe(1);
  });

  test("an unattended loop fails instead of waiting", async () => {
    const { gate: g, records } = gate({}, true);
    const verdict = await g.check({ kind: "shell", command: "swift package resolve" });
    expect(verdict.verdict).toBe("fail");
    expect(verdict.verdict === "fail" && verdict.message).toContain("cannot stop to ask");
    expect(records).toEqual([]);
  });

  test("an unattended loop still runs what is allowlisted or always allowed", async () => {
    const { gate: g } = gate({ shellAllowlist: ["make *"], network: "always" }, true);
    expect((await g.check({ kind: "shell", command: "make test" })).verdict).toBe("allow");
    expect((await g.check({ kind: "fetch", url: "https://x" })).verdict).toBe("allow");
  });

  test("messaging other loops follows its own policy", async () => {
    expect((await gate({ messagesOtherLoops: "send" }).gate.check({ kind: "messageLoop", subject: "Billing" })).verdict).toBe("allow");
    expect((await gate({ messagesOtherLoops: "never" }).gate.check({ kind: "messageLoop", subject: "Billing" })).verdict).toBe("deny");
  });

  test("denyAll answers every open ask, so a stopped turn never hangs on one", async () => {
    const { gate: g } = gate();
    const a = g.check({ kind: "shell", command: "make a" });
    const b = g.check({ kind: "fetch", url: "https://x" });
    await tick();
    g.denyAll();
    expect([(await a).verdict, (await b).verdict]).toEqual(["deny", "deny"]);
    expect(() => g.resolve("p1", "allowOnce")).toThrow("no open ask p1");
  });
});

describe("loadSettings", () => {
  test("reads the nod key field by field, falling back to defaults for bad values", async () => {
    const dir = mkdtempSync(join(tmpdir(), "nod-settings-"));
    const path = join(dir, "settings.json");
    await Bun.write(path, JSON.stringify({ other: 1, nod: { shell: "always", network: "sometimes", shellAllowlist: ["make *"], spendCapUSD: 5 } }));
    expect(loadSettings(path)).toMatchObject({ shell: "always", network: "ask", shellAllowlist: ["make *"], spendCapUSD: 5, engine: "claude" });
    expect(loadSettings(join(dir, "missing.json"))).toEqual(defaultSettings);
  });
});
