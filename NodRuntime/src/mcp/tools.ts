import { randomUUID } from "node:crypto";
import type { GraphDaemon, Json } from "./daemon";
import {
  allNodes,
  brief,
  downstream,
  handoffPrefix,
  levelOf,
  oneLine,
  payloadDescription,
  referenceDate,
  relationOf,
  resolveLoop,
  stateName,
  type WireGraph,
  type WireNode,
} from "./graph";

export type MessagePolicy = "draftForMe" | "send" | "never";

/** The `mailDraft` event the runtime appends to `events.jsonl`; `v`, `seq` and `at` are its to add. */
export interface MailDraftEvent {
  type: "mailDraft";
  draftID: string;
  toNodeID: string;
  inReplyTo?: string;
  text: string;
}

export interface ToolResult {
  text: string;
  isError?: boolean;
}

/** Engine-neutral: the runtime adapts these to the Claude Agent SDK's or Copilot SDK's tool shape. */
export interface GraphcodeTool {
  name: string;
  description: string;
  inputSchema: { type: "object"; properties: Record<string, unknown>; required?: string[] };
  readOnly: boolean;
  handler(args: Record<string, unknown>): Promise<ToolResult>;
}

export interface GraphcodeToolContext {
  nodeID: string;
  projectPath: string;
  daemon: GraphDaemon;
  /** Read per call, so a change in Settings › Agents › Nod applies without a restart. */
  messagesOtherLoops(): MessagePolicy;
  emit(event: MailDraftEvent): void;
  newID?(): string;
}

export const serverName = "graphcode";

const policyOff =
  "Messaging other loops is off for Nod (Settings › Agents › Nod › Message other loops). Tell the human instead.";

export function createGraphcodeTools(ctx: GraphcodeToolContext): GraphcodeTool[] {
  const graph = async () => (await ctx.daemon.snapshot(ctx.projectPath)) as unknown as WireGraph;
  const newID = ctx.newID ?? (() => randomUUID());

  async function deliver(to: WireNode[], text: string, inReplyTo?: string): Promise<ToolResult> {
    const policy = ctx.messagesOtherLoops();
    if (policy === "never") return { text: policyOff, isError: true };
    if (policy === "draftForMe") {
      for (const target of to) {
        ctx.emit({ type: "mailDraft", draftID: newID(), toNodeID: target.id, inReplyTo, text });
      }
      const names = to.map((t) => t.title).join(", ");
      return { text: `Drafted for the human to approve; nothing is sent until they do. To: ${names}.` };
    }
    for (const target of to) await sendDraft(ctx, { toNodeID: target.id, text });
    return { text: `Sent to ${to.map((t) => t.title).join(", ")}.` };
  }

  return [
    {
      name: "siblings",
      description:
        "The other loops in this loop's graph: title, id, type, state, what each was handed, what it is doing, and how it relates to you (from = hands off to you, to = you hand off to it, beside = messages or forks).",
      inputSchema: { type: "object", properties: {} },
      readOnly: true,
      async handler() {
        const g = await graph();
        const level = levelOf(g, ctx.nodeID) ?? g;
        const others = level.nodes.filter((node) => node.id.toLowerCase() !== ctx.nodeID.toLowerCase());
        if (others.length === 0) return { text: "No other loops in this graph." };
        const lines = others.map((node) => {
          const parts = [
            `${node.title} (${node.id})`,
            `${node.loopType} · ${stateName(node.state)}`,
            `relation: ${relationOf(level, ctx.nodeID, node.id)}`,
          ];
          const handed = brief(node);
          if (handed) parts.push(`brief: ${handed}`);
          if (node.activity) parts.push(`now: ${oneLine(node.activity)}`);
          return `- ${parts.join(" | ")}`;
        });
        return { text: lines.join("\n") };
      },
    },
    {
      name: "edges",
      description:
        "Edges touching this loop, or every edge in its graph with all=true: kind (handoff sequences, message talks, spawn instantiates), condition, and whether it has fired.",
      inputSchema: {
        type: "object",
        properties: { all: { type: "boolean", description: "Every edge in the graph, not just yours." } },
      },
      readOnly: true,
      async handler(args) {
        const g = await graph();
        const level = levelOf(g, ctx.nodeID) ?? g;
        const titles = new Map(allNodes(g).map((n) => [n.id.toLowerCase(), n.title]));
        const mine = (id: string) => id.toLowerCase() === ctx.nodeID.toLowerCase();
        const edges = args.all === true ? level.edges : level.edges.filter((e) => mine(e.from) || mine(e.to));
        if (edges.length === 0) return { text: "No edges." };
        return {
          text: edges
            .map((edge) => {
              const condition = typeof edge.condition === "string" ? edge.condition : stateName(edge.condition);
              const fired = (edge.fireCount ?? 0) > 0 ? `fired ${edge.fireCount}×` : "not fired";
              const from = titles.get(edge.from.toLowerCase()) ?? edge.from;
              const to = titles.get(edge.to.toLowerCase()) ?? edge.to;
              return `- ${from} → ${to} · ${edge.kind} · ${condition} · ${fired}`;
            })
            .join("\n"),
        };
      },
    },
    {
      name: "handoff_briefs",
      description:
        "What upstream loops hand to this one: each source's brief, state, result and what its edge carries. Read this before starting work that continues someone else's.",
      inputSchema: { type: "object", properties: {} },
      readOnly: true,
      async handler() {
        const g = await graph();
        const level = levelOf(g, ctx.nodeID) ?? g;
        const inbound = level.edges.filter(
          (e) => e.kind !== "message" && e.to.toLowerCase() === ctx.nodeID.toLowerCase(),
        );
        if (inbound.length === 0) return { text: "Nothing hands off to this loop." };
        return {
          text: inbound
            .map((edge) => {
              const source = level.nodes.find((n) => n.id.toLowerCase() === edge.from.toLowerCase());
              if (!source) return `- ${edge.from}: source no longer in the graph`;
              const lines = [
                `- ${source.title} (${source.id}) · ${stateName(source.state)} · ${(edge.fireCount ?? 0) > 0 ? "handed off" : "not yet handed off"}`,
              ];
              const handed = source.goal?.summary ?? source.firstInstruction ?? source.triggerPrompt;
              if (handed) lines.push(`  was handed: ${handed.trim()}`);
              if (source.resolution?.detail) lines.push(`  result: ${source.resolution.detail.trim()}`);
              lines.push(`  the edge carries ${payloadDescription(edge.payloadTransform)}`);
              return lines.join("\n");
            })
            .join("\n"),
        };
      },
    },
    {
      name: "mailroom",
      description:
        "The project's Mailroom: notices any loop posted for whoever comes next, newest last. Read-only — your read cursor does not move. Bodies are cut short; use mailroom_read for one in full.",
      inputSchema: {
        type: "object",
        properties: {
          search: { type: "string", description: "Substring across author, topic and body." },
          unread: { type: "boolean", description: "Only posts this loop has not read yet." },
          limit: { type: "number", description: "At most this many, newest kept. Default 20." },
        },
      },
      readOnly: true,
      async handler(args) {
        const selection: Json = args.unread === true ? { unread: { reader: ctx.nodeID } } : { board: {} };
        const search = typeof args.search === "string" && args.search.length > 0 ? args.search : null;
        const box = (await ctx.daemon.mailbox(ctx.projectPath, {
          selection,
          search,
          fullBodies: false,
          advanceCursor: false,
        })) as { posts?: Array<Record<string, Json>> };
        const limit = typeof args.limit === "number" && args.limit > 0 ? Math.floor(args.limit) : 20;
        const posts = (box.posts ?? []).slice(-limit);
        if (posts.length === 0) return { text: "No posts." };
        return { text: posts.map(formatPost).join("\n") };
      },
    },
    {
      name: "mailroom_read",
      description: "One Mailroom post in full, by id.",
      inputSchema: { type: "object", properties: { id: { type: "number" } }, required: ["id"] },
      readOnly: true,
      async handler(args) {
        if (typeof args.id !== "number") return { text: "id must be a post number.", isError: true };
        const box = (await ctx.daemon.mailbox(ctx.projectPath, {
          selection: { post: { id: args.id } },
          search: null,
          fullBodies: true,
          advanceCursor: false,
        })) as { posts?: Array<Record<string, Json>> };
        const post = box.posts?.[0];
        return post ? { text: formatPost(post) } : { text: `No post #${args.id}.`, isError: true };
      },
    },
    {
      name: "ask",
      description:
        "Message another loop — a question or an answer to one. Depending on the human's setting this is drafted for their approval, sent, or refused. Pass inReplyTo with the id of the message you are answering.",
      inputSchema: {
        type: "object",
        properties: {
          to: { type: "string", description: "The loop's title or id." },
          text: { type: "string" },
          inReplyTo: { type: "string", description: "The id of the message this answers, if any." },
        },
        required: ["to", "text"],
      },
      readOnly: false,
      async handler(args) {
        const text = typeof args.text === "string" ? args.text.trim() : "";
        if (!text || typeof args.to !== "string") return { text: "to and text are required.", isError: true };
        const target = resolveLoop(await graph(), args.to, ctx.nodeID);
        if (!target) return { text: `No loop called ${args.to}. Call siblings to see who is there.`, isError: true };
        const inReplyTo = typeof args.inReplyTo === "string" ? args.inReplyTo : undefined;
        return deliver([target], text, inReplyTo);
      },
    },
    {
      name: "handoff",
      description:
        "Pass a brief downstream: to every loop this one hands off to, or to the named loop. Use when your part is done and the next loop should know what you found. Gated like ask.",
      inputSchema: {
        type: "object",
        properties: {
          brief: { type: "string", description: "What the next loop needs to know." },
          to: { type: "string", description: "A loop's title or id; default is every downstream loop." },
        },
        required: ["brief"],
      },
      readOnly: false,
      async handler(args) {
        const text = typeof args.brief === "string" ? args.brief.trim() : "";
        if (!text) return { text: "brief is required.", isError: true };
        const g = await graph();
        let targets: WireNode[];
        if (typeof args.to === "string" && args.to.length > 0) {
          const target = resolveLoop(g, args.to, ctx.nodeID);
          if (!target) return { text: `No loop called ${args.to}.`, isError: true };
          targets = [target];
        } else {
          targets = downstream(g, ctx.nodeID);
          if (targets.length === 0) {
            return { text: "Nothing is downstream of this loop; name a loop with to.", isError: true };
          }
        }
        return deliver(targets, handoffPrefix + text);
      },
    },
  ];
}

/**
 * Sends one message as this loop — what `sendDraft` on the control socket does once the
 * human approves a draft, and what `ask`/`handoff` do under the Send policy.
 */
export async function sendDraft(ctx: Pick<GraphcodeToolContext, "nodeID" | "projectPath" | "daemon">, draft: {
  toNodeID: string;
  text: string;
}): Promise<void> {
  await ctx.daemon.graphCommand(ctx.projectPath, {
    messageNode: { _0: draft.toNodeID.toUpperCase(), text: draft.text, from: ctx.nodeID.toUpperCase(), followUp: true },
  });
}

function formatPost(post: Record<string, Json>): string {
  const topic = typeof post.topic === "string" ? ` (${post.topic})` : "";
  const at = referenceDate(post.at);
  return `#${post.id}${topic} ${post.author ?? "unknown"}${at ? ` · ${at}` : ""}: ${post.body ?? ""}`;
}
