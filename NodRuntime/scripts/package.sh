#!/bin/sh
# Builds graphcode-nod for the app bundle: one self-contained executable plus both engines'
# agent runtimes — the Claude Code the Agent SDK bundles and the Copilot runtime — in a
# folder the app copies to Contents/Helpers/nod/. Nothing is installed on the Mac.
#
#   scripts/package.sh [out-dir] [bun-target]     e.g. scripts/package.sh dist bun-darwin-arm64
#
# SIGN_IDENTITY set: signs graphcode-nod and the Copilot runtime with the hardened runtime and
# packaging/entitlements.plist — a compiled Bun binary needs JIT entitlements under the
# hardened runtime. Claude Code keeps Anthropic's own signature.
set -eu
cd "$(dirname "$0")/.."
out=${1:-dist}
target=${2:-bun-darwin-$(uname -m | sed 's/x86_64/x64/')}
platform=$(echo "$target" | sed 's/^bun-//')

bun install --frozen-lockfile
mkdir -p "$out"
bun build src/main.ts --compile --minify --target="$target" --outfile "$out/graphcode-nod"

runtime="node_modules/@github/copilot-sdk-$platform/prebuilds/$platform"
cp "$runtime/copilot-runtime" "$runtime/runtime.node" "$out/"
cp "node_modules/@anthropic-ai/claude-agent-sdk-$platform/claude" "$out/"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  for binary in "$out/graphcode-nod" "$out/copilot-runtime" "$out/runtime.node"; do
    codesign --force --options runtime --timestamp --entitlements packaging/entitlements.plist \
      --sign "$SIGN_IDENTITY" "$binary"
  done
fi
ls -l "$out"
