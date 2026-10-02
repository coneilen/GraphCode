import type { NodEventRecord } from "./protocol";

/**
 * The plain-text transcript on the PTY, for `zmx attach` and remote loops. The app never
 * parses it; it renders from the event log.
 */
export class Transcript {
  private midLine = false;

  constructor(private readonly write: (text: string) => void) {}

  render(record: NodEventRecord): void {
    switch (record.type) {
      case "sessionStarted":
        this.line(`● Nod · ${record.model} via ${record.engine === "claude" ? "Claude Agent SDK" : "GitHub Copilot SDK"}${record.resumed ? " · resumed" : ""}`);
        return;
      case "userMessage":
        this.line(`${record.delivery === "steer" ? "↳ steer" : "›"} ${record.text}`);
        return;
      case "assistantText":
        if (record.delta) {
          this.write(record.delta);
          this.midLine = !record.delta.endsWith("\n");
        }
        if (record.final) this.endLine();
        return;
      case "toolCall":
        this.line(`  ▸ ${record.title}`);
        return;
      case "toolResult":
        if (record.status !== "running") this.line(`    ${record.status === "ok" ? "✓" : "✗"} ${record.summary}${record.durationMs ? ` · ${seconds(record.durationMs)}` : ""}`);
        return;
      case "hunkStaged":
        this.line(`  ± ${record.file} +${record.added} −${record.removed}${record.autoAccepted ? " · accepted" : " · awaiting review"}`);
        return;
      case "hunkResolved":
        this.line(`    hunk ${record.hunkID} ${record.decision}${record.note ? `: ${record.note}` : ""}`);
        return;
      case "permissionAsked":
        this.line(`  ? Nod asks to ${record.kind === "shell" ? "run" : "use"} ${record.subject} — ${record.reason} Answer in the chat pane.`);
        return;
      case "permissionResolved":
        this.line(`    ${record.decision === "deny" ? "denied" : "allowed"}`);
        return;
      case "goalCheck":
        this.line(`  ◎ Goal check · ${record.met ? "holds" : "not yet"} · ${record.clauses.filter((c) => c.met).length}/${record.clauses.length}`);
        return;
      case "turnEnded":
        if (record.filesChanged > 0) this.line(`  ${record.filesChanged} file${record.filesChanged === 1 ? "" : "s"} · +${record.added} −${record.removed}`);
        return;
      case "compacted":
        this.line(`  ── compacted turns ${record.fromTurn}–${record.throughTurn} ──`);
        return;
      case "failure":
        this.line(`  ! ${record.message}`);
        return;
    }
  }

  private line(text: string): void {
    this.endLine();
    this.write(text + "\n");
  }

  private endLine(): void {
    if (this.midLine) this.write("\n");
    this.midLine = false;
  }
}

function seconds(ms: number): string {
  return ms < 1000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.round(ms / 1000)}s`;
}
