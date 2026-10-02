import { createServer, type Server, type Socket } from "node:net";
import { existsSync, mkdirSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";
import { parseCommand, type NodCommand } from "./protocol";

export type CommandHandler = (command: NodCommand) => Promise<void> | void;

/**
 * `control.sock`: one `NodCommand` per line in, one `{"ok":…}` per line out, in order.
 * Commands on one connection are handled one at a time so their replies line up with
 * the lines that asked for them.
 */
export class ControlSocket {
  private server: Server | undefined;
  private sockets = new Set<Socket>();

  constructor(
    readonly path: string,
    private readonly handle: CommandHandler,
  ) {}

  async listen(): Promise<void> {
    mkdirSync(dirname(this.path), { recursive: true });
    // A socket file left by a killed runtime refuses every connect; a live runtime for the
    // same node is the launcher's job to prevent, not this one's.
    if (existsSync(this.path)) unlinkSync(this.path);
    const server = createServer((socket) => this.accept(socket));
    this.server = server;
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(this.path, () => {
        server.off("error", reject);
        resolve();
      });
    });
  }

  async close(): Promise<void> {
    for (const socket of this.sockets) socket.destroy();
    const server = this.server;
    this.server = undefined;
    if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
    if (existsSync(this.path)) unlinkSync(this.path);
  }

  private accept(socket: Socket): void {
    this.sockets.add(socket);
    socket.setEncoding("utf8");
    let buffered = "";
    let chain = Promise.resolve();
    socket.on("data", (chunk: string) => {
      buffered += chunk;
      let newline: number;
      while ((newline = buffered.indexOf("\n")) >= 0) {
        const line = buffered.slice(0, newline).trim();
        buffered = buffered.slice(newline + 1);
        if (line.length === 0) continue;
        chain = chain.then(() => this.reply(socket, line));
      }
    });
    socket.on("error", () => socket.destroy());
    socket.on("close", () => this.sockets.delete(socket));
  }

  private async reply(socket: Socket, line: string): Promise<void> {
    let answer: { ok: true } | { ok: false; error: string };
    try {
      await this.handle(parseCommand(line));
      answer = { ok: true };
    } catch (error) {
      answer = { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
    if (!socket.destroyed) socket.write(JSON.stringify(answer) + "\n");
  }
}
