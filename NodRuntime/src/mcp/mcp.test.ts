import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { daemonClient, encodeFrame, FrameReader, socketPath, type GraphDaemon, type Json } from "./daemon";
import { classifyInbound, levelOf, relationOf, resolveLoop, type WireGraph } from "./graph";
import { createGraphcodeTools, sendDraft, type MailDraftEvent, type MessagePolicy } from "./tools";

const ME = "11111111-1111-1111-1111-111111111111";
const PRICING = "22222222-2222-2222-2222-222222222222";
const NOTES = "33333333-3333-3333-3333-333333333333";
const BILLING = "44444444-4444-4444-4444-444444444444";
const FORK = "55555555-5555-5555-5555-555555555555";
const CHILD = "66666666-6666-6666-6666-666666666666";

const graph: WireGraph = {
  nodes: [
    { id: ME, title: "Monetization", loopType: "goalBased", state: { running: {} }, goal: { summary: "every paid route is capped" }, activity: "Running swift test" },
    {
      id: PRICING, title: "Pricing", loopType: "goalBased", state: { succeeded: {} },
      goal: { summary: "Decide the free tier" }, resolution: { detail: "50 exports a month, 402 over the cap" },
    },
    { id: NOTES, title: "ReleaseNotes", loopType: "turnBased", state: { idle: {} }, firstInstruction: "Write the notes" },
    { id: BILLING, title: "BillingUI", loopType: "turnBased", state: { running: {} } },
    { id: FORK, title: "Monetization2", loopType: "goalBased", state: { running: {} }, lineage: { kind: "fork", sourceNodeID: ME } },
    {
      id: "77777777-7777-7777-7777-777777777777", title: "Caps", loopType: "proactive", state: { running: {} },
      subGraph: { nodes: [{ id: CHILD, title: "Server", loopType: "goalBased", state: { running: {} } }], edges: [] },
    },
  ],
  edges: [
    { id: "e1", from: PRICING, to: ME, kind: "handoff", condition: "always", payloadTransform: { template: { _0: "Free tier is 50" } }, fireCount: 1 },
    { id: "e2", from: ME, to: NOTES, kind: "handoff", condition: "always", payloadTransform: { none: {} }, fireCount: 0 },
    { id: "e3", from: BILLING, to: ME, kind: "message", condition: "always", fireCount: 0 },
  ],
};

class FakeDaemon implements GraphDaemon {
  commands: Json[] = [];
  queries: Json[] = [];
  posts: Array<Record<string, Json>> = [
    { id: 1, at: 0, author: "Pricing", topic: "nod", body: "free tier decided", kind: "notice" },
    { id: 2, at: 60, author: "BillingUI", body: "banner wip", kind: "notice" },
  ];
  async snapshot() {
    return graph as unknown as Json;
  }
  async mailbox(_: string, query: Json) {
    this.queries.push(query);
    const selection = (query as { selection: Record<string, Json> }).selection;
    if ("post" in selection) {
      const id = (selection.post as { id: number }).id;
      return { posts: this.posts.filter((p) => p.id === id) } as Json;
    }
    return { posts: this.posts } as Json;
  }
  async graphCommand(_: string, command: Json) {
    this.commands.push(command);
  }
}

function tools(policy: MessagePolicy, daemon = new FakeDaemon()) {
  const drafts: MailDraftEvent[] = [];
  let n = 0;
  const all = createGraphcodeTools({
    nodeID: ME,
    projectPath: "/work/repo",
    daemon,
    messagesOtherLoops: () => policy,
    emit: (event) => drafts.push(event),
    newID: () => `d${++n}`,
  });
  const call = (name: string, args: Record<string, unknown> = {}) => all.find((t) => t.name === name)!.handler(args);
  return { all, call, drafts, daemon };
}

describe("graph", () => {
  test("relations read from, to and beside, forks included", () => {
    const level = levelOf(graph, ME)!;
    expect(relationOf(level, ME, PRICING)).toBe("from");
    expect(relationOf(level, ME, NOTES)).toBe("to");
    expect(relationOf(level, ME, BILLING)).toBe("beside");
    expect(relationOf(level, ME, FORK)).toBe("beside");
  });

  test("a composite child's level is its sub-graph", () => {
    expect(levelOf(graph, CHILD)?.nodes.map((n) => n.title)).toEqual(["Server"]);
  });

  test("loops resolve by title, unique prefix or id", () => {
    expect(resolveLoop(graph, "@billingui", ME)?.id).toBe(BILLING);
    expect(resolveLoop(graph, "rel", ME)?.id).toBe(NOTES);
    expect(resolveLoop(graph, "Mon", ME)?.id).toBe(FORK);
    expect(resolveLoop(graph, "Nobody", ME)).toBeUndefined();
    expect(resolveLoop(graph, "server", ME)?.id).toBe(CHILD);
  });

  test("inbound lines name their sender and kind", () => {
    expect(classifyInbound("[graphcode] BillingUI: what does /export return?", graph, ME)).toEqual({
      kind: "mail", senderID: BILLING, senderTitle: "BillingUI", body: "what does /export return?",
    });
    expect(classifyInbound("[graphcode] Pricing finished.", graph, ME)?.kind).toBe("handoff");
    expect(classifyInbound("[graphcode] BillingUI: Handoff: banner done", graph, ME)).toMatchObject({ kind: "handoff", body: "banner done" });
    expect(classifyInbound("[graphcode] Stop requested from the graph.", graph, ME)).toBeUndefined();
    expect(classifyInbound("fix /export", graph, ME)).toBeUndefined();
  });
});

describe("read-only tools", () => {
  test("the server mounts the read tools and ask/handoff", () => {
    const { all } = tools("draftForMe");
    expect(all.map((t) => t.name)).toEqual(["siblings", "edges", "handoff_briefs", "mailroom", "mailroom_read", "ask", "handoff"]);
    expect(all.filter((t) => !t.readOnly).map((t) => t.name)).toEqual(["ask", "handoff"]);
  });

  test("siblings lists the other loops at this level with their relation", async () => {
    const { text } = await tools("draftForMe").call("siblings");
    expect(text).toContain(`Pricing (${PRICING}) | goalBased · succeeded | relation: from | brief: Decide the free tier`);
    expect(text).toContain("ReleaseNotes");
    expect(text).toContain("relation: to");
    expect(text).toContain("Monetization2");
    expect(text).not.toContain(`Monetization (${ME})`);
    expect(text).not.toContain("Server");
  });

  test("edges shows only this loop's unless all", async () => {
    const mine = await tools("draftForMe").call("edges");
    expect(mine.text.split("\n")).toEqual([
      "- Pricing → Monetization · handoff · always · fired 1×",
      "- Monetization → ReleaseNotes · handoff · always · not fired",
      "- BillingUI → Monetization · message · always · not fired",
    ]);
  });

  test("handoff briefs carry the source's result and the edge's payload", async () => {
    const { text } = await tools("draftForMe").call("handoff_briefs");
    expect(text).toContain("Pricing");
    expect(text).toContain("handed off");
    expect(text).toContain("result: 50 exports a month, 402 over the cap");
    expect(text).toContain("the brief: Free tier is 50");
  });

  test("the mailroom is read without moving the cursor", async () => {
    const t = tools("draftForMe");
    const list = await t.call("mailroom", { search: "tier", unread: true, limit: 1 });
    expect(list.text).toBe("#2 BillingUI · 2001-01-01T00:01:00.000Z: banner wip");
    expect(t.daemon.queries[0]).toEqual({ selection: { unread: { reader: ME } }, search: "tier", fullBodies: false, advanceCursor: false });
    const one = await t.call("mailroom_read", { id: 1 });
    expect(one.text).toContain("#1 (nod) Pricing");
    expect(t.daemon.queries[1]).toMatchObject({ selection: { post: { id: 1 } }, fullBodies: true, advanceCursor: false });
    expect((await t.call("mailroom_read", { id: 9 })).isError).toBe(true);
  });
});

describe("ask and handoff are gated by messagesOtherLoops", () => {
  test("Draft for me emits a mailDraft and sends nothing", async () => {
    const t = tools("draftForMe");
    const result = await t.call("ask", { to: "billing", text: "402 with { limit, resetsAt }", inReplyTo: "u7" });
    expect(result.isError).toBeUndefined();
    expect(t.drafts).toEqual([{ type: "mailDraft", draftID: "d1", toNodeID: BILLING, inReplyTo: "u7", text: "402 with { limit, resetsAt }" }]);
    expect(t.daemon.commands).toEqual([]);
  });

  test("Send messages the loop through the daemon as this loop", async () => {
    const t = tools("send");
    await t.call("ask", { to: "BillingUI", text: "done?" });
    expect(t.drafts).toEqual([]);
    expect(t.daemon.commands).toEqual([{ messageNode: { _0: BILLING, text: "done?", from: ME, followUp: true } }]);
  });

  test("Never refuses and does nothing", async () => {
    const t = tools("never");
    const ask = await t.call("ask", { to: "BillingUI", text: "x" });
    const handoff = await t.call("handoff", { brief: "x" });
    expect(ask.isError).toBe(true);
    expect(handoff.isError).toBe(true);
    expect(ask.text).toContain("Settings › Agents › Nod");
    expect(t.drafts).toEqual([]);
    expect(t.daemon.commands).toEqual([]);
  });

  test("handoff goes downstream by default, or to the named loop", async () => {
    const t = tools("send");
    await t.call("handoff", { brief: "Moved /export into the paid group." });
    await t.call("handoff", { brief: "check the 402", to: "BillingUI" });
    expect(t.daemon.commands).toEqual([
      { messageNode: { _0: NOTES, text: "Handoff: Moved /export into the paid group.", from: ME, followUp: true } },
      { messageNode: { _0: BILLING, text: "Handoff: check the 402", from: ME, followUp: true } },
    ]);
    const drafted = tools("draftForMe");
    await drafted.call("handoff", { brief: "summary" });
    expect(drafted.drafts.map((d) => [d.toNodeID, d.text, d.inReplyTo])).toEqual([[NOTES, "Handoff: summary", undefined]]);
  });

  test("unknown loops and empty text are errors, not sends", async () => {
    const t = tools("send");
    expect((await t.call("ask", { to: "Nobody", text: "x" })).isError).toBe(true);
    expect((await t.call("ask", { to: "BillingUI", text: "  " })).isError).toBe(true);
    expect((await t.call("handoff", { brief: "" })).isError).toBe(true);
    expect(t.daemon.commands).toEqual([]);
  });
});

describe("daemon wire", () => {
  let server: Server | undefined;
  let dir: string | undefined;
  afterEach(() => {
    server?.close();
    if (dir) rmSync(dir, { recursive: true, force: true });
  });

  async function fakeGraphcoded(answer: (command: Record<string, Json>) => Json[]): Promise<{ path: string; seen: Json[] }> {
    dir = mkdtempSync(join(tmpdir(), "nodmcp-"));
    const path = join(dir, "d.sock");
    const seen: Json[] = [];
    server = createServer((socket) => {
      const reader = new FrameReader();
      socket.write(encodeFrame({ nodesChanged: { _0: [] } }));
      socket.on("data", (chunk: Buffer) => {
        for (const command of reader.push(chunk)) {
          seen.push(command as Json);
          for (const event of answer(command as Record<string, Json>)) socket.write(encodeFrame(event));
        }
      });
    });
    await new Promise<void>((resolve) => server!.listen(path, resolve));
    return { path, seen };
  }

  test("frames split and join across chunk boundaries", () => {
    const bytes = Buffer.concat([encodeFrame({ a: 1 }), encodeFrame({ b: "ü" })]);
    const reader = new FrameReader();
    expect(reader.push(bytes.subarray(0, 3))).toEqual([]);
    expect(reader.push(bytes.subarray(3, 12))).toEqual([{ a: 1 }]);
    expect(reader.push(bytes.subarray(12))).toEqual([{ b: "ü" }]);
  });

  test("a snapshot opens the project and skips unsolicited events", async () => {
    const { path, seen } = await fakeGraphcoded((c) => ("openProject" in c ? [{ graphChanged: { _0: graph as unknown as Json } }] : []));
    const snapshot = (await daemonClient(path, 2000).snapshot("/work/repo")) as unknown as WireGraph;
    expect(snapshot.nodes.length).toBe(graph.nodes.length);
    expect(seen).toEqual([{ openProject: { path: "/work/repo" } }]);
  });

  test("a message is sent after opening the project, and a refusal is thrown", async () => {
    let refuse = false;
    const { path, seen } = await fakeGraphcoded((c) => {
      if ("openProject" in c) return [{ graphChanged: { _0: graph as unknown as Json } }];
      return refuse ? [{ errorOccurred: { _0: "no loop with that id" } }] : [{ graphChanged: { _0: graph as unknown as Json } }];
    });
    const daemon = daemonClient(path, 2000);
    await sendDraft({ nodeID: ME.toLowerCase(), projectPath: "/work/repo", daemon }, { toNodeID: BILLING, text: "hi" });
    expect(seen[1]).toEqual({
      graphCommand: { projectPath: "/work/repo", command: { messageNode: { _0: BILLING, text: "hi", from: ME, followUp: true } } },
    });
    refuse = true;
    await expect(sendDraft({ nodeID: ME, projectPath: "/work/repo", daemon }, { toNodeID: BILLING, text: "x" })).rejects.toThrow(
      "no loop with that id",
    );
  });

  test("the mailbox answer is unwrapped", async () => {
    const { path } = await fakeGraphcoded((c) => ("mailbox" in c ? [{ mailbox: { mailbox: { posts: [{ id: 3 }] } } }] : []));
    expect(await daemonClient(path, 2000).mailbox("/p", { selection: { board: {} } })).toEqual({ posts: [{ id: 3 }] });
  });

  test("a missing daemon is a clear error", async () => {
    await expect(daemonClient("/nonexistent/graphcoded.sock", 500).snapshot("/p")).rejects.toThrow("not reachable");
  });

  test("the socket is found the way the CLI finds it", () => {
    expect(socketPath({ GRAPHCODE_SOCKET: "/tmp/x.sock" })).toBe("/tmp/x.sock");
    expect(socketPath({ GRAPHCODE_SUPPORT_DIR: "/s" })).toBe("/s/graphcoded.sock");
    expect(socketPath({})).toEndWith("/.graphcode/graphcoded.sock");
  });
});
