#!/bin/sh
# Builds graphcode-nod for the app bundle: one self-contained executable plus the Copilot
# runtime it speaks to, in a folder the app copies to Contents/Helpers/nod/.
#
#   scripts/package.sh [out-dir] [bun-target]     e.g. scripts/package.sh dist bun-darwin-arm64
#
# SIGN_IDENTITY set: signs both with the hardened runtime and packaging/entitlements.plist —
# a compiled Bun binary needs JIT entitlements under the hardened runtime.
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

if [ -n "${SIGN_IDENTITY:-}" ]; then
  for binary in "$out/graphcode-nod" "$out/copilot-runtime" "$out/runtime.node"; do
    codesign --force --options runtime --timestamp --entitlements packaging/entitlements.plist \
      --sign "$SIGN_IDENTITY" "$binary"
  done
fi
ls -l "$out"
