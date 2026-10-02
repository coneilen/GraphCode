import { expect, test } from "bun:test";
import { claudeExecutable, copilotRuntime, type Locations } from "../src/agentRuntimes";
import { anthropicAPIKey, claudeEnvironment, githubToken } from "../src/credentials";

function at(present: string[], env: Record<string, string> = {}): Locations {
  return {
    env,
    execPath: "/Applications/GraphCode.app/Contents/Helpers/nod/graphcode-nod",
    sourceDir: "/$bunfs/root",
    home: "/Users/me",
    exists: (path) => present.includes(path),
  };
}

test("Claude Code: the build shipped beside graphcode-nod, never the human's install unless overridden", () => {
  const shipped = "/Applications/GraphCode.app/Contents/Helpers/nod/claude";
  expect(claudeExecutable(at([shipped, "/Users/me/.local/bin/claude"]))).toBe(shipped);
  expect(claudeExecutable(at(["/Users/me/.local/bin/claude"]))).toBeUndefined();
  expect(claudeExecutable(at([shipped, "/x/claude"], { GRAPHCODE_NOD_CLAUDE: "/x/claude" }))).toBe("/x/claude");
});

test("Copilot: the runtime shipped beside graphcode-nod wins over an installed CLI", () => {
  const shipped = "/Applications/GraphCode.app/Contents/Helpers/nod/copilot-runtime";
  expect(copilotRuntime(at([shipped, "/opt/homebrew/bin/copilot"]))).toBe(shipped);
  expect(copilotRuntime(at(["/opt/homebrew/bin/copilot"]))).toBe("/opt/homebrew/bin/copilot");
  expect(copilotRuntime(at([]))).toBeUndefined();
});

test("sign-in reads only Nod's own Keychain items", () => {
  const asked: string[] = [];
  const read = (service: string, account?: string) => (asked.push(`${service}/${account}`), account === "anthropic-api-key" ? "sk-1" : undefined);
  expect(anthropicAPIKey(read)).toBe("sk-1");
  expect(githubToken(read)).toBeUndefined();
  expect(asked).toEqual(["app.graphcode.nod/anthropic-api-key", "app.graphcode.nod/github-token"]);
});

test("Claude Code gets Nod's key and config dir, and no inherited way to sign in", () => {
  const env = claudeEnvironment("sk-nod", "/support/nod/claude", {
    PATH: "/bin",
    ANTHROPIC_API_KEY: "sk-other",
    ANTHROPIC_AUTH_TOKEN: "t",
    CLAUDE_CODE_OAUTH_TOKEN: "oauth",
    CLAUDE_CONFIG_DIR: "/Users/me/.claude",
  });
  expect(env).toEqual({
    PATH: "/bin",
    ANTHROPIC_API_KEY: "sk-nod",
    CLAUDE_CONFIG_DIR: "/support/nod/claude",
    CLAUDE_AGENT_SDK_CLIENT_APP: "graphcode-nod",
  });
});
