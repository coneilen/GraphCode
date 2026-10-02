import { spawn } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { supportDirectory } from "./settings";

export type Presence = "busy" | "awaitingInput" | "idle" | "absent";

/**
 * Encodes a phrase for a `zmx` label value, which takes only `[A-Za-z0-9._-]`: exactly what
 * PresenceHooks' activity script does, so `ZmxSessionLauncher.decodedActivity` reads it back.
 * Literal `_` becomes `_5F`, every other disallowed byte a space, and spaces `_20`.
 */
export function encodeActivity(phrase: string): string {
  return phrase
    .slice(0, 64)
    .replace(/_/g, "_5F")
    .replace(/[^A-Za-z0-9._-]/g, " ")
    .replace(/ +/g, " ")
    .trim()
    .replace(/ /g, "_20");
}

export type LabelRunner = (args: string[]) => Promise<void>;

/**
 * Writes the labels Claude Code's hooks write (`presence`, `activity`, `usage`) and the
 * `sessions/<node>.id` pointer plus `.history` line `captureSessionID` writes, so the
 * daemon's existing readers serve Nod unchanged. Outside a zmx session it does nothing,
 * like the hooks' `$ZMX_SESSION` guard.
 */
export class PresenceReporter {
  private chain: Promise<void> = Promise.resolve();
  private last = "";

  constructor(
    private readonly session: string | undefined,
    private readonly run: LabelRunner = zmxRunner(),
    private readonly support = supportDirectory(),
  ) {}

  get enabled(): boolean {
    return Boolean(this.session);
  }

  presence(presence: Presence, activity?: string): Promise<void> {
    // Every report but a tool call's clears the activity: the last thing a session was
    // doing is stale the moment it answers, stops or waits.
    const labels = [`presence=${presence}`, `activity=${activity ? encodeActivity(activity) : ""}`];
    return this.set(labels);
  }

  usage(inputTokens: number, outputTokens: number): Promise<void> {
    return this.set([`usage=input.${Math.round(inputTokens)}_output.${Math.round(outputTokens)}`]);
  }

  sessionID(nodeID: string, conversationID: string, cwd: string): void {
    if (!this.session) return;
    const directory = join(this.support, "sessions");
    mkdirSync(directory, { recursive: true });
    const epoch = Math.floor(Date.now() / 1000);
    appendFileSync(join(directory, `${nodeID}.history`), `${epoch} ${conversationID} ${cwd}\n`);
    writeFileSync(join(directory, `${nodeID}.id`), conversationID);
  }

  /** Writes are serialised, so labels land in the order they were reported. */
  private set(labels: string[]): Promise<void> {
    if (!this.session) return Promise.resolve();
    const key = labels.join(" ");
    if (key === this.last) return this.chain;
    this.last = key;
    const session = this.session;
    this.chain = this.chain.then(() => this.run(["set", session, ...labels]).catch(() => {}));
    return this.chain;
  }

  flush(): Promise<void> {
    return this.chain;
  }
}

export function zmxPath(support = supportDirectory()): string {
  const bundled = join(support, "bin", "zmx");
  return existsSync(bundled) ? bundled : "zmx";
}

function zmxRunner(path = zmxPath()): LabelRunner {
  return (args) =>
    new Promise((resolve) => {
      const child = spawn(path, args, { stdio: "ignore" });
      const timer = setTimeout(() => child.kill("SIGKILL"), 5000);
      child.on("error", () => {
        clearTimeout(timer);
        resolve();
      });
      child.on("exit", () => {
        clearTimeout(timer);
        resolve();
      });
    });
}
