export interface Hunk {
  oldStart: number;
  oldLines: number;
  newStart: number;
  newLines: number;
  /** Each line prefixed with ' ', '-' or '+'. */
  lines: string[];
}

type Op = { kind: " " | "-" | "+"; text: string };

/**
 * Lines as `split("\n")` gives them, so joining with "\n" restores the text byte for byte —
 * except that empty text has no lines, so creating a file diffs as pure additions.
 */
export function splitLines(text: string): string[] {
  return text === "" ? [] : text.split("\n");
}

/** Myers' O(ND) line diff, after trimming the common prefix and suffix. */
export function diffLines(a: string[], b: string[]): Op[] {
  let prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix++;
  let suffix = 0;
  while (
    suffix < a.length - prefix &&
    suffix < b.length - prefix &&
    a[a.length - 1 - suffix] === b[b.length - 1 - suffix]
  )
    suffix++;
  const midA = a.slice(prefix, a.length - suffix);
  const midB = b.slice(prefix, b.length - suffix);
  const ops: Op[] = a.slice(0, prefix).map((text) => ({ kind: " ", text }));
  ops.push(...myers(midA, midB));
  ops.push(...a.slice(a.length - suffix).map((text): Op => ({ kind: " ", text })));
  return ops;
}

function myers(a: string[], b: string[]): Op[] {
  const n = a.length;
  const m = b.length;
  if (n === 0) return b.map((text) => ({ kind: "+", text }));
  if (m === 0) return a.map((text) => ({ kind: "-", text }));
  const max = n + m;
  const offset = max;
  let v: Int32Array = new Int32Array(2 * max + 2);
  const trace: Int32Array[] = [];
  outer: for (let d = 0; d <= max; d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x =
        k === -d || (k !== d && v[offset + k - 1]! < v[offset + k + 1]!) ? v[offset + k + 1]! : v[offset + k - 1]! + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        trace.push(v.slice());
        break outer;
      }
    }
  }
  const ops: Op[] = [];
  let x = n;
  let y = m;
  for (let d = trace.length - 2; d >= 0 && (x > 0 || y > 0); d--) {
    v = trace[d]!;
    const k = x - y;
    const prevK =
      k === -d || (k !== d && v[offset + k - 1]! < v[offset + k + 1]!) ? k + 1 : k - 1;
    const prevX = v[offset + prevK]!;
    const prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.push({ kind: " ", text: a[--x]! });
      y--;
    }
    if (d === 0) break;
    if (x === prevX) ops.push({ kind: "+", text: b[--y]! });
    else ops.push({ kind: "-", text: a[--x]! });
  }
  while (x > 0 && y > 0) {
    ops.push({ kind: " ", text: a[--x]! });
    y--;
  }
  return ops.reverse();
}

/** Groups a diff into unified-diff hunks with `context` lines around each change, as git does. */
export function hunks(before: string, after: string, context = 3): Hunk[] {
  const ops = diffLines(splitLines(before), splitLines(after));
  const changed = ops.map((op, i) => (op.kind === " " ? -1 : i)).filter((i) => i >= 0);
  if (changed.length === 0) return [];
  const ranges: [number, number][] = [];
  for (const i of changed) {
    const start = Math.max(0, i - context);
    const end = Math.min(ops.length - 1, i + context);
    const last = ranges[ranges.length - 1];
    if (last && start <= last[1] + 1) last[1] = Math.max(last[1], end);
    else ranges.push([start, end]);
  }
  const oldLineAt: number[] = [];
  const newLineAt: number[] = [];
  let oldLine = 1;
  let newLine = 1;
  for (const op of ops) {
    oldLineAt.push(oldLine);
    newLineAt.push(newLine);
    if (op.kind !== "+") oldLine++;
    if (op.kind !== "-") newLine++;
  }
  return ranges.map(([start, end]) => {
    const slice = ops.slice(start, end + 1);
    const oldLines = slice.filter((op) => op.kind !== "+").length;
    const newLines = slice.filter((op) => op.kind !== "-").length;
    return {
      oldStart: oldLineAt[start]!,
      oldLines,
      newStart: newLineAt[start]!,
      newLines,
      lines: slice.map((op) => op.kind + op.text),
    };
  });
}

export function hunkHeader(hunk: Hunk): string {
  return `@@ -${hunk.oldStart},${hunk.oldLines} +${hunk.newStart},${hunk.newLines} @@`;
}

export function hunkStats(hunk: Hunk): { added: number; removed: number } {
  // A hunk that ends on a change, with no context after it, ends at end of file — and an
  // empty last line there is the text's final newline, not a line of its own.
  const last = hunk.lines[hunk.lines.length - 1];
  const lines = last === "+" || last === "-" ? hunk.lines.slice(0, -1) : hunk.lines;
  return {
    added: lines.filter((l) => l.startsWith("+")).length,
    removed: lines.filter((l) => l.startsWith("-")).length,
  };
}

export class HunkConflict extends Error {}

/**
 * Applies one hunk to `text` wherever its old side now sits — other hunks of the same edit
 * may have been accepted or rejected first, so the expected line is a hint, not an address.
 * `reverse` undoes a hunk that was already applied.
 */
export function applyHunk(text: string, hunk: Hunk, reverse = false): string {
  const from = reverse ? "+" : "-";
  const to = reverse ? "-" : "+";
  const oldBlock = hunk.lines.filter((l) => !l.startsWith(to)).map((l) => l.slice(1));
  const newBlock = hunk.lines.filter((l) => !l.startsWith(from)).map((l) => l.slice(1));
  const lines = splitLines(text);
  const hint = (reverse ? hunk.newStart : hunk.oldStart) - 1;
  const at = locate(lines, oldBlock, hint);
  if (at < 0) throw new HunkConflict("the file changed under this hunk");
  lines.splice(at, oldBlock.length, ...newBlock);
  return lines.join("\n");
}

function locate(lines: string[], block: string[], hint: number): number {
  const matches = (at: number) => block.every((line, i) => lines[at + i] === line);
  const last = lines.length - block.length;
  for (let distance = 0; distance <= lines.length; distance++) {
    for (const at of distance === 0 ? [hint] : [hint - distance, hint + distance]) {
      if (at >= 0 && at <= last && matches(at)) return at;
    }
  }
  return -1;
}
