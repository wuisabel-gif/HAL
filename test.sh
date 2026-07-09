#!/usr/bin/env bash
# Regression net: build the plugins, run the host in policy mode, and fail if
# any of the three capability boundaries stops holding. No framework -- just
# grep the output for the refusals that make HAL "sandboxed". Run before push:
#
#   ./test.sh
set -euo pipefail
cd "$(dirname "$0")"
[ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH"

echo ">> building plugins..."
for p in resize-good exfiltrate-evil; do
  ( cd "plugins/$p" && cargo build --release --target wasm32-unknown-unknown )
done

echo ">> running host (policy mode)..."
out="$(dotnet run --project host -- policies.json 2>&1)"

fail=0
check() {
  if printf '%s' "$out" | grep -q "$1"; then
    echo "  ok:   $2"
  else
    echo "  FAIL: $2  (expected to find: $1)"
    fail=1
  fi
}

# The good plugin must still work inside its namespace...
check "transformed 5 bytes"  "trusted plugin runs within its grant"
# ...and each overreach must be refused:
check "denied kv_read"       "namespace isolation blocks a cross-plugin read"
check "blocked:"             "network denied (plugin has no NetworkHost)"
check "killed: fuel"         "fuel limit stops the CPU bomb"

if [ "$fail" = 0 ]; then
  echo ">> PASS: all boundaries held"
else
  echo ">> FAIL: a capability boundary regressed"
  printf '%s\n' "$out"
  exit 1
fi
