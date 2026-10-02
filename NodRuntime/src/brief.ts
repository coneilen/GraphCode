import { readFileSync } from "node:fs";
import type { NodAttachment } from "./protocol";

/** `--inherit <path>`: the brief a composite child or fork starts from (PROTOCOL.md, Inherited briefs). */
export interface NodBrief {
  kind: string;
  fromNodeID?: string;
  text: string;
  attachments: NodAttachment[];
  fork?: { conversationID?: string; messageID: string };
}

export function readBrief(path: string): NodBrief {
  const raw = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
  if (typeof raw.text !== "string") throw new Error(`brief ${path} has no text`);
  const fork = raw.fork as Record<string, unknown> | undefined;
  return {
    kind: typeof raw.kind === "string" ? raw.kind : "handoff",
    fromNodeID: typeof raw.fromNodeID === "string" ? raw.fromNodeID : undefined,
    text: raw.text,
    attachments: Array.isArray(raw.attachments)
      ? (raw.attachments as NodAttachment[]).filter((a) => typeof a?.kind === "string" && typeof a?.reference === "string")
      : [],
    fork:
      fork && typeof fork.messageID === "string"
        ? { messageID: fork.messageID, conversationID: typeof fork.conversationID === "string" ? fork.conversationID : undefined }
        : undefined,
  };
}
