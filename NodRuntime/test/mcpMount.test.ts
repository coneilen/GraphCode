import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { McpSdkServerConfigWithInstance, Options, Query } from "@anthropic-ai/claude-agent-sdk";
import type { CopilotClient, SessionConfig, Tool } from "@github/copilot-sdk";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { ClaudeEngine, toolRequest as claudeToolRequest } from "../src/claudeEngine";
import { CopilotEngine, toolRequest as copilotToolRequest } from "../src/copilotEngine";
import type { ToolRequest, TurnCallbacks } from "../src/engine";
import { EventLog } from "../src/eventLog";
import { createGraphcodeTools, type GraphDaemon, type MailDraftEvent, type MessagePolicy } from "../src/mcp";
import type { Json } from "../src/mcp/daemon";
import { loadProjectMcpServers, type McpMount } from "../src/mcpServers";
import { PermissionGate } from "../src/permissions";
import { PresenceReporter } from "../src/presence";
import type { NodEventRecord } from "../src/protocol";
import { NodRuntime } from "../src/runtime";
import { defaultSettings, loadSettings } from "../src/settings";
import { FakeEngine, until } from "./fakeEngine";

const ME = "11111111-1111-1111-1111-111111111111";
const PEER = "22222222-2222-2222-2222-222222222222";
const graph = {
  nodes: [
    { id: ME, title: "Monetization", loopType: "goalBased", state: { running: {} } },
    { id: PEER, title: "Pricing", loopType: "goalBased", state: { idle: {} } },
  ],
  edges: [],
};

class FakeDaemon implements GraphDaemon {
  commands: Json[] = [];
  async snapshot() {
    return graph as unknown as Json;
  }
  async mailbox() {
    return { posts: [] } as Json;
  }
  async graphCommand(_: string, command: Json) {
    this.commands.push(command);
  }
}

function project(mcp: object): string {
  const dir = mkdtempSync(join(tmpdir(), "nod-mcp-"));
  writeFileSync(join(dir, ".mcp.json"), JSON.stringify({ mcpServers: mcp }));
  return dir;
}

const projectServers = {
  github: { command: "github-mcp", args: ["--token", "${GH_TOKEN}"], env: { MODE: "${MODE:-read}" } },
  linear: { type: "http", url: "https://mcp.linear.app/${PATH_PART}", headers: { Authorization: "Bearer ${LINEAR}" } },
  graphcode: { command: "impostor" },
};

function mount(policy: MessagePolicy, disabled: string[] = []) {
  const daemon = new FakeDaemon();
  const drafts: MailDraftEvent[] = [];
  const servers = loadProjectMcpServers(project(projectServers), disabled, { GH_TOKEN: "t", PATH_PART: "sse", LINEAR: "k" });
  const graphcode = createGraphcodeTools({
    nodeID: ME,
    projectPath: "/work/repo",
    daemon,
    messagesOtherLoops: () => policy,
    emit: (draft) => drafts.push(draft),
    newID: () => "d1",
  });
  return { mcp: { graphcode, servers } satisfies McpMount, daemon, drafts };
}

/** A turn's callbacks that record what the engine asks the gate. */
function recordingCallbacks() {
  const asked: ToolRequest[] = [];
  const callbacks: TurnCallbacks = {
    text() {},
    toolCall() {},
    toolResult() {},
    usage() {},
    compacted() {},
    authorize: async (request) => (asked.push(request), { allow: true }),
    takeSteer: () => undefined,
  };
  return { asked, callbacks };
}

function startClaude(mcp: McpMount) {
  let options: Options | undefined;
  let release = () => {};
  const fakeQuery = ((args: { options: Options }) => {
    options = args.options;
    const ended = new Promise<void>((resolve) => (release = resolve));
    return {
      async *[Symbol.asyncIterator]() {
        await ended;
      },
      interrupt: async () => {},
      setModel: async () => {},
      close: () => release(),
    } as unknown as Query;
  }) as unknown as typeof import("@anthropic-ai/claude-agent-sdk").query;
  const engine = new ClaudeEngine({ apiKey: "sk-test", configDir: mkdtempSync(join(tmpdir(), "nod-cfg-")), query: fakeQuery });
  return { engine, options: () => options! };
}

async function connectSdkServer(server: McpSdkServerConfigWithInstance): Promise<Client> {
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await server.instance.connect(serverSide);
  const client = new Client({ name: "test", version: "1" });
  await client.connect(clientSide);
  return client;
}

function startCopilot() {
  let config: SessionConfig | undefined;
  const session = {
    sessionId: "s1",
    on() {},
    getEvents: async () => [],
    send: () => new Promise(() => {}),
    abort: async () => {},
    disconnect: async () => {},
  };
  const client = {
    start: async () => {},
    stop: async () => {},
    createSession: async (c: SessionConfig) => ((config = c), session),
    resumeSession: async (_: string, c: SessionConfig) => ((config = c), session),
  } as unknown as CopilotClient;
  const engine = new CopilotEngine({ client: () => client });
  return { engine, config: () => config! };
}

const textOf = (result: unknown) => ((result as { content: { text: string }[] }).content[0]?.text ?? "");

describe(".mcp.json", () => {
  test("loads stdio and http servers with ${VAR} and ${VAR:-default} expanded", () => {
    const servers = loadProjectMcpServers(project(projectServers), [], { GH_TOKEN: "t", PATH_PART: "sse", LINEAR: "k" });
    expect(servers).toEqual({
      github: { type: "stdio", command: "github-mcp", args: ["--token", "t"], env: { MODE: "read" } },
      linear: { type: "http", url: "https://mcp.linear.app/sse", headers: { Authorization: "Bearer k" } },
    });
  });

  test("skips disabledMCPServers, and a project entry can never replace or disable graphcode", () => {
    const servers = loadProjectMcpServers(project(projectServers), ["github", "graphcode"], {});
    expect(Object.keys(servers)).toEqual(["linear"]);
  });

  test("walks up from the worktree, the nearer file winning a name", () => {
    const root = project({ github: { command: "outer" }, sentry: { command: "sentry-mcp" } });
    const inner = join(root, "worktrees", "a");
    mkdirSync(inner, { recursive: true });
    writeFileSync(join(inner, ".mcp.json"), JSON.stringify({ mcpServers: { github: { command: "inner" } } }));
    const servers = loadProjectMcpServers(inner, [], {});
    expect(servers.github).toMatchObject({ command: "inner" });
    expect(servers.sentry).toMatchObject({ command: "sentry-mcp" });
  });

  test("disabledMCPServers is read from settings.json's nod key", () => {
    const dir = mkdtempSync(join(tmpdir(), "nod-settings-"));
    writeFileSync(join(dir, "settings.json"), JSON.stringify({ nod: { disabledMCPServers: ["github"] } }));
    expect(loadSettings(join(dir, "settings.json")).disabledMCPServers).toEqual(["github"]);
    expect(defaultSettings.disabledMCPServers).toEqual([]);
  });
});

describe("Claude engine mounts", () => {
  test("graphcode in-process and the project's servers, and nothing Claude Code would find itself", async () => {
    const { mcp } = mount("draftForMe", ["linear"]);
    const { engine, options } = startClaude(mcp);
    await engine.start({ cwd: "/work/repo", mcp });
    expect(options().strictMcpConfig).toBe(true);
    expect(Object.keys(options().mcpServers!).sort()).toEqual(["github", "graphcode"]);
    expect(options().mcpServers!.github).toEqual(mcp.servers.github!);
    expect(options().mcpServers!.graphcode).toMatchObject({ type: "sdk", name: "graphcode" });
    await engine.close();
  });

  test("the graphcode server lists its tools and Draft for me emits mailDraft without sending", async () => {
    const { mcp, daemon, drafts } = mount("draftForMe");
    const { engine, options } = startClaude(mcp);
    await engine.start({ cwd: "/work/repo", mcp });
    const client = await connectSdkServer(options().mcpServers!.graphcode as McpSdkServerConfigWithInstance);
    const names = (await client.listTools()).tools.map((t) => t.name).sort();
    expect(names).toEqual(["ask", "edges", "handoff", "handoff_briefs", "mailroom", "mailroom_read", "siblings"]);
    const siblings = await client.callTool({ name: "siblings", arguments: {} });
    expect(textOf(siblings)).toContain(`Pricing (${PEER})`);
    const asked = await client.callTool({ name: "ask", arguments: { to: "Pricing", text: "free tier?" } });
    expect(textOf(asked)).toContain("Drafted for the human");
    expect(drafts).toEqual([{ type: "mailDraft", draftID: "d1", toNodeID: PEER, inReplyTo: undefined, text: "free tier?" }]);
    expect(daemon.commands).toEqual([]);
    await client.close();
    await engine.close();
  });

  test("Never refuses ask and handoff; Send sends as this loop", async () => {
    for (const policy of ["never", "send"] as const) {
      const { mcp, daemon, drafts } = mount(policy);
      const { engine, options } = startClaude(mcp);
      await engine.start({ cwd: "/work/repo", mcp });
      const client = await connectSdkServer(options().mcpServers!.graphcode as McpSdkServerConfigWithInstance);
      const result = await client.callTool({ name: "handoff", arguments: { brief: "done", to: "Pricing" } });
      expect(drafts).toEqual([]);
      if (policy === "never") {
        expect(result.isError).toBe(true);
        expect(daemon.commands).toEqual([]);
      } else {
        expect(daemon.commands).toEqual([{ messageNode: { _0: PEER, text: "Handoff: done", from: ME, followUp: true } }]);
      }
      await client.close();
      await engine.close();
    }
  });

  test("every mcp__ call is forced to an ask and reaches the gate through canUseTool", async () => {
    const { mcp } = mount("draftForMe");
    const { engine, options } = startClaude(mcp);
    await engine.start({ cwd: "/work/repo", mcp });
    const preToolUse = options().hooks!.PreToolUse![0]!.hooks[0]!;
    const signal = new AbortController().signal;
    for (const tool of ["mcp__graphcode__ask", "mcp__github__create_issue"]) {
      const out = await preToolUse({ hook_event_name: "PreToolUse", tool_name: tool, tool_input: {} } as never, undefined, { signal });
      expect(out).toMatchObject({ hookSpecificOutput: { permissionDecision: "ask" } });
    }
    const { asked, callbacks } = recordingCallbacks();
    void engine.runTurn("go", [], callbacks);
    await options().canUseTool!("mcp__github__create_issue", {}, { signal } as never);
    expect(asked).toEqual([{ intent: { kind: "mcp", server: "github", tool: "create_issue" } }]);
    await engine.close();
  });
});

describe("Copilot engine mounts", () => {
  test("graphcode as custom tools and the project's servers as mcpServers", async () => {
    const { mcp } = mount("draftForMe", ["github"]);
    const { engine, config } = startCopilot();
    await engine.start({ cwd: "/work/repo", mcp });
    expect(config().tools!.map((t) => t.name).sort()).toEqual([
      "graphcode_ask", "graphcode_edges", "graphcode_handoff", "graphcode_handoff_briefs",
      "graphcode_mailroom", "graphcode_mailroom_read", "graphcode_siblings",
    ]);
    expect(config().mcpServers).toEqual({
      linear: { type: "http", url: "https://mcp.linear.app/sse", headers: { Authorization: "Bearer k" }, tools: ["*"] },
    });
  });

  test("Draft for me drafts, Never refuses, Send sends", async () => {
    const call = (tools: Tool[], name: string, args: object) =>
      tools.find((t) => t.name === name)!.handler!(args, {} as never) as Promise<{ resultType: string; textResultForLlm: string }>;
    const draft = mount("draftForMe");
    let session = startCopilot();
    await session.engine.start({ cwd: "/work/repo", mcp: draft.mcp });
    expect((await call(session.config().tools!, "graphcode_ask", { to: PEER, text: "hi" })).resultType).toBe("success");
    expect(draft.drafts).toHaveLength(1);
    expect(draft.daemon.commands).toEqual([]);

    const never = mount("never");
    session = startCopilot();
    await session.engine.start({ cwd: "/work/repo", mcp: never.mcp });
    expect((await call(session.config().tools!, "graphcode_ask", { to: PEER, text: "hi" })).resultType).toBe("failure");
    expect(never.daemon.commands).toEqual([]);

    const send = mount("send");
    session = startCopilot();
    await session.engine.start({ cwd: "/work/repo", mcp: send.mcp });
    await call(session.config().tools!, "graphcode_ask", { to: "Pricing", text: "hi" });
    expect(send.daemon.commands).toHaveLength(1);
    expect(send.drafts).toEqual([]);
  });

  test("custom-tool and mcp permission requests reach the gate", async () => {
    const { mcp } = mount("draftForMe");
    const { engine, config } = startCopilot();
    await engine.start({ cwd: "/work/repo", mcp });
    const { asked, callbacks } = recordingCallbacks();
    void engine.runTurn("go", [], callbacks);
    await config().onPermissionRequest!({ kind: "custom-tool", toolName: "graphcode_ask", toolDescription: "" } as never, { sessionId: "s1" } as never);
    await config().onPermissionRequest!({ kind: "mcp", serverName: "linear", toolName: "list_issues", readOnly: true } as never, { sessionId: "s1" } as never);
    expect(asked).toEqual([
      { intent: { kind: "mcp", server: "graphcode", tool: "ask" } },
      { intent: { kind: "mcp", server: "linear", tool: "list_issues" } },
    ]);
  });
});

describe("the gate over MCP tools", () => {
  function gate(unattended = false) {
    const log = new EventLog(join(mkdtempSync(join(tmpdir(), "nod-gate-")), "events.jsonl"));
    const records: NodEventRecord[] = [];
    log.onRecord((r) => records.push(r));
    return { gate: new PermissionGate({ settings: defaultSettings, worktree: "/work/repo", unattended, log }), records };
  }

  test("graphcode's tools pass, because they apply messagesOtherLoops themselves", async () => {
    const { gate: g } = gate(true);
    for (const request of [
      claudeToolRequest("mcp__graphcode__handoff", {}, "/work/repo"),
      copilotToolRequest({ kind: "custom-tool", toolName: "graphcode_handoff" } as never, "/work/repo"),
    ]) {
      expect(await g.check(request.intent)).toEqual({ verdict: "allow" });
    }
  });

  test("a project server's tool is an mcpTool ask on both engines, and fails an unattended loop", async () => {
    for (const request of [
      claudeToolRequest("mcp__github__create_issue", {}, "/work/repo"),
      copilotToolRequest({ kind: "mcp", serverName: "github", toolName: "create_issue" } as never, "/work/repo"),
    ]) {
      const { gate: g, records } = gate();
      const verdict = g.check(request.intent);
      await until(() => records.length === 1);
      expect(records[0]).toMatchObject({ type: "permissionAsked", kind: "mcpTool", subject: "github/create_issue" });
      g.resolve((records[0] as { askID: string }).askID, "deny");
      expect(await verdict).toMatchObject({ verdict: "deny" });
      expect(await gate(true).gate.check(request.intent)).toMatchObject({ verdict: "fail" });
    }
  });
});

describe("runtime", () => {
  function runtime(engine: FakeEngine, projectPath: string | undefined, daemon: GraphDaemon) {
    const cwd = mkdtempSync(join(tmpdir(), "nod-rtm-"));
    const log = new EventLog(join(cwd, "events.jsonl"));
    const records: NodEventRecord[] = [];
    log.onRecord((r) => records.push(r));
    const rt = new NodRuntime({
      nodeID: ME,
      cwd,
      stateDir: cwd,
      loopType: "main",
      settings: defaultSettings,
      engine,
      log,
      presence: new PresenceReporter(undefined, async () => {}, join(cwd, "support")),
      projectPath,
      daemon,
      mcpServers: { github: { type: "stdio", command: "github-mcp" } },
    });
    return { rt, records };
  }

  test("hands the engine graphcode and the project's servers, and sends an approved draft as edited", async () => {
    const engine = new FakeEngine();
    const daemon = new FakeDaemon();
    const { rt, records } = runtime(engine, "/work/repo", daemon);
    await rt.start();
    expect(engine.started!.mcp!.servers).toEqual({ github: { type: "stdio", command: "github-mcp" } });
    const ask = engine.started!.mcp!.graphcode.find((t) => t.name === "ask")!;
    await ask.handler({ to: "Pricing", text: "free tier?" });
    const draft = records.find((r) => r.type === "mailDraft") as NodEventRecord & { draftID: string; toNodeID: string };
    expect(draft.toNodeID).toBe(PEER);
    expect(daemon.commands).toEqual([]);
    await rt.handle({ type: "sendDraft", draftID: draft.draftID, text: "free tier: 50?" });
    expect(daemon.commands).toEqual([{ messageNode: { _0: PEER, text: "free tier: 50?", from: ME, followUp: true } }]);
    await expect(rt.handle({ type: "sendDraft", draftID: "nope", text: "x" })).rejects.toThrow("no mail draft");
    await rt.close();
  });

  test("without NOD_PROJECT_PATH graphcode stays mounted and says why it can't reach the graph", async () => {
    const engine = new FakeEngine();
    const daemon = new FakeDaemon();
    const { rt } = runtime(engine, undefined, daemon);
    await rt.start();
    const siblings = engine.started!.mcp!.graphcode.find((t) => t.name === "siblings")!;
    await expect(siblings.handler({})).rejects.toThrow("NOD_PROJECT_PATH");
    await rt.close();
  });
});
