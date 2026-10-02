/**
 * Reading a graphcoded `LoopGraph` snapshot from Nod's seat in it. Mirrors the Swift side
 * (`NodGraphContext`, `NodInboundMail`, `NodGraphVerb`) so the chat pane and the agent
 * agree on who is upstream, downstream and beside.
 */

export interface WireNode {
  id: string;
  title: string;
  loopType: string;
  state: unknown;
  backend?: string;
  goal?: { summary?: string };
  firstInstruction?: string;
  triggerPrompt?: string;
  checkDescription?: string;
  activity?: string;
  resolution?: { basis?: unknown; detail?: string };
  lineage?: { kind: string; sourceNodeID: string; briefPath?: string };
  subGraph?: WireGraph;
}

export interface WireEdge {
  id: string;
  from: string;
  to: string;
  kind: "handoff" | "message" | "spawn" | string;
  condition?: unknown;
  payloadTransform?: unknown;
  fireCount?: number;
}

export interface WireGraph {
  nodes: WireNode[];
  edges: WireEdge[];
}

export type Relation = "from" | "to" | "beside" | "none";

const same = (a: string | undefined, b: string | undefined) =>
  !!a && !!b && a.toLowerCase() === b.toLowerCase();

/** Swift encodes enum states as `{"running": {}}`. */
export function stateName(state: unknown): string {
  if (typeof state === "string") return state;
  if (state && typeof state === "object") return Object.keys(state)[0] ?? "unknown";
  return "unknown";
}

/** The graph level holding `nodeID` — the root, or a composite's sub-graph. */
export function levelOf(graph: WireGraph, nodeID: string): WireGraph | undefined {
  if (graph.nodes.some((node) => same(node.id, nodeID))) return graph;
  for (const node of graph.nodes) {
    const found = node.subGraph && levelOf(node.subGraph, nodeID);
    if (found) return found;
  }
  return undefined;
}

export function allNodes(graph: WireGraph): WireNode[] {
  return graph.nodes.flatMap((node) => [node, ...(node.subGraph ? allNodes(node.subGraph) : [])]);
}

export function oneLine(text: string | undefined, limit = 160): string | undefined {
  const line = text?.split("\n").find((l) => l.trim().length > 0)?.trim();
  if (!line) return undefined;
  return line.length > limit ? `${line.slice(0, limit - 1)}…` : line;
}

export function brief(node: WireNode): string | undefined {
  return oneLine(node.goal?.summary ?? node.firstInstruction ?? node.triggerPrompt ?? node.checkDescription);
}

export function relationOf(level: WireGraph, nodeID: string, otherID: string): Relation {
  for (const edge of level.edges) {
    const sequencing = edge.kind !== "message";
    if (same(edge.from, otherID) && same(edge.to, nodeID)) return sequencing ? "from" : "beside";
    if (same(edge.from, nodeID) && same(edge.to, otherID)) return sequencing ? "to" : "beside";
  }
  const other = level.nodes.find((n) => same(n.id, otherID));
  const me = level.nodes.find((n) => same(n.id, nodeID));
  const forked =
    (other?.lineage?.kind === "fork" && same(other.lineage.sourceNodeID, nodeID)) ||
    (me?.lineage?.kind === "fork" && same(me.lineage.sourceNodeID, otherID));
  return forked ? "beside" : "none";
}

export function downstream(graph: WireGraph, nodeID: string): WireNode[] {
  const level = levelOf(graph, nodeID);
  if (!level) return [];
  return level.edges
    .filter((edge) => edge.kind === "handoff" && same(edge.from, nodeID))
    .map((edge) => level.nodes.find((node) => same(node.id, edge.to)))
    .filter((node): node is WireNode => !!node);
}

/** Exact title (any case), then a unique prefix, then an id — `@bill` finds BillingUI. */
export function resolveLoop(graph: WireGraph, name: string, excluding: string): WireNode | undefined {
  const wanted = name.replace(/^@/, "").toLowerCase();
  const candidates = allNodes(graph).filter((node) => !same(node.id, excluding));
  const exact = candidates.find((node) => node.title.toLowerCase() === wanted);
  if (exact) return exact;
  const prefixed = candidates.filter((node) => node.title.toLowerCase().startsWith(wanted));
  if (prefixed.length === 1) return prefixed[0];
  return candidates.find((node) => node.id.toLowerCase() === wanted);
}

export const handoffPrefix = "Handoff: ";
const notice = "[graphcode] ";

export interface InboundMail {
  kind: "mail" | "handoff";
  senderID: string;
  senderTitle: string;
  body: string;
}

/**
 * Who a typed `[graphcode] <Sender>: <text>` line came from, so a reply can be drafted to
 * the right loop. Nil for a human's line or a notice no loop sent.
 */
export function classifyInbound(text: string, graph: WireGraph, nodeID: string): InboundMail | undefined {
  if (!text.startsWith(notice)) return undefined;
  const rest = text.slice(notice.length);
  const byLength = [...allNodes(graph)].sort((a, b) => b.title.length - a.title.length);
  for (const node of byLength) {
    let body: string | undefined;
    if (rest.startsWith(`${node.title}: `)) body = rest.slice(node.title.length + 2);
    else if (rest === `${node.title} finished.`) body = "";
    if (body === undefined) continue;
    let kind: InboundMail["kind"] = "mail";
    if (body.startsWith(handoffPrefix)) {
      body = body.slice(handoffPrefix.length);
      kind = "handoff";
    } else {
      const level = levelOf(graph, nodeID);
      if (level?.edges.some((e) => e.kind === "handoff" && same(e.from, node.id) && same(e.to, nodeID))) {
        kind = "handoff";
      }
    }
    return { kind, senderID: node.id, senderTitle: node.title, body };
  }
  return undefined;
}

/** What an inbound handoff edge carries, in words. */
export function payloadDescription(transform: unknown): string {
  if (!transform || typeof transform !== "object") return "a note that the source finished";
  const [kind, value] = Object.entries(transform as Record<string, unknown>)[0] ?? [];
  const inner = (value as { _0?: unknown } | undefined)?._0;
  if (kind === "template" && typeof inner === "string") return `the brief: ${inner}`;
  if (kind === "script") return "the output of a script run when the source finishes";
  return "a note that the source finished";
}

/** Foundation encodes dates as seconds since 2001-01-01. */
export function referenceDate(seconds: unknown): string | undefined {
  if (typeof seconds !== "number") return undefined;
  return new Date((seconds + 978_307_200) * 1000).toISOString();
}
