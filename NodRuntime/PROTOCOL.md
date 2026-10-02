# Nod protocol, version 1

Source of truth: `GraphcodeKit/Sources/Domain/NodProtocol.swift`. Change both together.

Each event and command is one JSON object on one line. A `type` field names it, and the
payload's fields sit beside `type` rather than nested. Dates are ISO-8601 UTC. Unknown
fields are ignored. Unknown event types decode as `unknown` and are skipped by readers, so
adding an event never breaks an older app. Bump `v` only for a change an old reader would
misread.

## Launch

graphcode starts `graphcode-nod` inside the node's zmx session:

```
graphcode-nod --node <uuid> [--cwd <dir>] --engine claude|copilot --loop-type main|goal|timed|turn|composite
              [--model <id>] [--goal-file <path>] [--inherit <path>] [--unattended]
              [--briefing <path>] [--prompt <text>] [--resume <conversation-id>]
```

- `NOD_STATE` (`NodProtocol.stateDirectoryVariable`) is always set, to
  `<support-dir>/nod/<node-uuid>`. Use it rather than computing `~/.graphcode/...`: a
  workspace can move its support directory. Create it if missing.
- `NOD_NODE_ID` is always set, and `NOD_PROJECT_PATH` is set for a node in a project, for
  the graphcode MCP server, which asks `graphcoded`'s socket about siblings and edges.
- `--unattended` marks a loop nobody watches: timed loops, and composite children. A
  permission it would have to ask about fails the run (`permissionUnavailable`).
- `--inherit <path>` hands a fresh composite child or fork the brief it starts from. It is
  never passed on `--resume`.
- `--goal-file` is `$NOD_STATE/goal.md`, the goal's condition as plain text, rewritten on
  every launch.
- `--resume` is the `conversationID` of an earlier `sessionStarted`. graphcode banks it
  from the event log while the session is live, so a reboot or restart resumes.
- The binary is `Contents/Helpers/nod/graphcode-nod` in the app bundle for the app's own
  panes. `graphcoded` runs `<support-dir>/bin/nod/graphcode-nod`: the app copies the whole
  `Helpers/nod` directory there when it installs its helpers. `GRAPHCODE_NOD_PATH`
  overrides both for development.
- A plain line on the PTY is a queued `send`. graphcode falls back to typing when
  `control.sock` is not there yet, so read stdin from the first moment.

## Events — `events.jsonl`

Every line carries `v`, `seq` (strictly increasing from 1) and `at`.

| type | fields | notes |
|---|---|---|
| `sessionStarted` | `engine` (`claude`/`copilot`), `model`, `conversationID`, `resumed` | first line of every run |
| `turnStarted` | `turn`, `origin` (`user` `queue` `steer` `handoff` `mail` `timer` `goalCheck`) | |
| `userMessage` | `id`, `text`, `delivery` (`queue`/`steer`), `attachments[]`, `fromNodeID?` | echoed when the runtime accepts it |
| `assistantText` | `turn`, `messageID`, `delta`, `final` | deltas with one `messageID` concatenate |
| `toolCall` | `turn`, `callID`, `tool`, `title` | `title` is the card's one line |
| `toolResult` | `callID`, `status` (`running` `ok` `error`), `summary`, `output?`, `durationMs?` | |
| `hunkStaged` | `turn`, `hunkID`, `file`, `header`, `diff`, `added`, `removed`, `autoAccepted` | written to disk only on accept |
| `hunkResolved` | `hunkID`, `decision` (`accept` `reject` `comment`), `note?` | |
| `permissionAsked` | `askID`, `kind` (`shell` `network` `editOutsideWorktree` `messageLoop` `mcpTool`), `subject`, `reason`, `answerableFromCard` | the loop is in Needs you until resolved, or until the next `sessionStarted` |
| `permissionResolved` | `askID`, `decision` (`allowOnce` `alwaysAllow` `deny`) | |
| `goalCheck` | `turn`, `evaluatorModel`, `clauses[{text, met, evidence?}]`, `met` | run each time Nod tries to stop |
| `turnEnded` | `turn`, `filesChanged`, `added`, `removed`, `summary?` | |
| `usage` | `inputTokens`, `outputTokens`, `costUSD?`, `premiumRequests?`, `contextUsed` (0…1) | running totals for the run, so the newest one is the answer |
| `planProposed` | `planID`, `title`, `steps[{id, text, files[], size?, editedByHuman, doneCheck}]` | `files` are repository-relative, so Run as Composite can group steps by area; `doneCheck` (absent = false) marks the step that verifies the others |
| `mailDraft` | `draftID`, `toNodeID`, `inReplyTo?`, `text` | sent only on `sendDraft` |
| `compacted` | `fromTurn`, `throughTurn` | |
| `activity` | `line` | the canvas card's live line |
| `failure` | `kind` (`signInExpired` `contextFull` `spendCap` `permissionUnavailable` `engineError`), `message` | shown as a banner above the composer; every kind but `contextFull` puts the loop in Needs you until the next `turnStarted` |

## Commands — `control.sock`

| type | fields |
|---|---|
| `send` | `text`, `delivery` (`queue`/`steer`), `attachments[]` |
| `stop` | |
| `resolveHunk` | `hunkID`, `decision`, `note?` |
| `resolvePermission` | `askID`, `decision` |
| `runPlan` | `planID`, `steps[]`, `mode` (`here`/`composite`) |
| `fork` | `messageID` |
| `sendDraft` | `draftID`, `text` |
| `compact` | |
| `setModel` | `model` |
| `markGoalDone` | |

The runtime answers each command line with `{"ok":true}` or `{"ok":false,"error":"…"}`.

## Inherited briefs — `--inherit <path>`

A composite child made from a plan, and a fork, start from another loop's conversation. The
app writes a `NodBrief` to `<support-dir>/nod/briefs/<uuid>.json` before creating the loop
and records the path in `LoopNode.lineage.briefPath`. The launcher passes
`--inherit <path>` on a fresh start only, never with `--resume`. The runtime sends the
brief as turn 1 with origin `handoff`.

| field | notes |
|---|---|
| `v` | protocol version |
| `kind` | `compositeChild` or `fork` |
| `fromNodeID` | the loop it came from |
| `text` | the brief itself |
| `attachments[]` | `NodAttachment`s, usually the source's `loopTranscript` |
| `fork?` | `{conversationID?, messageID}`: resume the source's engine conversation forked after `messageID` (Claude Agent SDK `resume` + `forkSession`), instead of summarising it |

## The graphcode MCP server

`src/mcp/` is the built-in server Nod always mounts (`serverName` = `graphcode`).
`createGraphcodeTools(ctx)` returns engine-neutral tool definitions for the runtime to
adapt. It reads and writes through graphcoded's socket (`$GRAPHCODE_SOCKET`, else
`$GRAPHCODE_SUPPORT_DIR/graphcoded.sock`), the same RPC the CLI speaks. It never reads
graph files. `ctx.projectPath` comes from `$NOD_PROJECT_PATH`.

| tool | does |
|---|---|
| `siblings` | other loops at this loop's level: type, state, brief, live line, relation (`from` `to` `beside` `none`) |
| `edges` | edges touching this loop, or all of them |
| `handoff_briefs` | upstream sources: what each was handed, its result, what the edge carries |
| `mailroom`, `mailroom_read` | the board, read-only; the read cursor never moves |
| `ask` | message a loop, optionally `inReplyTo` a message id |
| `handoff` | send `Handoff: <brief>` downstream, or to a named loop |

`ask` and `handoff` follow `NodSettings.messagesOtherLoops`, read on every call.
`draftForMe` emits `mailDraft` and sends nothing. `send` sends `messageNode` as this loop.
`never` refuses.
The runtime keeps each draft's addressee and answers `sendDraft` with `sendDraft(ctx, {toNodeID, text})`, the text as the human edited it.
Without `$NOD_PROJECT_PATH` the server stays mounted and its tools say the graph is out of reach.

### Mounting

| | Claude engine | Copilot engine |
|---|---|---|
| graphcode | in-process SDK MCP server `graphcode` (`mcp__graphcode__<tool>`) | custom tools `graphcode_<tool>` |
| `.mcp.json` | `mcpServers`, with `strictMcpConfig: true` | `mcpServers` (config discovery stays off) |
| gate | PreToolUse forces every `mcp__` call to `canUseTool` | `mcp` and `custom-tool` permission requests |

`.mcp.json` is read walking up from the loop's working directory, the nearer file winning a
name, with `${VAR}` and `${VAR:-default}` expanded. Names in `NodSettings.disabledMCPServers`
are skipped, and an entry called `graphcode` is ignored. A project server's tool asks as
`mcpTool` with subject `<server>/<tool>`.

`classifyInbound(line, graph, nodeID)` maps a typed `[graphcode] <Sender>: …` line to the
sending loop, so a drafted reply goes to the right place.

## Example

```json
{"v":1,"seq":1,"at":"2026-10-01T20:00:00Z","type":"sessionStarted","engine":"claude","model":"sonnet","conversationID":"8c1…","resumed":false}
{"v":1,"seq":2,"at":"2026-10-01T20:00:01Z","type":"turnStarted","turn":1,"origin":"user"}
{"v":1,"seq":3,"at":"2026-10-01T20:00:04Z","type":"toolCall","turn":1,"callID":"c1","tool":"Grep","title":"Search \"UsageGate\""}
{"v":1,"seq":4,"at":"2026-10-01T20:00:04Z","type":"toolResult","callID":"c1","status":"ok","summary":"6 hits in 4 files","durationMs":400}
```
