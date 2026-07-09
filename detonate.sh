#!/usr/bin/env bash
# Detonate untrusted code in a throwaway, network-denied container BEFORE you
# run it on your own machine with real credentials. Local twin of
# .github/workflows/sandbox-pr.yml -- the "detonate before you download" step
# the capability-security-review skill tells the agent to reach for.
#
#   ./detonate.sh                                  # detonate HAL's own demo
#   ./detonate.sh --image python:3.12 \
#                 --run "python app.py" --dir ./suspicious-pr
#   ./detonate.sh --build "npm ci" --image node:22 \
#                 --run "npm test" --dir ./suspicious-pr
#
# What isolation you get: no network (--network none), no host secrets (docker
# does not inherit your env), dropped capabilities, and a bounded memory/pid
# budget so a CPU/fork bomb can't take the box down. The source is mounted
# read-only. If the code needed the network or a secret, it fails HERE.
#
# ponytail: this proves *isolation*, not a full behavioral trace. To also see
# what it attempted (connections, files, syscalls), run the container under
# `strace -f` or point `--network` at a logging proxy. Left as an upgrade path.
set -euo pipefail

DIR="."
IMAGE="mcr.microsoft.com/dotnet/runtime:10.0"
BUILD=""
RUN=""
DEMO=1

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --build) BUILD="$2"; DEMO=0; shift 2 ;;
    --run)   RUN="$2"; DEMO=0; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "!! docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1        || { echo "!! docker daemon is not running" >&2; exit 1; }

if [ "$DEMO" = 1 ]; then
  # Build HAL on the host (network on, to fetch deps), then run the host binary
  # inside the sandbox. Same split as CI: isolate the EXECUTION, not the build.
  echo ">> building HAL demo on host (network on for deps)..."
  [ -d "$HOME/.cargo/bin" ] && export PATH="$HOME/.cargo/bin:$PATH"
  rustup target add wasm32-unknown-unknown >/dev/null 2>&1 || true
  for p in resize-good exfiltrate-evil; do
    ( cd "plugins/$p" && cargo build --release --target wasm32-unknown-unknown )
  done
  dotnet publish host -c Release -o out >/dev/null
  # Run the portable IL DLL via `dotnet`, not the apphost: publishing on macOS
  # produces a Mach-O apphost that can't exec in a Linux container. The DLL is
  # arch-neutral and the runtime image ships `dotnet`; native libextism is
  # resolved from out/runtimes/<container-arch>/native.
  RUN="dotnet out/Hal.dll"
  DIR="."
elif [ -n "$BUILD" ]; then
  echo ">> build on host (network on): $BUILD"
  ( cd "$DIR" && bash -c "$BUILD" )
fi

[ -n "$RUN" ] || { echo "!! nothing to run: pass --run \"<cmd>\"" >&2; exit 1; }

SRC="$(cd "$DIR" && pwd)"
echo ">> detonating in a --network none sandbox ($IMAGE)"
echo ">>   run: $RUN"

set +e
docker run --rm \
  --network none \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --memory 512m \
  --tmpfs /tmp \
  -v "$SRC:/work:ro" \
  -w /work \
  "$IMAGE" \
  sh -c "$RUN" 2>&1 | tee detonation.log
code=${PIPESTATUS[0]}
set -e

echo
echo ">> exit code: $code   (log: detonation.log)"
echo ">> it ran with no network and none of your secrets. If it needed either,"
echo ">> it failed in the sandbox, not on your machine."
exit "$code"
