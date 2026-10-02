# GraphCode Nod

GraphCode's own chat-native agent. The five other backends are CLIs in a terminal that
GraphCode types into and reads presence off. Nod is a harness GraphCode owns, running on
the **Claude Agent SDK** or the **GitHub Copilot SDK**. Its presence is exact, its goal is
a typed condition with its own evaluator, and it can see the graph it lives in.

The name is **GraphCode Nod** in setup, settings and commits, and **Nod** inside the app.
The engine is a setting, not a provider: both SDKs sit under one `.nod` backend, and
switching the engine only changes which models are offered and whose sign-in is used.

The design brief is `GraphCode design review.zip` (`nod_designs/GraphCode Nod.dc.html`).

## Architecture

```
 graphcode.app ──── chat pane (SwiftUI) ── reads events.jsonl, writes control.sock
      │
 graphcoded ─────── launches/ensures the session in zmx like any backend,
      │             reads presence labels, delivers .message edges as typed text
      ▼
 zmx session ────── graphcode-nod  (this package, TypeScript)
                      ├─ engine: Claude Agent SDK | Copilot SDK
                      ├─ staged edits, permission gate, goal evaluator
                      ├─ graphcode MCP server (siblings, edges, mailroom)
                      └─ a plain-text transcript on its PTY
```

Nod runs **inside a zmx session like every other backend**, so the daemon's lifecycle,
ensure/resume, restart, kill and `.message` delivery keep working unchanged. The PTY shows
a readable plain-text transcript, which keeps `zmx attach` and remote loops usable. The
app does not parse that text. It renders the chat pane from the event log.

| Channel | Direction | Format |
|---|---|---|
| `$NOD_STATE/events.jsonl` | runtime → app/daemon | One `NodEventRecord` per line, append-only, `seq` strictly increasing |
| `$NOD_STATE/control.sock` | app → runtime | Unix socket, one `NodCommand` JSON per line; the runtime replies `{"ok":true}` or `{"ok":false,"error":…}` per line |
| PTY stdin (`zmx send`) | daemon → runtime | A plain line is `send {delivery: queue}`, so `.message` edges and `graphcode node send` work unchanged |
| zmx labels | runtime → daemon | The same presence/activity/session-id labels Claude Code's hooks write (`PresenceHooks`), so the existing readers serve Nod |

`$NOD_STATE` is `<support-dir>/nod/<node-uuid>/` (`~/.graphcode/nod/<node-uuid>/` in the
default workspace), and graphcode always sets it. It also holds `conversation.json`
(engine, model, conversation id) for resume.

The wire types are `GraphcodeKit/Sources/Domain/NodProtocol.swift`. PROTOCOL.md is the
prose version. The two change together.

## Command line

```
graphcode-nod --node <uuid> --cwd <dir> [--engine claude|copilot] [--model <id>]
              [--loop-type main|goal|timed|turn|composite] [--goal-file <path>]
              [--briefing <path>] [--resume <conversation-id>] [--inherit <brief.json>]
              [--prompt <text>] [--unattended]
graphcode-nod -p <prompt> [--engine claude|copilot] [--model <id>]   # one-shot print mode
```

## The runtime (`src/`)

| Module | Does |
|---|---|
| `main.ts` | argv, print mode, PTY lines as queued sends, signals (Ctrl-C stops the turn, then quits) |
| `runtime.ts` | the turn queue, steer, stop, goal checks, spend cap, failures, presence |
| `engine.ts` | the one interface both engines implement; nothing above it branches on the engine |
| `claudeEngine.ts` · `copilotEngine.ts` | the Claude Agent SDK and GitHub Copilot SDK adapters |
| `eventLog.ts` · `controlSocket.ts` · `protocol.ts` | `events.jsonl`, `control.sock`, and the wire types mirroring `NodProtocol.swift` |
| `hunks.ts` · `diff.ts` | staged edits: Myers diff, git-style hunks, apply/reverse anywhere the context now sits |
| `permissions.ts` · `settings.ts` | the gate over `NodSettings` (read from `settings.json`'s `nod` key) and the shell allowlist |
| `goal.ts` | splits the goal into clauses and judges them every time the agent stops |
| `presence.ts` | the `presence`/`activity`/`usage` zmx labels and `sessions/<node>.id` that `PresenceHooks` writes |
| `credentials.ts` · `agentRuntimes.ts` | Keychain sign-ins, and where each engine's agent runtime is |
| `brief.ts` | `--inherit <brief.json>` (PROTOCOL.md, Inherited briefs) |

```sh
bun install && bun test        # unit tests run against fake engines; the contract test compiles NodProtocol.swift
bun ./node_modules/.bin/tsc --noEmit -p .
bun src/main.ts -p "hello"     # from source
```

**How the pieces behave**

- **Turns** run one at a time. `send {queue}` waits for the turn to end; `send {steer}` is
  delivered at the next tool boundary through the engine's PostToolUse `additionalContext`,
  and a steer that never meets a tool boundary runs next as a `steer` turn. `stop` interrupts
  the turn, rejects its pending hunks, denies its open asks and clears the queue.
- **Edits** are held until every hunk of the edit has a decision. All accepted, the agent's
  own tool writes the edit; some accepted, the runtime writes those to the file as it is now
  and the tool is refused with the reviewer's notes. In Auto mode hunks arrive accepted; a
  later reject or comment reverse-applies the hunk and tells the agent, until the turn ends.
  An edit the runtime can't diff (a notebook, an `old_string` not in the file) is refused in
  review mode rather than written unreviewed.
- **The gate** is authoritative: the Claude engine forces every Bash/edit/web/MCP call
  through `canUseTool` with a PreToolUse `ask`, so the human's own Claude Code allow rules
  can't bypass it; Copilot routes every shell/write/url/mcp request through one handler.
  Allowlisted commands run; compound commands must be allowlisted in every part, and
  command substitutions never are. A network command is asked about as `network`. Timed
  loops (and `--unattended` composite children) fail the run with `permissionUnavailable`
  instead of waiting. *Always allow* holds for the session; persisting it to the allowlist
  is the app's job when it sees `permissionResolved {alwaysAllow}`.
- **The goal** (`--goal-file`) is re-split into clauses on every stop and judged by the
  evaluator model (`goalEvaluatorModel`, default Haiku on Claude) from the agent's last
  message and recent tool results. Anything the judge doesn't clearly mark met counts as
  not met. Not met queues a `goalCheck` turn naming the unmet clauses; after 20 in a row
  without a human message Nod waits. `markGoalDone` records a met check. The runtime does
  not resolve the loop itself: the daemon reads `goalCheck {met: true}`.
- **Spend cap** (`spendCapUSD`) applies to unattended loops, per run (a run starts with a
  turn a human or timer started). Claude's cost is exact at each turn end and estimated
  mid-turn from tokens, scaled to the last exact figure, so the cap can stop mid-turn.
  Copilot reports premium requests, which its plan caps.
- **Context** is reported as `usage.contextUsed`; at 95% Nod compacts after the turn.
- **Resume**: `--resume <conversation-id>` continues the engine conversation and appends to
  the same `events.jsonl`, continuing its `seq`. `conversation.json` holds engine, model and
  conversation id.

## Sign-in

Keychain service `app.graphcode.nod` (`NodSettings.keychainService`), written by
Settings › Agents › Nod:

| Account | Used as |
|---|---|
| `anthropic-api-key` | the Claude engine's only credential, passed to Claude Code as `ANTHROPIC_API_KEY` |
| `github-token` | the Copilot SDK's `gitHubToken`; without it, the Copilot CLI's own GitHub login |

The Claude engine never uses a claude.ai login (policy, mailroom #1190). Claude Code runs
with every inherited credential variable stripped and `CLAUDE_CONFIG_DIR` set to
`~/.graphcode/nod/claude`, so it cannot find the human's login either. Without a key every
turn fails with `signInExpired`; a key the API rejects fails the turn within seconds instead
of sitting in Claude Code's retry backoff.

## Packaging

**Decision: one `bun build --compile` executable plus both engines' agent runtimes, in
`Contents/Helpers/nod/`. Nothing is installed on the Mac and nothing is found on PATH.**

`scripts/package.sh [out-dir] [bun-target]` writes:

| File | Size | From |
|---|---|---|
| `graphcode-nod` | ~64 MB | `bun build --compile` (no Node or Bun needed) |
| `claude` | ~228 MB | the Claude Code the Agent SDK bundles (keeps Anthropic's signature) |
| `copilot-runtime`, `runtime.node` | ~86 MB | the Copilot SDK's runtime |

With `SIGN_IDENTITY` set it signs `graphcode-nod` and the Copilot runtime with the hardened
runtime and `packaging/entitlements.plist` (a compiled Bun binary needs the JIT
entitlements). The app's panes run `<App>/Contents/Helpers/nod/graphcode-nod`; the app
copies the whole folder to `<support-dir>/bin/nod/` for graphcoded (PROTOCOL.md, Launch).
The runtime resolves its own real path before looking beside itself, so a symlinked copy
works too. It keeps its state in `$NOD_STATE` (set on every launch), falling back to
`<support-dir>/nod/<node>/`, and takes `$NOD_NODE_ID` when `--node` is absent.

A compiled binary cannot load the SDKs' platform packages (they resolve to the build
machine's `node_modules`), so `agentRuntimes.ts` looks for each agent runtime explicitly:

| Engine | Search order |
|---|---|
| Claude | `$GRAPHCODE_NOD_CLAUDE` (a deliberate override) → `claude` beside graphcode-nod → the SDK's own (source checkouts) |
| Copilot | `$GRAPHCODE_NOD_COPILOT` → `copilot-runtime` beside graphcode-nod → the SDK's own (source checkouts) → an installed `copilot` CLI |

## Capabilities

| Capability | Nod | Why |
|---|---|---|
| Hooks / presence | exact | GraphCode receives SDK events directly |
| Goal mode | native, `goalDirective` nil | the goal is a field with its own evaluator |
| Mid-session input | steer + queue | inject at the next tool boundary without interrupting |
| Sub-agents | yes | children are real loops on the canvas |
| MCP · structured out | yes · yes | shares the project's MCP config with the CLIs |
| Recurrence | daemon | timed loops re-enter the same conversation |
| Graph access | new | read-only tools for siblings, edges, handoffs, the mailroom |

`CLISessionBackendKind.nod.isSpiked` stays false, so Nod hosts no loop type, until
`graphcode-nod` launches from the app bundle.

## Work streams

| Stream | Owns |
|---|---|
| Runtime | this package: engines, event log, control socket, staged hunks, permissions, goal evaluator, print mode, packaging into the app bundle |
| Launch | `BackendCommand`/`ZmxSessionLauncher` argv, presence, resume, `isSpiked` flip, daemon recurrence |
| Chat pane | transcript, work cards, composer, steer/queue, failure banners |
| Graph layer | context strip, inline mail, handoff offers, plan mode → Composite, forks, graphcode MCP server |
| Setup & settings | engine choice, Claude sign-in reuse, Copilot device flow, Keychain, Settings › Agents › Nod, the Chat/Terminal agent menu, canvas cards |

## Open questions from the design review

- Switching the engine mid-loop
- Confirming the goal's split into checkable clauses at creation
- How CLI siblings message Nod (today: typed text through `zmx send`, read as a queued message)
