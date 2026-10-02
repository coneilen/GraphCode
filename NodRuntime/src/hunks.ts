import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, relative } from "node:path";
import { applyHunk, hunkHeader, hunks, hunkStats, type Hunk } from "./diff";
import type { EventLog } from "./eventLog";
import { realPath } from "./permissions";
import type { NodHunkDecision } from "./protocol";

export interface StagedHunk {
  id: string;
  file: string;
  hunk: Hunk;
  turn: number;
  autoAccepted: boolean;
  state: "pending" | "accepted" | "rejected" | "commented";
  note?: string;
}

export interface EditOutcome {
  /**
   * Every hunk accepted: nothing has been written, and the agent's own tool should now run
   * and write the edit exactly as asked. Otherwise the accepted hunks are already on disk
   * and the tool must not run.
   */
  allAccepted: boolean;
  hunks: StagedHunk[];
  /** What to tell the agent about the parts that did not land. */
  feedback: string;
}

/**
 * Edits are staged, not written. A hunk lands in the worktree only when it is accepted —
 * or, in Auto mode, it lands at once and a later reject reverse-applies it, so an
 * auto-accepted hunk stays reviewable until the turn ends.
 *
 * The edit is held until every hunk has a decision. All accepted, the agent's tool writes
 * it; only some, the stager writes those and the tool is refused with the reviewer's notes
 * — the stager never writes an edit the tool is about to write again.
 */
export class HunkStager {
  private staged = new Map<string, StagedHunk>();
  private waiters = new Map<string, () => void>();
  private nextID = 1;

  private readonly worktree: string;

  constructor(
    private readonly log: EventLog,
    worktree: string,
  ) {
    // Engines report real paths; relative names are only right against the real worktree.
    this.worktree = realPath(worktree);
  }

  /** Called when an auto-accepted hunk is rejected or sent back after it landed. */
  onLateDecision?: (hunk: StagedHunk) => void;

  /**
   * Stages the change from the file's current content to `after`, and resolves once every
   * hunk has a decision — at once in auto mode.
   */
  async stageEdit(file: string, after: string, turn: number, auto: boolean): Promise<EditOutcome> {
    const before = readOr(file);
    const staged = hunks(before, after).map((hunk) => this.stage(file, hunk, turn, auto));
    if (auto) return { allAccepted: true, hunks: staged, feedback: "" };
    await Promise.all(staged.map((h) => this.decided(h.id)));
    const result = outcome(staged, this.worktree);
    if (!result.allAccepted) {
      // Applied to the file as it is now, so a human's edit made meanwhile survives.
      const current = readOr(file);
      let text = current;
      for (const h of staged.filter((h) => h.state === "accepted")) text = applyHunk(text, h.hunk);
      if (text !== current) writeFile(file, text);
    }
    return result;
  }

  pending(): StagedHunk[] {
    return [...this.staged.values()].filter((h) => h.state === "pending");
  }

  get(id: string): StagedHunk | undefined {
    return this.staged.get(id);
  }

  /** Accepted lines this turn, for `turnEnded`. */
  tally(turn: number): { filesChanged: number; added: number; removed: number } {
    const landed = [...this.staged.values()].filter((h) => h.turn === turn && h.state === "accepted");
    const files = new Set(landed.map((h) => h.file));
    let added = 0;
    let removed = 0;
    for (const h of landed) {
      const stats = hunkStats(h.hunk);
      added += stats.added;
      removed += stats.removed;
    }
    return { filesChanged: files.size, added, removed };
  }

  /** Auto-accepted hunks stop being reviewable once their turn has ended. */
  closeTurn(turn: number): void {
    for (const [id, h] of this.staged) {
      if (h.turn === turn && h.state !== "pending") this.staged.delete(id);
    }
  }

  /** A stopped turn can't wait for review: its pending hunks are dropped, not written. */
  rejectPending(note: string): void {
    for (const h of this.pending()) this.resolve(h.id, "reject", note);
  }

  resolve(id: string, decision: NodHunkDecision, note?: string): void {
    const h = this.staged.get(id);
    if (!h) throw new Error(`no hunk ${id}`);
    const late = h.state === "accepted" && h.autoAccepted;
    if (h.state === "pending") {
      h.state = decision === "accept" ? "accepted" : decision === "reject" ? "rejected" : "commented";
    } else if (late && decision !== "accept") {
      writeFile(h.file, applyHunk(readOr(h.file), h.hunk, true));
      h.state = decision === "reject" ? "rejected" : "commented";
    } else {
      throw new Error(`hunk ${id} is already ${h.state}`);
    }
    h.note = note;
    this.log.append({ type: "hunkResolved", hunkID: id, decision, note });
    this.waiters.get(id)?.();
    this.waiters.delete(id);
    if (late) this.onLateDecision?.(h);
  }

  private stage(file: string, hunk: Hunk, turn: number, auto: boolean): StagedHunk {
    const staged: StagedHunk = {
      id: `h${this.nextID++}`,
      file,
      hunk,
      turn,
      autoAccepted: auto,
      state: auto ? "accepted" : "pending",
    };
    this.staged.set(staged.id, staged);
    const stats = hunkStats(hunk);
    this.log.append({
      type: "hunkStaged",
      turn,
      hunkID: staged.id,
      file: relative(this.worktree, realPath(file)),
      header: hunkHeader(hunk),
      diff: [hunkHeader(hunk), ...hunk.lines].join("\n"),
      added: stats.added,
      removed: stats.removed,
      autoAccepted: auto,
    });
    return staged;
  }

  private decided(id: string): Promise<void> {
    if (this.staged.get(id)?.state !== "pending") return Promise.resolve();
    return new Promise((resolve) => this.waiters.set(id, resolve));
  }
}

function outcome(staged: StagedHunk[], worktree: string): EditOutcome {
  const allAccepted = staged.every((h) => h.state === "accepted");
  const notes = staged
    .filter((h) => h.state !== "accepted")
    .map((h) => {
      const where = `${relative(worktree, realPath(h.file))} ${hunkHeader(h.hunk)}`;
      const verb = h.state === "rejected" ? "was rejected" : "was sent back";
      return `- ${where} ${verb}${h.note ? `: ${h.note}` : ""}`;
    });
  const accepted = staged.filter((h) => h.state === "accepted").length;
  const feedback = allAccepted
    ? ""
    : `The reviewer accepted ${accepted} of ${staged.length} hunks of this edit; accepted hunks are on disk, the rest are not.\n` +
      notes.join("\n");
  return { allAccepted, hunks: staged, feedback };
}

function readOr(file: string): string {
  return existsSync(file) ? readFileSync(file, "utf8") : "";
}

function writeFile(file: string, text: string): void {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, text);
}
