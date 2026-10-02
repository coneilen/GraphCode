import { appendFileSync, existsSync, mkdirSync, openSync, readSync, closeSync, statSync } from "node:fs";
import { dirname } from "node:path";
import { PROTOCOL_VERSION, wireDate, type NodEvent, type NodEventRecord } from "./protocol";

/**
 * `events.jsonl`: one record per line, append-only, `seq` strictly increasing across every
 * run that ever wrote the file — a resumed runtime continues the numbering rather than
 * restarting it, because readers tail by `seq`.
 *
 * Appends are synchronous: a record must be on disk before the event it describes can have
 * consequences (a permission ask the app is about to answer, a hunk it is about to accept).
 */
export class EventLog {
  private seq: number;
  private needsNewline: boolean;
  private listeners = new Set<(record: NodEventRecord) => void>();

  constructor(
    readonly path: string,
    private readonly clock: () => Date = () => new Date(),
  ) {
    mkdirSync(dirname(path), { recursive: true });
    let tail = readTail(path, TAIL_BYTES);
    this.seq = lastSeq(tail);
    // One record (a large diff or tool output) can outgrow the tail window.
    if (this.seq === 0 && Buffer.byteLength(tail) >= TAIL_BYTES) {
      tail = readTail(path, Number.MAX_SAFE_INTEGER);
      this.seq = lastSeq(tail);
    }
    // A runtime killed mid-write leaves a torn last line; starting on a fresh line keeps
    // the torn one from swallowing the next record.
    this.needsNewline = tail.length > 0 && !tail.endsWith("\n");
  }

  get lastSeq(): number {
    return this.seq;
  }

  append(event: NodEvent): NodEventRecord {
    this.seq += 1;
    const record = { v: PROTOCOL_VERSION, seq: this.seq, at: wireDate(this.clock()), ...event } as NodEventRecord;
    const line = JSON.stringify(record) + "\n";
    appendFileSync(this.path, this.needsNewline ? "\n" + line : line);
    this.needsNewline = false;
    for (const listener of this.listeners) listener(record);
    return record;
  }

  onRecord(listener: (record: NodEventRecord) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}

const TAIL_BYTES = 64 * 1024;

function readTail(path: string, maxBytes: number): string {
  if (!existsSync(path)) return "";
  const size = statSync(path).size;
  if (size === 0) return "";
  const length = Math.min(size, maxBytes);
  const buffer = Buffer.alloc(length);
  const fd = openSync(path, "r");
  try {
    readSync(fd, buffer, 0, length, size - length);
  } finally {
    closeSync(fd);
  }
  return buffer.toString("utf8");
}

/** The highest `seq` among the complete records in a log tail; torn or foreign lines are skipped. */
export function lastSeq(tail: string): number {
  let max = 0;
  for (const line of tail.split("\n")) {
    if (!line.startsWith("{")) continue;
    try {
      const seq = (JSON.parse(line) as { seq?: unknown }).seq;
      if (typeof seq === "number" && Number.isInteger(seq) && seq > max) max = seq;
    } catch {
      // torn line
    }
  }
  return max;
}
