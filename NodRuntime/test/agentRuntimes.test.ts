import { expect, test } from "bun:test";
import { claudeExecutable, copilotRuntime, type Locations } from "../src/agentRuntimes";
import { claudeCredentials } from "../src/credentials";

function at(present: string[], env: Record<string, string> = {}): Locations {
  return {
    env,
    execPath: "/Applications/GraphCode.app/Contents/Helpers/graphcode-nod",
    sourceDir: "/$bunfs/root",
    home: "/Users/me",
    support: "/Users/me/.graphcode",
    exists: (path) => present.includes(path),
  };
}

test("Claude Code: the override, then the human's install, then one shipped beside graphcode-nod", () => {
  const shipped = "/Applications/GraphCode.app/Contents/Helpers/claude";
  expect(claudeExecutable(at([shipped, "/Users/me/.local/bin/claude"]))).toBe("/Users/me/.local/bin/claude");
  expect(claudeExecutable(at([shipped]))).toBe(shipped);
  expect(claudeExecutable(at([shipped, "/x/claude"], { GRAPHCODE_NOD_CLAUDE: "/x/claude" }))).toBe("/x/claude");
  expect(claudeExecutable(at(["/Users/me/.graphcode/nod/bin/claude"]))).toBe("/Users/me/.graphcode/nod/bin/claude");
  expect(claudeExecutable(at([]))).toBeUndefined();
});

test("Copilot: the runtime shipped beside graphcode-nod wins over an installed CLI", () => {
  const shipped = "/Applications/GraphCode.app/Contents/Helpers/copilot-runtime";
  expect(copilotRuntime(at([shipped, "/opt/homebrew/bin/copilot"]))).toBe(shipped);
  expect(copilotRuntime(at(["/opt/homebrew/bin/copilot"]))).toBe("/opt/homebrew/bin/copilot");
  expect(copilotRuntime(at([]))).toBeUndefined();
});

test("Claude credentials: Nod's Keychain entry, then the environment, then Claude Code's own login", () => {
  const keychain = (entries: Record<string, string>) => (service: string, account?: string) => entries[`${service}/${account ?? ""}`];
  expect(claudeCredentials(keychain({ "app.graphcode.nod/anthropic-api-key": "sk-1" }), {}, "/nohome")).toEqual({
    env: { ANTHROPIC_API_KEY: "sk-1" },
    source: "nod-api-key",
  });
  expect(claudeCredentials(keychain({ "app.graphcode.nod/claude-oauth-token": "t" }), {}, "/nohome").env).toEqual({ CLAUDE_CODE_OAUTH_TOKEN: "t" });
  expect(claudeCredentials(keychain({}), { ANTHROPIC_API_KEY: "x" }, "/nohome").source).toBe("environment");
  expect(claudeCredentials(keychain({ "Claude Code-credentials/": "{}" }), {}, "/nohome")).toEqual({ env: {}, source: "claude-code-login" });
  expect(claudeCredentials(keychain({}), {}, "/nohome").source).toBe("none");
});
