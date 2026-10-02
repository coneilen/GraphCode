// The TypeScript side of GraphcodeKit/Sources/Domain/NodProtocol.swift. PROTOCOL.md is the
// prose version; the three change together.

export const PROTOCOL_VERSION = 1;

export type NodEngineKind = "claude" | "copilot";
export type NodDelivery = "queue" | "steer";
export type NodTurnOrigin = "user" | "queue" | "steer" | "handoff" | "mail" | "timer" | "goalCheck";
export type NodPermissionKind = "shell" | "network" | "editOutsideWorktree" | "messageLoop" | "mcpTool";
export type NodPermissionDecision = "allowOnce" | "alwaysAllow" | "deny";
export type NodHunkDecision = "accept" | "reject" | "comment";
export type NodToolStatus = "running" | "ok" | "error";
export type NodFailureKind =
  | "signInExpired"
  | "contextFull"
  | "spendCap"
  | "permissionUnavailable"
  | "engineError";

export interface NodAttachment {
  kind: "file" | "image" | "loopTranscript";
  reference: string;
  label?: string;
}

export interface NodGoalClause {
  text: string;
  met: boolean;
  evidence?: string;
}

export interface NodPlanStep {
  id: string;
  text: string;
  files: string[];
  size?: "small" | "medium" | "large";
  editedByHuman: boolean;
}

export type NodEvent =
  | { type: "sessionStarted"; engine: NodEngineKind; model: string; conversationID: string; resumed: boolean }
  | { type: "turnStarted"; turn: number; origin: NodTurnOrigin }
  | {
      type: "userMessage";
      id: string;
      text: string;
      delivery: NodDelivery;
      attachments: NodAttachment[];
      fromNodeID?: string;
    }
  | { type: "assistantText"; turn: number; messageID: string; delta: string; final: boolean }
  | { type: "toolCall"; turn: number; callID: string; tool: string; title: string }
  | {
      type: "toolResult";
      callID: string;
      status: NodToolStatus;
      summary: string;
      output?: string;
      durationMs?: number;
    }
  | {
      type: "hunkStaged";
      turn: number;
      hunkID: string;
      file: string;
      header: string;
      diff: string;
      added: number;
      removed: number;
      autoAccepted: boolean;
    }
  | { type: "hunkResolved"; hunkID: string; decision: NodHunkDecision; note?: string }
  | {
      type: "permissionAsked";
      askID: string;
      kind: NodPermissionKind;
      subject: string;
      reason: string;
      answerableFromCard: boolean;
    }
  | { type: "permissionResolved"; askID: string; decision: NodPermissionDecision }
  | { type: "goalCheck"; turn: number; evaluatorModel: string; clauses: NodGoalClause[]; met: boolean }
  | { type: "turnEnded"; turn: number; filesChanged: number; added: number; removed: number; summary?: string }
  | {
      type: "usage";
      inputTokens: number;
      outputTokens: number;
      costUSD?: number;
      premiumRequests?: number;
      contextUsed: number;
    }
  | { type: "planProposed"; planID: string; title: string; steps: NodPlanStep[] }
  | { type: "mailDraft"; draftID: string; toNodeID: string; inReplyTo?: string; text: string }
  | { type: "compacted"; fromTurn: number; throughTurn: number }
  | { type: "activity"; line: string }
  | { type: "failure"; kind: NodFailureKind; message: string };

export type NodEventRecord = NodEvent & { v: number; seq: number; at: string };

export type NodCommand =
  | { type: "send"; text: string; delivery: NodDelivery; attachments: NodAttachment[] }
  | { type: "stop" }
  | { type: "resolveHunk"; hunkID: string; decision: NodHunkDecision; note?: string }
  | { type: "resolvePermission"; askID: string; decision: NodPermissionDecision }
  | { type: "runPlan"; planID: string; steps: NodPlanStep[]; mode: "here" | "composite" }
  | { type: "fork"; messageID: string }
  | { type: "sendDraft"; draftID: string; text: string }
  | { type: "compact" }
  | { type: "setModel"; model: string }
  | { type: "markGoalDone" };

/** Swift's `.iso8601` date strategy rejects fractional seconds, so `at` never carries them. */
export function wireDate(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

const deliveries = new Set(["queue", "steer"]);
const hunkDecisions = new Set(["accept", "reject", "comment"]);
const permissionDecisions = new Set(["allowOnce", "alwaysAllow", "deny"]);
const attachmentKinds = new Set(["file", "image", "loopTranscript"]);

/**
 * Validates one control-socket line into a command, mirroring `NodCommand`'s Swift decoder:
 * an unknown type or a missing required field is an error, unknown extra fields are ignored.
 */
export function parseCommand(line: string): NodCommand {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    throw new Error("not JSON");
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) throw new Error("not an object");
  const o = raw as Record<string, unknown>;
  const str = (key: string): string => {
    const value = o[key];
    if (typeof value !== "string") throw new Error(`${String(o.type)}: missing ${key}`);
    return value;
  };
  const optStr = (key: string): string | undefined => {
    const value = o[key];
    if (value === undefined || value === null) return undefined;
    if (typeof value !== "string") throw new Error(`${String(o.type)}: ${key} is not a string`);
    return value;
  };
  const oneOf = <T extends string>(key: string, allowed: Set<string>): T => {
    const value = str(key);
    if (!allowed.has(value)) throw new Error(`${String(o.type)}: bad ${key} ${value}`);
    return value as T;
  };
  switch (o.type) {
    case "send": {
      const attachments = Array.isArray(o.attachments) ? o.attachments.map(parseAttachment) : [];
      const delivery = o.delivery === undefined ? "queue" : oneOf<NodDelivery>("delivery", deliveries);
      return { type: "send", text: str("text"), delivery, attachments };
    }
    case "stop":
    case "compact":
    case "markGoalDone":
      return { type: o.type };
    case "resolveHunk":
      return {
        type: "resolveHunk",
        hunkID: str("hunkID"),
        decision: oneOf<NodHunkDecision>("decision", hunkDecisions),
        note: optStr("note"),
      };
    case "resolvePermission":
      return {
        type: "resolvePermission",
        askID: str("askID"),
        decision: oneOf<NodPermissionDecision>("decision", permissionDecisions),
      };
    case "runPlan": {
      if (!Array.isArray(o.steps)) throw new Error("runPlan: missing steps");
      const mode = str("mode");
      if (mode !== "here" && mode !== "composite") throw new Error(`runPlan: bad mode ${mode}`);
      return { type: "runPlan", planID: str("planID"), steps: o.steps.map(parseStep), mode };
    }
    case "fork":
      return { type: "fork", messageID: str("messageID") };
    case "sendDraft":
      return { type: "sendDraft", draftID: str("draftID"), text: str("text") };
    case "setModel":
      return { type: "setModel", model: str("model") };
    default:
      throw new Error(`unknown Nod command ${String(o.type)}`);
  }
}

function parseAttachment(value: unknown): NodAttachment {
  const o = (value ?? {}) as Record<string, unknown>;
  if (typeof o.kind !== "string" || !attachmentKinds.has(o.kind)) throw new Error("attachment: bad kind");
  if (typeof o.reference !== "string") throw new Error("attachment: missing reference");
  return {
    kind: o.kind as NodAttachment["kind"],
    reference: o.reference,
    label: typeof o.label === "string" ? o.label : undefined,
  };
}

function parseStep(value: unknown): NodPlanStep {
  const o = (value ?? {}) as Record<string, unknown>;
  if (typeof o.id !== "string" || typeof o.text !== "string") throw new Error("plan step: missing id or text");
  return {
    id: o.id,
    text: o.text,
    files: Array.isArray(o.files) ? o.files.filter((f): f is string => typeof f === "string") : [],
    size: o.size === "small" || o.size === "medium" || o.size === "large" ? o.size : undefined,
    editedByHuman: o.editedByHuman === true,
  };
}
