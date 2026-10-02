import type { EventLog } from "./eventLog";
import type { NodGoalClause } from "./protocol";

/** Asks a model one question and returns its text answer; engines provide it. */
export type Judge = (prompt: string, model: string) => Promise<string>;

/**
 * Splits a goal into checkable clauses: list items, then `;`, then a top-level "and".
 * "and" inside backticks, quotes or brackets never splits, and a single word that can't be a
 * claim of its own ("resetsAt") is joined back onto the one before it.
 */
export function splitGoal(goal: string): string[] {
  const body = goal.trim().replace(/^(?:done when\s*:?|goal\s*:|the goal is(?: that)?\b)\s*/i, "");
  const items = body
    .split(/\n+/)
    .map((line) => line.replace(/^\s*(?:[-*•]|\d+[.)])\s+/, "").trim())
    .filter(Boolean);
  const clauses: string[] = [];
  for (const item of items) {
    splitTopLevel(item).forEach((piece, i) => {
      const text = piece.trim().replace(/[.,]$/, "").trim();
      if (!text) return;
      const previous = clauses[clauses.length - 1];
      if (i > 0 && previous !== undefined && text.split(/\s+/).length < 2) {
        clauses[clauses.length - 1] = `${previous} and ${text}`;
      } else {
        clauses.push(text);
      }
    });
  }
  return clauses.length > 0 ? clauses : [body.trim()];
}

function splitTopLevel(text: string): string[] {
  const pieces: string[] = [];
  let depth = 0;
  let quote: string | null = null;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (quote) {
      if (c === quote) quote = null;
      continue;
    }
    if (c === "`" || c === '"') quote = c;
    else if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth = Math.max(0, depth - 1);
    else if (depth === 0) {
      if (c === ";") {
        pieces.push(text.slice(start, i));
        start = i + 1;
      } else {
        const rest = text.slice(i);
        const match = /^,?\s+and\s+/i.exec(rest);
        if (match && (c === " " || c === ",")) {
          pieces.push(text.slice(start, i));
          start = i + match[0].length;
          i = start - 1;
        }
      }
    }
  }
  pieces.push(text.slice(start));
  return pieces;
}

export interface GoalEvidence {
  /** The agent's last words before trying to stop. */
  lastMessage: string;
  /** Recent tool calls with their outcomes, newest last. */
  toolResults: string[];
}

export interface GoalVerdict {
  met: boolean;
  clauses: NodGoalClause[];
}

export function evaluatorPrompt(clauses: string[], evidence: GoalEvidence): string {
  return [
    "You are the goal evaluator for a coding agent. The agent is trying to stop.",
    "Decide, for each numbered clause of its goal, whether the evidence below shows it is met.",
    "Be strict: a clause is met only if the evidence demonstrates it, not if the agent merely claims it.",
    "",
    "Clauses:",
    ...clauses.map((clause, i) => `${i}. ${clause}`),
    "",
    "Recent tool activity:",
    ...(evidence.toolResults.length > 0 ? evidence.toolResults.map((r) => `- ${r}`) : ["(none)"]),
    "",
    "The agent's last message:",
    evidence.lastMessage || "(empty)",
    "",
    'Answer with JSON only: {"clauses":[{"index":0,"met":true,"evidence":"one short line"}]}',
  ].join("\n");
}

/** Reads the judge's answer; anything unreadable counts as not met, never as met. */
export function parseVerdict(answer: string, clauses: string[]): GoalVerdict {
  const byIndex = new Map<number, { met: boolean; evidence?: string }>();
  const json = /\{[\s\S]*\}/.exec(answer)?.[0];
  if (json) {
    try {
      const parsed = JSON.parse(json) as { clauses?: unknown };
      if (Array.isArray(parsed.clauses)) {
        for (const entry of parsed.clauses as Record<string, unknown>[]) {
          if (typeof entry?.index === "number") {
            byIndex.set(entry.index, {
              met: entry.met === true,
              evidence: typeof entry.evidence === "string" ? entry.evidence : undefined,
            });
          }
        }
      }
    } catch {
      // unreadable: every clause stays unmet
    }
  }
  const result = clauses.map((text, i) => {
    const judged = byIndex.get(i);
    return { text, met: judged?.met ?? false, evidence: judged ? judged.evidence : "the evaluator gave no verdict" };
  });
  return { met: result.every((c) => c.met), clauses: result };
}

/**
 * The native goal: checked every time the agent tries to stop. Not met means the agent is
 * sent back to work with the unmet clauses; met (or marked done by a human) ends the loop.
 */
export class GoalEvaluator {
  private markedDone = false;

  constructor(
    public goal: string,
    private readonly judge: Judge,
    readonly model: string,
    private readonly log: EventLog,
  ) {}

  markDone(): void {
    this.markedDone = true;
  }

  get isMarkedDone(): boolean {
    return this.markedDone;
  }

  async check(turn: number, evidence: GoalEvidence): Promise<GoalVerdict> {
    const clauses = splitGoal(this.goal);
    let verdict: GoalVerdict;
    if (this.markedDone) {
      verdict = { met: true, clauses: clauses.map((text) => ({ text, met: true, evidence: "marked done by a human" })) };
    } else {
      // A judge that fails reads as "not met", the same as one that answers nonsense.
      const answer = await this.judge(evaluatorPrompt(clauses, evidence), this.model).catch(() => "");
      verdict = parseVerdict(answer, clauses);
    }
    this.log.append({ type: "goalCheck", turn, evaluatorModel: this.model, clauses: verdict.clauses, met: verdict.met });
    return verdict;
  }

  /** What the agent is told when it tried to stop too early. */
  static continuation(verdict: GoalVerdict): string {
    const unmet = verdict.clauses.filter((c) => !c.met);
    return [
      "Goal check: not yet. These parts of the goal are not met:",
      ...unmet.map((c) => `- ${c.text}${c.evidence ? ` (${c.evidence})` : ""}`),
      "Keep working until they are, then stop.",
    ].join("\n");
  }
}
