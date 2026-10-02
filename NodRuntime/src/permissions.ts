import { existsSync, realpathSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve } from "node:path";
import type { EventLog } from "./eventLog";
import { serverName } from "./mcp";
import type { NodPermissionDecision, NodPermissionKind } from "./protocol";
import type { Ask, NodSettings } from "./settings";

/** What a tool call wants to do, as far as the gate cares. Engines map their own tools onto it. */
export type ToolIntent =
  | { kind: "read" }
  | { kind: "shell"; command: string }
  | { kind: "fetch"; url: string }
  | { kind: "edit"; path: string }
  | { kind: "mcp"; server: string; tool: string }
  | { kind: "messageLoop"; subject: string };

export type GateVerdict =
  | { verdict: "allow" }
  /** An edit inside the worktree: allowed, but through the hunk stager. */
  | { verdict: "stage" }
  | { verdict: "deny"; message: string }
  /** An unattended loop needed a human; the run fails rather than waiting. */
  | { verdict: "fail"; message: string };

export interface GateOptions {
  settings: NodSettings;
  worktree: string;
  /** Timed loops and composite children: nobody is there to answer. */
  unattended: boolean;
  log: EventLog;
  /** Called when an ask opens and when the last one closes, for presence. */
  onAwaiting?: (awaiting: boolean) => void;
}

interface OpenAsk {
  kind: NodPermissionKind;
  subject: string;
  resolve: (decision: NodPermissionDecision) => void;
}

/**
 * Gates shell, network, out-of-worktree and project-MCP work by `NodSettings` and the shell allowlist.
 * Reads, searches and in-worktree edits never ask here — edits are reviewed as hunks.
 */
export class PermissionGate {
  private asks = new Map<string, OpenAsk>();
  private sessionAllowed = new Set<string>();
  private nextID = 1;

  constructor(private readonly options: GateOptions) {}

  get openAsks(): number {
    return this.asks.size;
  }

  async check(intent: ToolIntent): Promise<GateVerdict> {
    const { settings } = this.options;
    switch (intent.kind) {
      case "read":
        return { verdict: "allow" };
      case "edit":
        if (isInside(this.options.worktree, intent.path)) return { verdict: "stage" };
        return this.byPolicy(settings.editsOutsideWorktree, "editOutsideWorktree", intent.path,
          "Edits a file outside this loop's worktree.");
      case "shell": {
        if (matchesAllowlist(intent.command, settings.shellAllowlist)) return { verdict: "allow" };
        const network = usesNetwork(intent.command);
        if (network) {
          if (settings.shell === "never") return deny("shell", intent.command);
          return this.byPolicy(settings.network, "network", intent.command,
            "Reaches the network. Not in this project's allowlist.");
        }
        return this.byPolicy(settings.shell, "shell", intent.command, "Not in this project's allowlist.");
      }
      case "fetch":
        return this.byPolicy(settings.network, "network", intent.url, "Fetches a URL.");
      case "mcp":
        // graphcode's own tools apply messagesOtherLoops themselves, as drafts or refusals.
        if (intent.server === serverName) return { verdict: "allow" };
        return this.ask("mcpTool", `${intent.server}/${intent.tool}`, "Calls a tool on one of this project's MCP servers.");
      case "messageLoop":
        if (settings.messagesOtherLoops === "send") return { verdict: "allow" };
        if (settings.messagesOtherLoops === "never") return deny("messageLoop", intent.subject);
        return this.ask("messageLoop", intent.subject, "Sends a message to another loop.");
    }
  }

  resolve(askID: string, decision: NodPermissionDecision): void {
    const ask = this.asks.get(askID);
    if (!ask) throw new Error(`no open ask ${askID}`);
    this.asks.delete(askID);
    if (decision === "alwaysAllow") this.sessionAllowed.add(key(ask.kind, ask.subject));
    this.options.log.append({ type: "permissionResolved", askID, decision });
    if (this.asks.size === 0) this.options.onAwaiting?.(false);
    ask.resolve(decision);
  }

  /** A stopped turn takes its open asks with it. */
  denyAll(): void {
    for (const askID of [...this.asks.keys()]) this.resolve(askID, "deny");
  }

  private byPolicy(policy: Ask, kind: NodPermissionKind, subject: string, reason: string): Promise<GateVerdict> | GateVerdict {
    if (policy === "always") return { verdict: "allow" };
    if (policy === "never") return deny(kind, subject);
    return this.ask(kind, subject, reason);
  }

  private async ask(kind: NodPermissionKind, subject: string, reason: string): Promise<GateVerdict> {
    if (this.sessionAllowed.has(key(kind, subject))) return { verdict: "allow" };
    if (this.options.unattended) {
      return {
        verdict: "fail",
        message: `This loop runs unattended and cannot stop to ask: ${describe(kind)} \`${subject}\`. ${reason}`,
      };
    }
    const askID = `p${this.nextID++}`;
    const decision = await new Promise<NodPermissionDecision>((resolve) => {
      this.asks.set(askID, { kind, subject, resolve });
      this.options.log.append({
        type: "permissionAsked",
        askID,
        kind,
        subject,
        reason,
        answerableFromCard: kind === "shell" && isReadOnlyCommand(subject),
      });
      if (this.asks.size === 1) this.options.onAwaiting?.(true);
    });
    return decision === "deny"
      ? { verdict: "deny", message: `The human denied this: ${describe(kind)} \`${subject}\`.` }
      : { verdict: "allow" };
  }
}

function deny(kind: NodPermissionKind, subject: string): GateVerdict {
  return { verdict: "deny", message: `Nod's settings never allow this: ${describe(kind)} \`${subject}\`.` };
}

function describe(kind: NodPermissionKind): string {
  switch (kind) {
    case "shell": return "run a command";
    case "network": return "reach the network";
    case "editOutsideWorktree": return "edit outside the worktree";
    case "messageLoop": return "message another loop";
    case "mcpTool": return "use an MCP tool";
  }
}

function key(kind: NodPermissionKind, subject: string): string {
  return `${kind}\u0000${subject}`;
}

/**
 * Compared as real paths: engines report symlink-resolved paths (`/private/tmp/…` for a
 * worktree opened as `/tmp/…`), and a file that doesn't exist yet resolves through its
 * nearest existing ancestor.
 */
export function isInside(root: string, path: string): boolean {
  const rel = relative(realPath(resolve(root)), realPath(resolve(root, path)));
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

export function realPath(path: string): string {
  if (existsSync(path)) return realpathSync(path);
  const parent = dirname(path);
  return parent === path ? path : join(realPath(parent), basename(path));
}

/**
 * Allowlist patterns are words: `*` alone matches any number of further words (`swift test
 * *`), `*` inside a word is a wildcard, and `a|b|c` is one word of alternatives
 * (`git status|diff|log`). A compound command is allowed only if every part is, and a
 * command with substitutions never is — its real argv isn't known until it runs.
 */
export function matchesAllowlist(command: string, patterns: string[]): boolean {
  if (patterns.length === 0) return false;
  if (/`|\$\(|<\(|>\(/.test(command)) return false;
  const parts = command.split(/&&|\|\||;|\||\n/).map((p) => p.trim()).filter(Boolean);
  if (parts.length === 0) return false;
  const regexes = patterns.map(patternRegex);
  return parts.every((part) => regexes.some((re) => re.test(part)));
}

function patternRegex(pattern: string): RegExp {
  const words = pattern.trim().split(/\s+/);
  let source = "";
  words.forEach((word, i) => {
    if (word === "*") {
      source += i === 0 ? "\\S+(?:\\s+\\S+)*" : "(?:\\s+\\S+)*";
      return;
    }
    const alternatives = word.split("|").map((alt) => alt.split("*").map(escape).join("\\S*"));
    source += (i === 0 ? "" : "\\s+") + `(?:${alternatives.join("|")})`;
  });
  return new RegExp(`^${source}$`);
}

function escape(text: string): string {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

const networkCommands: RegExp[] = [
  /^(curl|wget|ssh|scp|sftp|rsync|nc|ncat|telnet|ping|dig|nslookup|ftp|gh|brew)\b/,
  /^git\s+(clone|fetch|pull|push|ls-remote|remote\s+update|submodule\s+(update|sync))\b/,
  /^(npm|pnpm|yarn|bun)\s+(install|i|add|ci|update|upgrade|publish|dlx|create)\b/,
  /^(npx|bunx|pnpx|uvx)\b/,
  /^(pip3?|uv\s+pip|pipx)\s+install\b/,
  /^(uv|poetry)\s+(add|sync|lock|install)\b/,
  /^swift\s+package\s+(resolve|update|reset)\b/,
  /^(cargo)\s+(install|fetch|update|add|publish)\b/,
  /^go\s+(get|install|mod\s+download)\b/,
  /^(docker|podman)\s+(pull|push|login)\b/,
  /^(gem|bundle)\s+(install|update)\b/,
  /^(pod)\s+(install|update|repo)\b/,
  /^tuist\s+install\b/,
];

export function usesNetwork(command: string): boolean {
  return command
    .split(/&&|\|\||;|\||\n/)
    .map((part) => part.trim().replace(/^(sudo|env(\s+\w+=\S+)*|time)\s+/, ""))
    .some((part) => networkCommands.some((re) => re.test(part)));
}

const readOnlyHeads = /^(ls|cat|head|tail|wc|grep|rg|find|pwd|which|file|stat|du|df|tree|echo|git\s+(status|diff|log|show|branch|blame))\b/;

export function isReadOnlyCommand(command: string): boolean {
  if (/[>]|`|\$\(|-delete\b|-exec\b/.test(command)) return false;
  return command
    .split(/&&|\|\||;|\|/)
    .map((part) => part.trim())
    .filter(Boolean)
    .every((part) => readOnlyHeads.test(part));
}
