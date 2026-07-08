#!/usr/bin/env bash
# Build both Rust plugins to WASM, then build & run the F# host.
# Run this from the repository root:  ./build.sh
set -euo pipefail

# Prefer rustup's toolchain (has the wasm target) over a Homebrew cargo.
[ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH"

echo ">> Ensuring the wasm target is installed..."
rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true

echo ">> Building Rust plugins (release, wasm32-unknown-unknown)..."
for p in resize-good exfiltrate-evil; do
  echo "   - $p"
  ( cd "plugins/$p" && cargo build --release --target wasm32-unknown-unknown )
done

echo ">> Building & running the F# host..."
# cwd stays at the repo root so the host's relative wasm paths resolve.
dotnet run --project host
