// Drives a real graphcode-nod goal-loop session in a throwaway repo and support directory:
// accepts every hunk, allows every ask, steers once, and leaves events.jsonl to read.
//
//   bun scripts/smoke.ts claude|copilot [runtime-command]
//
// The runtime command defaults to this checkout's source; pass "/path/to/graphcode-nod" to
// smoke a packaged build. Claude needs an anthropic-api-key item in app.graphcode.nod.
// With NOD_PROJECT_PATH (and GRAPHCODE_SOCKET) set, Nod also calls the graphcode MCP
// server's siblings tool against that graph first.
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { connect } from "node:net";
import { join } from "node:path";

const engine = process.argv[2] === "copilot" ? "copilot" : "claude";
const runtime = process.argv[3] ?? `bun ${join(import.meta.dir, "..", "src", "main.ts")}`;
const root = `/tmp/nod-smoke-${engine}`;
const work = join(root, "work");
const support = join(root, "support");
const node = "11111111-2222-3333-4444-555555555555";
rmSync(root, { recursive: true, force: true });
mkdirSync(work, { recursive: true });
mkdirSync(support, { recursive: true });
Bun.spawnSync(["git", "init", "-q"], { cwd: work });
writeFileSync(join(support, "settings.json"), JSON.stringify({ nod: { engine, shellAllowlist: ["cat *"], editsInWorktree: "reviewHunks" } }));
const goalFile = join(root, "goal.txt");
writeFileSync(goalFile, "Done when hello.txt contains the line `hello nod` and `cat hello.txt` has printed it");

const graphStep = process.env.NOD_PROJECT_PATH
  ? "First call the graphcode server's siblings tool and say how many other loops it lists. "
  : "";
const state = join(support, "nod", node);
const child = Bun.spawn(
  [...runtime.split(" "), "--node", node, "--cwd", work, "--engine", engine, "--loop-type", "goal", "--goal-file", goalFile,
    "--prompt", graphStep + "Use your Write tool (not the shell) to create hello.txt containing the line `hello nod`. Then run `ls -la` and then `cat hello.txt`.",
    "--exit-when-idle"],
  { env: { ...process.env, GRAPHCODE_SUPPORT_DIR: support, NOD_STATE: state }, stdout: "inherit", stderr: "inherit" },
);
const socket = join(state, "control.sock");
while (!existsSync(socket)) await Bun.sleep(100);
const control = connect(socket);
let seen = 0;
let steered = false;
const poll = setInterval(() => {
  const log = join(state, "events.jsonl");
  if (!existsSync(log)) return;
  const lines = readFileSync(log, "utf8").trim().split("\n");
  for (const line of lines.slice(seen)) {
    const record = JSON.parse(line);
    if (record.type === "hunkStaged") control.write(JSON.stringify({ type: "resolveHunk", hunkID: record.hunkID, decision: "accept" }) + "\n");
    if (record.type === "permissionAsked") control.write(JSON.stringify({ type: "resolvePermission", askID: record.askID, decision: "allowOnce" }) + "\n");
    if (record.type === "toolCall" && !steered) {
      steered = true;
      control.write(JSON.stringify({ type: "send", text: "Also: keep your final answer to one short sentence.", delivery: "steer" }) + "\n");
    }
  }
  seen = lines.length;
}, 100);
const code = await child.exited;
clearInterval(poll);
control.end();
console.error(`\nexit ${code} · ${seen} records in ${join(state, "events.jsonl")}`);
process.exit(code);
