import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { createSdkMcpServer, tool, type McpServerConfig, type SdkMcpToolDefinition } from "@anthropic-ai/claude-agent-sdk";
import type { MCPServerConfig, Tool, ToolResultObject } from "@github/copilot-sdk";
import { z } from "zod";
import { serverName, type GraphcodeTool, type ToolResult } from "./mcp";

/** A server entry from `.mcp.json`, in the shape Claude Code and Copilot CLI both read. */
export type ProjectMcpServer =
  | { type?: "stdio"; command: string; args?: string[]; env?: Record<string, string> }
  | { type: "http" | "sse"; url: string; headers?: Record<string, string> };

/** What each engine mounts: the built-in graphcode server and the project's own servers. */
export interface McpMount {
  graphcode: GraphcodeTool[];
  servers: Record<string, ProjectMcpServer>;
}

/** Copilot custom tools share one namespace with its built-ins, so they carry the server's name. */
export const copilotToolPrefix = `${serverName}_`;

/**
 * The project's `.mcp.json` servers, nearest file first as the CLIs find it walking up from
 * the working directory, with `${VAR}` and `${VAR:-default}` expanded. Names in `disabled`
 * are left out, and so is any entry called `graphcode`: the built-in server always wins.
 */
export function loadProjectMcpServers(
  cwd: string,
  disabled: string[],
  env: Record<string, string | undefined> = process.env,
): Record<string, ProjectMcpServer> {
  const servers: Record<string, ProjectMcpServer> = {};
  const skip = new Set([...disabled, serverName]);
  for (let dir = resolve(cwd); ; dir = dirname(dir)) {
    const file = join(dir, ".mcp.json");
    if (existsSync(file)) {
      for (const [name, entry] of Object.entries(readServers(file))) {
        if (skip.has(name) || name in servers) continue;
        const server = projectServer(entry, env);
        if (server) servers[name] = server;
      }
    }
    if (dirname(dir) === dir) return servers;
  }
}

function readServers(file: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8")) as { mcpServers?: unknown };
    return parsed.mcpServers && typeof parsed.mcpServers === "object" ? (parsed.mcpServers as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function projectServer(entry: unknown, env: Record<string, string | undefined>): ProjectMcpServer | undefined {
  if (!entry || typeof entry !== "object") return undefined;
  const e = entry as Record<string, unknown>;
  const expand = (text: string) =>
    text.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/g, (_, name: string, fallback?: string) => env[name] ?? fallback ?? "");
  const strings = (value: unknown) =>
    value && typeof value === "object" && !Array.isArray(value)
      ? Object.fromEntries(Object.entries(value).filter(([, v]) => typeof v === "string").map(([k, v]) => [k, expand(v as string)]))
      : undefined;
  if ((e.type === "http" || e.type === "sse") && typeof e.url === "string") {
    const headers = strings(e.headers);
    return { type: e.type, url: expand(e.url), ...(headers ? { headers } : {}) };
  }
  if ((e.type === undefined || e.type === "stdio") && typeof e.command === "string") {
    const args = Array.isArray(e.args) ? e.args.filter((a): a is string => typeof a === "string").map(expand) : undefined;
    const vars = strings(e.env);
    return { type: "stdio", command: expand(e.command), ...(args ? { args } : {}), ...(vars ? { env: vars } : {}) };
  }
  return undefined;
}

/** A thrown handler — graphcoded down, a bad reply — is the model's to read, not a crash. */
async function run(t: GraphcodeTool, args: Record<string, unknown>): Promise<ToolResult> {
  try {
    return await t.handler(args ?? {});
  } catch (error) {
    return { text: error instanceof Error ? error.message : String(error), isError: true };
  }
}

/** The Agent SDK's in-process server takes zod shapes; the graphcode tools use flat JSON Schema. */
function zodShape(schema: GraphcodeTool["inputSchema"]): Record<string, z.ZodType> {
  const required = new Set(schema.required ?? []);
  return Object.fromEntries(
    Object.entries(schema.properties).map(([key, value]) => {
      const property = value as { type?: string; description?: string };
      let field: z.ZodType = property.type === "number" ? z.number() : property.type === "boolean" ? z.boolean() : z.string();
      if (property.description) field = field.describe(property.description);
      return [key, required.has(key) ? field : field.optional()];
    }),
  );
}

export function claudeGraphcodeTools(tools: GraphcodeTool[]): SdkMcpToolDefinition[] {
  return tools.map((t) =>
    tool(
      t.name,
      t.description,
      zodShape(t.inputSchema),
      async (args) => {
        const result = await run(t, args as Record<string, unknown>);
        return { content: [{ type: "text", text: result.text }], ...(result.isError ? { isError: true } : {}) };
      },
      { annotations: { readOnlyHint: t.readOnly }, alwaysLoad: true },
    ),
  );
}

export function claudeMcpServers(mount: McpMount): Record<string, McpServerConfig> {
  return {
    ...mount.servers,
    [serverName]: createSdkMcpServer({ name: serverName, version: "1", tools: claudeGraphcodeTools(mount.graphcode), alwaysLoad: true }),
  };
}

export function copilotGraphcodeTools(tools: GraphcodeTool[]): Tool[] {
  return tools.map((t) => ({
    name: copilotToolPrefix + t.name,
    description: t.description,
    parameters: t.inputSchema,
    defer: "never",
    async handler(args: unknown): Promise<ToolResultObject> {
      const result = await run(t, args as Record<string, unknown>);
      return result.isError
        ? { textResultForLlm: result.text, resultType: "failure", error: result.text }
        : { textResultForLlm: result.text, resultType: "success" };
    },
  }));
}

export function copilotMcpServers(mount: McpMount): Record<string, MCPServerConfig> {
  return Object.fromEntries(
    Object.entries(mount.servers).map(([name, server]): [string, MCPServerConfig] =>
      "url" in server
        ? [name, { type: server.type, url: server.url, ...(server.headers ? { headers: server.headers } : {}), tools: ["*"] }]
        : [name, { type: "stdio", command: server.command, args: server.args ?? [], ...(server.env ? { env: server.env } : {}), tools: ["*"] }],
    ),
  );
}
