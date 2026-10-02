import { spawnSync } from "node:child_process";

/** `NodSettings.keychainService`: Nod's own sign-ins, never under `~/.graphcode`. */
export const KEYCHAIN_SERVICE = "app.graphcode.nod";

/** Keychain accounts under `KEYCHAIN_SERVICE`, written by Settings › Agents › Nod. */
export const KeychainAccount = {
  anthropicAPIKey: "anthropic-api-key",
  githubToken: "github-token",
} as const;

export type KeychainReader = (service: string, account?: string) => string | undefined;

export const readKeychain: KeychainReader = (service, account) => {
  if (process.platform !== "darwin") return undefined;
  const args = ["find-generic-password", "-s", service, ...(account ? ["-a", account] : []), "-w"];
  const result = spawnSync("/usr/bin/security", args, { encoding: "utf8", timeout: 5000 });
  if (result.status !== 0) return undefined;
  const value = result.stdout.trim();
  return value || undefined;
};

/**
 * The Claude engine signs in with an Anthropic API key from Nod's Keychain entry and nothing
 * else — never a claude.ai login, Claude Code's or anyone's (policy, mailroom #1190).
 */
export function anthropicAPIKey(read: KeychainReader = readKeychain): string | undefined {
  return read(KEYCHAIN_SERVICE, KeychainAccount.anthropicAPIKey);
}

/** A GitHub token from Nod's Keychain entry; without one, the Copilot CLI's own login is used. */
export function githubToken(read: KeychainReader = readKeychain): string | undefined {
  return read(KEYCHAIN_SERVICE, KeychainAccount.githubToken);
}

/** Variables that would let Claude Code sign in some other way; stripped from its environment. */
export const FOREIGN_CLAUDE_AUTH = [
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CONFIG_DIR",
];

/**
 * Claude Code's environment: the parent's, without any inherited credential, with Nod's key
 * and a config directory of Nod's own — so Claude Code can't find the human's login there.
 */
export function claudeEnvironment(
  apiKey: string,
  configDir: string,
  parent: Record<string, string | undefined> = process.env,
): Record<string, string | undefined> {
  const env = { ...parent };
  for (const name of FOREIGN_CLAUDE_AUTH) delete env[name];
  return { ...env, ANTHROPIC_API_KEY: apiKey, CLAUDE_CONFIG_DIR: configDir, CLAUDE_AGENT_SDK_CLIENT_APP: "graphcode-nod" };
}
