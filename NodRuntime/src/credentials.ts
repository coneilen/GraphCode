import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** `NodSettings.keychainService`: Nod's own sign-ins, never under `~/.graphcode`. */
export const KEYCHAIN_SERVICE = "app.graphcode.nod";

/** Keychain accounts under `KEYCHAIN_SERVICE`, written by Settings › Agents › Nod. */
export const KeychainAccount = {
  anthropicAPIKey: "anthropic-api-key",
  claudeOAuthToken: "claude-oauth-token",
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

/** Where Claude Code keeps its own login: the Keychain on macOS, a file elsewhere. */
export function hasClaudeCodeLogin(read: KeychainReader = readKeychain, home = homedir()): boolean {
  if (read("Claude Code-credentials")) return true;
  return existsSync(join(home, ".claude", ".credentials.json"));
}

export interface ClaudeCredentials {
  /** Variables for the engine's environment; empty when reusing Claude Code's own login. */
  env: Record<string, string>;
  source: "nod-api-key" | "nod-oauth" | "environment" | "claude-code-login" | "none";
}

/**
 * Nod's Keychain entry first, then an API key already in the environment, then the
 * Claude Code login on this Mac — which needs nothing passed, because the engine runs
 * Claude Code and Claude Code reads its own login.
 */
export function claudeCredentials(
  read: KeychainReader = readKeychain,
  env: Record<string, string | undefined> = process.env,
  home = homedir(),
): ClaudeCredentials {
  const apiKey = read(KEYCHAIN_SERVICE, KeychainAccount.anthropicAPIKey);
  if (apiKey) return { env: { ANTHROPIC_API_KEY: apiKey }, source: "nod-api-key" };
  const oauth = read(KEYCHAIN_SERVICE, KeychainAccount.claudeOAuthToken);
  if (oauth) return { env: { CLAUDE_CODE_OAUTH_TOKEN: oauth }, source: "nod-oauth" };
  if (env.ANTHROPIC_API_KEY || env.CLAUDE_CODE_OAUTH_TOKEN) return { env: {}, source: "environment" };
  if (hasClaudeCodeLogin(read, home)) return { env: {}, source: "claude-code-login" };
  return { env: {}, source: "none" };
}

/** A GitHub token from Nod's Keychain entry; without one, the Copilot CLI's own login is used. */
export function githubToken(read: KeychainReader = readKeychain): string | undefined {
  return read(KEYCHAIN_SERVICE, KeychainAccount.githubToken);
}
