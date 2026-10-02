import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";

/**
 * A client for graphcoded's socket — the same RPC the `graphcode` CLI and the remote shim
 * speak. graphcoded owns the graph, so reads come from its snapshot and writes go through
 * its permission and mailroom paths rather than around them.
 *
 * Frames are a 4-byte big-endian length then JSON, both ways. Commands use Swift's
 * synthesized enum coding: `{"caseName": {"label": value, "_0": unlabelled}}`.
 */
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type DaemonEvent = Record<string, Json>;

export function socketPath(env: Record<string, string | undefined> = process.env): string {
  if (env.GRAPHCODE_SOCKET) return expandHome(env.GRAPHCODE_SOCKET);
  const configured = env.GRAPHCODE_SUPPORT_DIR?.trim();
  const support = !configured
    ? join(homedir(), ".graphcode")
    : isAbsolute(expandHome(configured))
      ? expandHome(configured)
      : join(homedir(), configured);
  return join(support, "graphcoded.sock");
}

function expandHome(path: string): string {
  return path.startsWith("~/") ? join(homedir(), path.slice(2)) : path;
}

export function encodeFrame(value: Json): Buffer {
  const body = Buffer.from(JSON.stringify(value), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length, 0);
  return Buffer.concat([header, body]);
}

/** Splits a byte stream into frames, keeping a torn tail for the next chunk. */
export class FrameReader {
  private buffer = Buffer.alloc(0);

  push(chunk: Buffer): DaemonEvent[] {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    const frames: DaemonEvent[] = [];
    while (this.buffer.length >= 4) {
      const length = this.buffer.readUInt32BE(0);
      if (this.buffer.length < 4 + length) break;
      const body = this.buffer.subarray(4, 4 + length).toString("utf8");
      this.buffer = this.buffer.subarray(4 + length);
      frames.push(JSON.parse(body) as DaemonEvent);
    }
    return frames;
  }
}

export class DaemonError extends Error {}

/** One conversation with the daemon: send a command, wait for an event it answers with. */
export class DaemonConnection {
  private reader = new FrameReader();
  private queue: DaemonEvent[] = [];
  private waiters: Array<() => void> = [];
  private closed: Error | null = null;

  private constructor(private socket: Socket) {
    socket.on("data", (chunk: Buffer) => {
      this.queue.push(...this.reader.push(chunk));
      this.wake();
    });
    socket.on("error", (error) => this.close(error));
    socket.on("close", () => this.close(new DaemonError("graphcoded closed the connection")));
  }

  static open(path: string, timeoutMs: number): Promise<DaemonConnection> {
    return new Promise((resolve, reject) => {
      const socket = connect(path);
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new DaemonError(`graphcoded did not answer at ${path}`));
      }, timeoutMs);
      socket.once("connect", () => {
        clearTimeout(timer);
        resolve(new DaemonConnection(socket));
      });
      socket.once("error", (error) => {
        clearTimeout(timer);
        reject(new DaemonError(`graphcoded is not reachable at ${path}: ${error.message}`));
      });
    });
  }

  send(command: Json): void {
    this.socket.write(encodeFrame(command));
  }

  /** The first event carrying one of `keys`; unsolicited events in between are skipped. */
  async waitFor(keys: string[], timeoutMs: number): Promise<[string, Json]> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      while (this.queue.length > 0) {
        const event = this.queue.shift()!;
        const key = keys.find((k) => k in event);
        if (key) return [key, event[key]];
      }
      if (this.closed) throw this.closed;
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new DaemonError(`graphcoded sent no ${keys.join(" or ")}`);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, remaining);
        this.waiters.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }

  close(error: Error = new DaemonError("closed")): void {
    if (!this.closed) this.closed = error;
    this.socket.destroy();
    this.wake();
  }

  private wake(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const wake of waiters) wake();
  }
}

/** The calls the graphcode MCP server makes. A fresh connection per call, as the CLI does. */
export interface GraphDaemon {
  snapshot(projectPath: string): Promise<Json>;
  mailbox(projectPath: string, query: Json): Promise<Json>;
  graphCommand(projectPath: string, command: Json): Promise<void>;
}

export function daemonClient(path = socketPath(), timeoutMs = 10_000): GraphDaemon {
  async function withConnection<T>(body: (connection: DaemonConnection) => Promise<T>): Promise<T> {
    const connection = await DaemonConnection.open(path, timeoutMs);
    try {
      return await body(connection);
    } finally {
      connection.close();
    }
  }

  async function openProject(connection: DaemonConnection, projectPath: string): Promise<Json> {
    connection.send({ openProject: { path: projectPath } });
    const [key, value] = await connection.waitFor(["graphChanged", "errorOccurred"], timeoutMs);
    if (key === "errorOccurred") throw new DaemonError(unlabelled(value));
    return (value as { _0: Json })._0;
  }

  return {
    snapshot: (projectPath) => withConnection((connection) => openProject(connection, projectPath)),
    mailbox: (projectPath, query) =>
      withConnection(async (connection) => {
        connection.send({ mailbox: { projectPath, query } });
        const [key, value] = await connection.waitFor(["mailbox", "errorOccurred"], timeoutMs);
        if (key === "errorOccurred") throw new DaemonError(unlabelled(value));
        const wrapped = value as { mailbox?: Json; _0?: Json };
        return wrapped.mailbox ?? wrapped._0 ?? value;
      }),
    graphCommand: (projectPath, command) =>
      withConnection(async (connection) => {
        await openProject(connection, projectPath);
        connection.send({ graphCommand: { projectPath, command } });
        // The daemon judges delivery before it broadcasts, so the first answer is the verdict.
        const [key, value] = await connection.waitFor(["graphChanged", "errorOccurred"], timeoutMs);
        if (key === "errorOccurred") throw new DaemonError(unlabelled(value));
      }),
  };
}

function unlabelled(value: Json): string {
  const message = (value as { _0?: Json } | null)?._0;
  return typeof message === "string" ? message : JSON.stringify(value);
}
