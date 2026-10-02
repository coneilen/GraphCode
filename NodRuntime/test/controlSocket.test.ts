import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ControlSocket } from "../src/controlSocket";
import type { NodCommand } from "../src/protocol";

const open: ControlSocket[] = [];
afterEach(async () => {
  for (const socket of open.splice(0)) await socket.close();
});

async function serve(handle: (command: NodCommand) => Promise<void> | void): Promise<ControlSocket> {
  // Short path: a unix socket path is capped at 104 bytes on macOS.
  const path = join(mkdtempSync(join("/tmp", "nod-")), "control.sock");
  const socket = new ControlSocket(path, handle);
  await socket.listen();
  open.push(socket);
  return socket;
}

function client(path: string): Promise<{ socket: Socket; replies: () => Promise<string[]>; next: (n: number) => Promise<string[]> }> {
  return new Promise((resolve, reject) => {
    const socket = connect(path);
    let buffer = "";
    const received: string[] = [];
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      let i: number;
      while ((i = buffer.indexOf("\n")) >= 0) {
        received.push(buffer.slice(0, i));
        buffer = buffer.slice(i + 1);
      }
    });
    socket.on("error", reject);
    socket.on("connect", () =>
      resolve({
        socket,
        replies: async () => received,
        next: async (n: number) => {
          const deadline = Date.now() + 2000;
          while (received.length < n) {
            if (Date.now() > deadline) throw new Error(`only ${received.length} replies`);
            await new Promise((r) => setTimeout(r, 5));
          }
          return received.slice(0, n);
        },
      }),
    );
  });
}

describe("ControlSocket", () => {
  test("answers each command line with ok, in order, even when handlers finish out of order", async () => {
    const handled: string[] = [];
    const server = await serve(async (command) => {
      if (command.type === "send") await new Promise((r) => setTimeout(r, 30));
      handled.push(command.type);
    });
    const { socket, next } = await client(server.path);
    socket.write('{"type":"send","text":"slow"}\n{"type":"stop"}\n');
    expect(await next(2)).toEqual(['{"ok":true}', '{"ok":true}']);
    expect(handled).toEqual(["send", "stop"]);
    socket.end();
  });

  test("reports a malformed line or a handler error as ok:false and keeps the connection", async () => {
    const server = await serve((command) => {
      if (command.type === "fork") throw new Error("fork is not supported by this runtime yet");
    });
    const { socket, next } = await client(server.path);
    socket.write('nonsense\n{"type":"fork","messageID":"m1"}\n{"type":"compact"}\n');
    const replies = (await next(3)).map((line) => JSON.parse(line));
    expect(replies[0]).toEqual({ ok: false, error: "not JSON" });
    expect(replies[1]).toEqual({ ok: false, error: "fork is not supported by this runtime yet" });
    expect(replies[2]).toEqual({ ok: true });
    socket.end();
  });

  test("reassembles a command split across writes and ignores blank lines", async () => {
    const seen: NodCommand[] = [];
    const server = await serve((command) => void seen.push(command));
    const { socket, next } = await client(server.path);
    socket.write('{"type":"setMo');
    await new Promise((r) => setTimeout(r, 20));
    socket.write('del","model":"opus"}\n\n');
    expect(await next(1)).toEqual(['{"ok":true}']);
    expect(seen).toEqual([{ type: "setModel", model: "opus" }]);
    socket.end();
  });

  test("serves several clients at once", async () => {
    let count = 0;
    const server = await serve(() => void (count += 1));
    const a = await client(server.path);
    const b = await client(server.path);
    a.socket.write('{"type":"stop"}\n');
    b.socket.write('{"type":"stop"}\n');
    await a.next(1);
    await b.next(1);
    expect(count).toBe(2);
    a.socket.end();
    b.socket.end();
  });

  test("replaces a stale socket file left by a killed runtime, and removes its own on close", async () => {
    const path = join(mkdtempSync(join("/tmp", "nod-")), "control.sock");
    writeFileSync(path, "");
    const server = new ControlSocket(path, () => {});
    await server.listen();
    const { socket, next } = await client(path);
    socket.write('{"type":"stop"}\n');
    expect(await next(1)).toEqual(['{"ok":true}']);
    socket.end();
    await server.close();
    expect(await Bun.file(path).exists()).toBe(false);
  });
});
