import type { Engine, EngineSession, EngineStart, TurnCallbacks, TurnResult } from "../src/engine";
import type { NodAttachment, NodEngineKind } from "../src/protocol";

export type TurnScript = (callbacks: TurnCallbacks, text: string, engine: FakeEngine) => Promise<TurnResult> | TurnResult;

/** An engine whose turns are scripts, so tests drive exactly the reports a real SDK would make. */
export class FakeEngine implements Engine {
  readonly turns: string[] = [];
  readonly asks: { prompt: string; model?: string }[] = [];
  started?: EngineStart;
  interrupted = 0;
  model = "fake-model";
  private abort?: () => void;

  constructor(
    private scripts: TurnScript[] = [],
    private answers: ((prompt: string) => string)[] = [],
    readonly kind: NodEngineKind = "claude",
  ) {}

  queueTurn(script: TurnScript): void {
    this.scripts.push(script);
  }

  queueAnswer(answer: string | ((prompt: string) => string)): void {
    this.answers.push(typeof answer === "string" ? () => answer : answer);
  }

  async start(options: EngineStart): Promise<EngineSession> {
    this.started = options;
    if (options.model) this.model = options.model;
    return { conversationID: options.resume ?? "conv-1", model: this.model };
  }

  async runTurn(text: string, _attachments: NodAttachment[], callbacks: TurnCallbacks): Promise<TurnResult> {
    this.turns.push(text);
    const script = this.scripts.shift() ?? (() => ({ lastMessage: "ok" }));
    const interrupted = new Promise<TurnResult>((resolve) => {
      this.abort = () => resolve({ lastMessage: "", interrupted: true });
    });
    const result = await Promise.race([Promise.resolve(script(callbacks, text, this)), interrupted]);
    this.abort = undefined;
    return result;
  }

  async interrupt(): Promise<void> {
    this.interrupted += 1;
    this.abort?.();
  }

  async setModel(model: string): Promise<void> {
    this.model = model;
  }

  async compact(callbacks: TurnCallbacks): Promise<TurnResult> {
    callbacks.compacted();
    return { lastMessage: "" };
  }

  async ask(prompt: string, model?: string): Promise<string> {
    this.asks.push({ prompt, model });
    const answer = this.answers.shift();
    if (!answer) throw new Error("no scripted answer");
    return answer(prompt);
  }

  async close(): Promise<void> {}
}

export function tick(ms = 0): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Polls until `predicate` holds, failing the test after `timeout` ms. */
export async function until(predicate: () => boolean, timeout = 2000): Promise<void> {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("timed out waiting");
    await tick(5);
  }
}
