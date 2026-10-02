import { existsSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { supportDirectory } from "./settings";

/**
 * Where each engine's agent runtime is. A `bun build --compile` binary cannot reach the SDKs'
 * platform packages — they resolve to the build machine's `node_modules` — so a packaged
 * graphcode-nod looks beside itself first, then for an installed CLI.
 */
export interface Locations {
  env: Record<string, string | undefined>;
  /**
   * The running executable, symlinks resolved: graphcode-nod when compiled, bun when run from
   * source. The daemon launches `<support-dir>/bin/graphcode-nod`, a symlink into the app
   * bundle, and the runtimes ship beside the real file.
   */
  execPath: string;
  /** This module's directory, for the source checkout's `node_modules`. */
  sourceDir: string;
  home: string;
  /** `~/.graphcode`: Setup can download Claude Code to `nod/bin/claude` for a Mac without it. */
  support: string;
  exists: (path: string) => boolean;
}

const here: Locations = {
  env: process.env,
  execPath: resolvedExecPath(),
  sourceDir: import.meta.dir,
  home: homedir(),
  support: supportDirectory(),
  exists: existsSync,
};

const platform = `${process.platform}-${process.arch}`;

function resolvedExecPath(): string {
  try {
    return realpathSync(process.execPath);
  } catch {
    return process.execPath;
  }
}

/**
 * Claude Code: the human's own install first, so Nod shares its sign-in and its updates;
 * then one shipped beside graphcode-nod or downloaded by Setup; then the SDK's bundled build
 * (source checkouts).
 */
export function claudeExecutable(at: Locations = here): string | undefined {
  return [
    at.env.GRAPHCODE_NOD_CLAUDE,
    join(at.home, ".local", "bin", "claude"),
    join(at.home, ".claude", "local", "claude"),
    "/opt/homebrew/bin/claude",
    "/usr/local/bin/claude",
    join(dirname(at.execPath), "claude"),
    join(at.support, "nod", "bin", "claude"),
  ].find((path): path is string => Boolean(path) && at.exists(path!));
}

/**
 * The Copilot runtime the SDK speaks to: one shipped beside graphcode-nod (with its
 * `runtime.node`), the SDK's own in a source checkout, then an installed `copilot` CLI.
 */
export function copilotRuntime(at: Locations = here): string | undefined {
  return [
    at.env.GRAPHCODE_NOD_COPILOT,
    join(dirname(at.execPath), "copilot-runtime"),
    join(at.sourceDir, "..", "node_modules", "@github", `copilot-sdk-${platform}`, "prebuilds", platform, "copilot-runtime"),
    "/opt/homebrew/bin/copilot",
    "/usr/local/bin/copilot",
    join(at.home, ".local", "bin", "copilot"),
  ].find((path): path is string => Boolean(path) && at.exists(path!));
}
