import { basename } from "node:path";

export interface ToolDescription {
  /** The work card's one line, e.g. `Search "UsageGate"`. */
  title: string;
  /** The canvas card's live line, in PresenceHooks' activity-script phrasing. */
  activity: string;
}

function field(input: unknown, ...keys: string[]): string {
  if (typeof input !== "object" || input === null) return "";
  const record = input as Record<string, unknown>;
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string" && value) return value;
  }
  return "";
}

function oneLine(text: string, max = 80): string {
  const line = text.replace(/\s+/g, " ").trim();
  return line.length > max ? line.slice(0, max - 1) + "…" : line;
}

/** Covers both engines' tool names: Claude Code's (`Read`, `Bash`) and Copilot's (`view`, `bash`). */
export function describeTool(tool: string, input: unknown): ToolDescription {
  const path = field(input, "file_path", "path", "notebook_path", "fileName");
  const name = path ? basename(path) : "";
  switch (tool.toLowerCase()) {
    case "edit":
    case "multiedit":
    case "write":
    case "create":
    case "str_replace_editor":
    case "notebookedit":
      return { title: `Edit ${name}`, activity: `editing ${name}` };
    case "read":
    case "view":
      return { title: `Read ${name}`, activity: `reading ${name}` };
    case "bash":
    case "shell":
    case "bashoutput": {
      const command = oneLine(field(input, "command", "fullCommandText"));
      return { title: command || "Shell", activity: `running ${command}` };
    }
    case "grep":
    case "rg": {
      const pattern = field(input, "pattern", "query");
      return { title: `Search "${oneLine(pattern, 60)}"`, activity: `searching for ${pattern}` };
    }
    case "glob": {
      const pattern = field(input, "pattern");
      return { title: `Find "${oneLine(pattern, 60)}"`, activity: `looking for ${pattern}` };
    }
    case "websearch":
    case "web_search": {
      const query = field(input, "query");
      return { title: `Search the web for "${oneLine(query, 60)}"`, activity: `searching the web for ${query}` };
    }
    case "webfetch":
    case "web_fetch": {
      const host = field(input, "url").replace(/^\w+:\/\//, "").split("/")[0] ?? "";
      return { title: `Fetch ${host}`, activity: `reading ${host}` };
    }
    case "task":
    case "agent": {
      const description = field(input, "description");
      return { title: `Delegate ${oneLine(description, 60)}`, activity: `delegating ${description}` };
    }
    case "todowrite":
    case "update_todo":
      return { title: "Plan", activity: "planning" };
  }
  if (tool.startsWith("mcp__")) {
    const short = tool.split("__").pop() ?? tool;
    return { title: `Use ${short}`, activity: `using ${short}` };
  }
  return { title: tool, activity: `using ${tool}` };
}

/** A tool result's one-line summary: `exit 0`, `84 lines`, or the first line of the output. */
export function summarizeResult(tool: string, output: string, isError: boolean): string {
  const lines = output.split("\n").filter((l) => l.trim().length > 0);
  if (isError) return oneLine(lines[0] ?? "failed", 100);
  switch (tool.toLowerCase()) {
    case "read":
    case "view":
      return `${lines.length} lines`;
    case "grep":
    case "glob":
      return lines.length === 0 ? "no matches" : `${lines.length} ${lines.length === 1 ? "match" : "matches"}`;
  }
  return oneLine(lines[lines.length - 1] ?? "done", 100);
}
