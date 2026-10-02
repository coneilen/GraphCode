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
              [--briefing <path>] [--resume <conversation-id>] [--prompt <text>]
graphcode-nod -p <prompt> [--model <id>]     # one-shot print mode (titles, summaries)
```

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
