import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { extname, isAbsolute, resolve } from "node:path";
import {
  query,
  type HookCallback,
  type Options,
  type PermissionResult,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import type { ClaudeCredentials } from "./credentials";
import type { Engine, EngineFailure, EngineSession, EngineStart, ToolRequest, TurnCallbacks, TurnResult } from "./engine";
import type { NodAttachment } from "./protocol";
import { summarizeResult } from "./tools";

/** Tools the gate must see even when the user's own Claude settings would allow them. */
const GATED_TOOLS = /^(Bash|Edit|MultiEdit|Write|NotebookEdit|WebFetch|WebSearch|mcp__.*)$/;

const DEFAULT_CONTEXT_WINDOW = 200_000;
// Used only until the first result reports real spend; then scaled to match it.
const FALLBACK_PRICE = { input: 3 / 1_000_000, output: 15 / 1_000_000 };

/** An async iterable that is fed from outside: the streaming-input prompt of a long-lived query. */
class Inbox<T> implements AsyncIterable<T> {
  private items: T[] = [];
  private waiting?: (result: IteratorResult<T>) => void;
  private done = false;

  push(item: T): void {
    if (this.waiting) {
      const resolve = this.waiting;
      this.waiting = undefined;
      resolve({ value: item, done: false });
    } else this.items.push(item);
  }

  end(): void {
    this.done = true;
    this.waiting?.({ value: undefined, done: true });
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        if (this.items.length > 0) return Promise.resolve({ value: this.items.shift()!, done: false });
        if (this.done) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => (this.waiting = resolve));
      },
    };
  }
}

interface ActiveTurn {
  callbacks: TurnCallbacks;
  lastMessage: string;
  textByMessage: Map<string, string>;
  failure?: EngineFailure;
  interrupted: boolean;
  resolve: (result: TurnResult) => void;
}

export interface ClaudeEngineOptions {
  credentials: ClaudeCredentials;
  /** Claude Code to run; the SDK's bundled build when absent. */
  executable?: string;
}

/**
 * The Claude Agent SDK engine: one long-lived streaming-input query per session, so
 * turns share a Claude Code process. Every gated tool is forced through `canUseTool` by
 * a PreToolUse "ask", which is what makes Nod's gate authoritative over the human's own
 * Claude Code allow rules; steering rides the PostToolUse hook's `additionalContext`.
 */
export class ClaudeEngine implements Engine {
  readonly kind = "claude" as const;
  private q?: Query;
  private inbox?: Inbox<SDKUserMessage>;
  private start_?: EngineStart;
  private conversationID = "";
  private model = "";
  private turn?: ActiveTurn;
  private seenUsage = new Set<string>();
  private tokens = { input: 0, output: 0 };
  private tokensAtLastResult = { input: 0, output: 0 };
  private costAtLastResult = 0;
  private priceScale = 1;
  private contextWindow = DEFAULT_CONTEXT_WINDOW;
  private contextTokens = 0;
  private toolNames = new Map<string, string>();
  private consumer?: Promise<void>;
  /** Stream deltas carry no message id; the message_start before them does. */
  private streamMessageID = "";

  constructor(private readonly options: ClaudeEngineOptions) {}

  async start(start: EngineStart): Promise<EngineSession> {
    this.start_ = start;
    this.conversationID = start.resume ?? randomUUID();
    this.model = start.model ?? "sonnet";
    this.open(Boolean(start.resume));
    return { conversationID: this.conversationID, model: this.model };
  }

  private open(resuming: boolean): void {
    const start = this.start_!;
    this.inbox = new Inbox();
    const options: Options = {
      cwd: start.cwd,
      model: this.model,
      ...(resuming
        ? { resume: this.conversationID }
        : start.forkFrom
          ? { resume: start.forkFrom, forkSession: true, sessionId: this.conversationID }
          : { sessionId: this.conversationID }),
      permissionMode: "default",
      includePartialMessages: true,
      settingSources: ["user", "project", "local"],
      systemPrompt: { type: "preset", preset: "claude_code", append: start.systemAppend },
      canUseTool: (tool, input, { signal }) => this.canUseTool(tool, input, signal),
      hooks: {
        PreToolUse: [{ hooks: [this.preToolUse] }],
        PostToolUse: [{ hooks: [this.postToolUse] }],
      },
      env: { ...process.env, ...this.options.credentials.env, CLAUDE_AGENT_SDK_CLIENT_APP: "graphcode-nod" },
      ...(this.options.executable ? { pathToClaudeCodeExecutable: this.options.executable } : {}),
      stderr: () => {},
    };
    this.q = query({ prompt: this.inbox, options });
    this.consumer = this.consume(this.q);
  }

  async runTurn(text: string, attachments: NodAttachment[], callbacks: TurnCallbacks): Promise<TurnResult> {
    if (!this.q) this.open(true);
    return new Promise<TurnResult>((resolve) => {
      this.turn = { callbacks, lastMessage: "", textByMessage: new Map(), interrupted: false, resolve };
      this.inbox!.push(userMessage(text, attachments, this.start_!.cwd));
    });
  }

  async interrupt(): Promise<void> {
    if (!this.turn) return;
    this.turn.interrupted = true;
    await this.q?.interrupt().catch(() => {});
  }

  async setModel(model: string): Promise<void> {
    this.model = model;
    await this.q?.setModel(model);
  }

  compact(callbacks: TurnCallbacks): Promise<TurnResult> {
    return this.runTurn("/compact", [], callbacks);
  }

  async ask(prompt: string, model?: string): Promise<string> {
    const q = query({
      prompt,
      options: {
        cwd: this.start_?.cwd ?? process.cwd(),
        ...(model || this.model ? { model: model || this.model } : {}),
        tools: [],
        maxTurns: 1,
        permissionMode: "dontAsk",
        settingSources: [],
        persistSession: false,
        env: { ...process.env, ...this.options.credentials.env, CLAUDE_AGENT_SDK_CLIENT_APP: "graphcode-nod" },
        ...(this.options.executable ? { pathToClaudeCodeExecutable: this.options.executable } : {}),
        stderr: () => {},
      },
    });
    let text = "";
    for await (const message of q) {
      if (message.type === "assistant" && !message.parent_tool_use_id) {
        const failure = assistantFailure(message.error);
        if (failure) throw new Error(failure.message);
        text = textOf(message.message.content);
      }
      if (message.type === "result") {
        if (message.subtype === "success" && message.result) text = message.result;
        else if (message.subtype !== "success") throw new Error(message.errors.join("; ") || message.subtype);
      }
    }
    return text;
  }

  async close(): Promise<void> {
    this.inbox?.end();
    this.q?.close();
    await this.consumer?.catch(() => {});
  }

  private preToolUse: HookCallback = async (input) => {
    if (input.hook_event_name !== "PreToolUse" || !GATED_TOOLS.test(input.tool_name)) return {};
    return {
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: "GraphCode Nod reviews this tool call",
      },
    };
  };

  private postToolUse: HookCallback = async (input) => {
    if (input.hook_event_name !== "PostToolUse") return {};
    const steer = this.turn?.callbacks.takeSteer();
    return steer ? { hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: steer } } : {};
  };

  private async canUseTool(tool: string, input: Record<string, unknown>, signal: AbortSignal): Promise<PermissionResult> {
    const turn = this.turn;
    if (!turn) return { behavior: "deny", message: "No turn is running." };
    const request = toolRequest(tool, input, this.start_!.cwd);
    const aborted = new Promise<PermissionResult>((resolve) =>
      signal.addEventListener("abort", () => resolve({ behavior: "deny", message: "The turn was stopped." }), { once: true }),
    );
    const decided = turn.callbacks.authorize(request).then<PermissionResult>((authorization) =>
      authorization.allow
        ? { behavior: "allow", updatedInput: input }
        : { behavior: "deny", message: authorization.message, interrupt: authorization.interrupt },
    );
    const result = await Promise.race([decided, aborted]);
    if (result.behavior === "deny" && result.interrupt) turn.interrupted = true;
    return result;
  }

  private async consume(q: Query): Promise<void> {
    try {
      for await (const message of q) this.onMessage(message);
      this.finishTurn({ kind: "engineError", message: "Claude Code exited." });
    } catch (error) {
      this.finishTurn(classifyError(error));
    } finally {
      if (this.q === q) {
        this.q = undefined;
        this.inbox = undefined;
      }
    }
  }

  private finishTurn(failure?: EngineFailure): void {
    const turn = this.turn;
    if (!turn) return;
    this.turn = undefined;
    turn.resolve({ lastMessage: turn.lastMessage, failure: failure ?? turn.failure, interrupted: turn.interrupted });
  }

  private onMessage(message: SDKMessage): void {
    const turn = this.turn;
    switch (message.type) {
      case "system":
        if (message.subtype === "init") this.model = message.model;
        else if (message.subtype === "compact_boundary") turn?.callbacks.compacted();
        return;
      case "auth_status":
        if (message.error && turn) turn.failure = { kind: "signInExpired", message: message.error };
        return;
      case "stream_event": {
        if (!turn || message.parent_tool_use_id) return;
        const event = message.event;
        if (event.type === "message_start") this.streamMessageID = event.message.id;
        if (event.type === "content_block_delta" && event.delta.type === "text_delta") {
          const id = this.streamMessageID;
          turn.textByMessage.set(id, (turn.textByMessage.get(id) ?? "") + event.delta.text);
          turn.callbacks.text(id, event.delta.text, false);
        }
        return;
      }
      case "assistant": {
        if (!turn || message.parent_tool_use_id) return;
        const failure = assistantFailure(message.error);
        if (failure) turn.failure = failure;
        const id = message.message.id;
        for (const block of message.message.content) {
          if (block.type === "text") {
            if (!turn.textByMessage.has(id) && block.text) turn.callbacks.text(id, block.text, false);
            turn.textByMessage.set(id, block.text);
            turn.callbacks.text(id, "", true);
            if (block.text.trim()) turn.lastMessage = block.text;
          } else if (block.type === "tool_use") {
            this.toolNames.set(block.id, block.name);
            turn.callbacks.toolCall(block.id, block.name, block.input);
          }
        }
        this.recordUsage(id, message.message.usage);
        return;
      }
      case "user": {
        if (!turn || message.parent_tool_use_id) return;
        const content = message.message.content;
        if (!Array.isArray(content)) return;
        for (const block of content) {
          if (typeof block !== "object" || block === null || block.type !== "tool_result") continue;
          const output = toolResultText(block.content);
          const tool = this.toolNames.get(block.tool_use_id) ?? "";
          const isError = block.is_error === true;
          turn.callbacks.toolResult(block.tool_use_id, isError ? "error" : "ok", summarizeResult(tool, output, isError), output);
        }
        return;
      }
      case "result": {
        for (const usage of Object.values(message.modelUsage ?? {})) {
          if (usage.contextWindow > 0) this.contextWindow = usage.contextWindow;
        }
        this.costAtLastResult = message.total_cost_usd;
        const estimated = this.estimateAtDefaults(this.tokens);
        if (estimated > 0 && message.total_cost_usd > 0) this.priceScale = message.total_cost_usd / estimated;
        this.tokensAtLastResult = { ...this.tokens };
        turn?.callbacks.usage(this.usageReport(message.total_cost_usd));
        if (turn && message.subtype !== "success" && !turn.interrupted) {
          turn.failure ??= resultFailure(message.subtype, message.errors, message.terminal_reason);
        }
        if (turn && message.terminal_reason === "prompt_too_long") {
          turn.failure = { kind: "contextFull", message: "The conversation no longer fits the model's context window." };
        }
        this.finishTurn();
        return;
      }
    }
  }

  private recordUsage(messageID: string, usage: unknown): void {
    // Claude Code repeats a message's usage on every content block; count each message once.
    if (!usage || this.seenUsage.has(messageID)) return;
    this.seenUsage.add(messageID);
    const u = usage as Record<string, number | undefined>;
    const prompt = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
    this.tokens.input += prompt;
    this.tokens.output += u.output_tokens ?? 0;
    this.contextTokens = prompt + (u.output_tokens ?? 0);
    const sinceResult = {
      input: this.tokens.input - this.tokensAtLastResult.input,
      output: this.tokens.output - this.tokensAtLastResult.output,
    };
    const cost = this.costAtLastResult + this.estimateAtDefaults(sinceResult) * this.priceScale;
    this.turn?.callbacks.usage(this.usageReport(cost));
  }

  private estimateAtDefaults(tokens: { input: number; output: number }): number {
    return tokens.input * FALLBACK_PRICE.input + tokens.output * FALLBACK_PRICE.output;
  }

  private usageReport(costUSD: number) {
    return {
      inputTokens: this.tokens.input,
      outputTokens: this.tokens.output,
      costUSD,
      contextUsed: Math.min(1, this.contextTokens / this.contextWindow),
    };
  }
}

function userMessage(text: string, attachments: NodAttachment[], cwd: string): SDKUserMessage {
  const content: Array<Record<string, unknown>> = [];
  const notes: string[] = [];
  for (const attachment of attachments) {
    const path = isAbsolute(attachment.reference) ? attachment.reference : resolve(cwd, attachment.reference);
    if (attachment.kind === "image" && existsSync(path)) {
      const media = { ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp" }[
        extname(path).toLowerCase()
      ];
      if (media) {
        content.push({ type: "image", source: { type: "base64", media_type: media, data: readFileSync(path).toString("base64") } });
        continue;
      }
    }
    if (attachment.kind === "loopTranscript") notes.push(`Attached: the transcript of loop ${attachment.label ?? attachment.reference} (${attachment.reference}).`);
    else notes.push(`Attached file: ${path}`);
  }
  content.push({ type: "text", text: notes.length > 0 ? `${notes.join("\n")}\n\n${text}` : text });
  return {
    type: "user",
    message: { role: "user", content: content.length === 1 ? (content[0]!.text as string) : (content as never) },
    parent_tool_use_id: null,
  };
}

/** Maps a Claude Code tool call onto the gate's vocabulary, computing an edit's result for staging. */
export function toolRequest(tool: string, input: Record<string, unknown>, cwd: string): ToolRequest {
  const str = (key: string) => (typeof input[key] === "string" ? (input[key] as string) : "");
  const path = (key: string) => {
    const value = str(key);
    return value ? (isAbsolute(value) ? value : resolve(cwd, value)) : "";
  };
  switch (tool) {
    case "Bash":
      return { intent: { kind: "shell", command: str("command") } };
    case "WebFetch":
      return { intent: { kind: "fetch", url: str("url") } };
    case "WebSearch":
      return { intent: { kind: "fetch", url: `search: ${str("query")}` } };
    case "Write": {
      const file = path("file_path");
      return { intent: { kind: "edit", path: file }, edit: { path: file, after: str("content") } };
    }
    case "Edit":
    case "MultiEdit": {
      const file = path("file_path");
      const edits =
        tool === "Edit"
          ? [{ old_string: str("old_string"), new_string: str("new_string"), replace_all: input.replace_all === true }]
          : ((input.edits as { old_string: string; new_string: string; replace_all?: boolean }[]) ?? []);
      const before = existsSync(file) ? readFileSync(file, "utf8") : "";
      const after = applyEdits(before, edits);
      return { intent: { kind: "edit", path: file }, ...(after === undefined ? {} : { edit: { path: file, after } }) };
    }
    case "NotebookEdit":
      return { intent: { kind: "edit", path: path("notebook_path") } };
  }
  if (tool.startsWith("mcp__")) {
    const [, server = "", name = ""] = tool.split("__");
    return { intent: { kind: "mcp", server, tool: name } };
  }
  return { intent: { kind: "read" } };
}

/** Claude Code's Edit semantics; undefined when the tool itself would refuse the edit. */
export function applyEdits(text: string, edits: { old_string: string; new_string: string; replace_all?: boolean }[]): string | undefined {
  let result = text;
  for (const edit of edits) {
    if (edit.old_string === "") {
      if (result !== "") return undefined;
      result = edit.new_string;
      continue;
    }
    const count = result.split(edit.old_string).length - 1;
    if (count === 0 || (count > 1 && !edit.replace_all)) return undefined;
    result = edit.replace_all
      ? result.split(edit.old_string).join(edit.new_string)
      : result.replace(edit.old_string, () => edit.new_string);
  }
  return result;
}

function textOf(content: unknown): string {
  if (!Array.isArray(content)) return "";
  return content
    .filter((b): b is { type: "text"; text: string } => b?.type === "text")
    .map((b) => b.text)
    .join("");
}

function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) return textOf(content);
  return "";
}

function assistantFailure(error: string | undefined): EngineFailure | undefined {
  switch (error) {
    case undefined:
      return undefined;
    case "authentication_failed":
    case "oauth_org_not_allowed":
    case "verification_required":
    case "cloud_credential_error":
      return { kind: "signInExpired", message: "Claude sign-in expired. Sign in again to continue." };
    case "max_output_tokens":
      return undefined;
    default:
      return { kind: "engineError", message: `Claude reported ${error.replace(/_/g, " ")}.` };
  }
}

function resultFailure(subtype: string, errors: string[], terminal?: string): EngineFailure {
  if (subtype === "error_max_budget_usd") return { kind: "spendCap", message: "The Claude budget for this session ran out." };
  const detail = errors.filter(Boolean).join("; ");
  return { kind: "engineError", message: detail || `Claude stopped: ${terminal ?? subtype}` };
}

function classifyError(error: unknown): EngineFailure {
  const message = error instanceof Error ? error.message : String(error);
  if (/auth|login|api key|401|403/i.test(message)) return { kind: "signInExpired", message };
  return { kind: "engineError", message };
}
