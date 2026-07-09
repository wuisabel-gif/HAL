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
#   ./detonate.sh --trace --image node:22 --run "npm test"   # + behavior log
#
# What isolation you get: no network (--network none), no host secrets (docker
# does not inherit your env), dropped capabilities, and a bounded memory/pid
# budget so a CPU/fork bomb can't take the box down. The source is mounted
# read-only. If the code needed the network or a secret, it fails HERE.
#
# --trace also RECORDS what the code tried to do: the hostnames it tried to
# resolve (via a DNS-logging sink on an egress-denied network), the files it
# created/modified, and -- when the image ships strace -- the exec and connect
# syscalls. Egress stays denied throughout; --trace shows intent, not success.
set -euo pipefail

DIR="."
IMAGE="mcr.microsoft.com/dotnet/runtime:10.0"
BUILD=""
RUN=""
DEMO=1
TRACE=0

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   DIR="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --build) BUILD="$2"; DEMO=0; shift 2 ;;
    --run)   RUN="$2"; DEMO=0; shift 2 ;;
    --trace) TRACE=1; shift ;;
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

if [ "$TRACE" = 0 ]; then
  # ---- plain mode: hard isolation, no network at all ----
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
fi

# ---- trace mode: same isolation, but RECORD what the code tried to do ----
# Two layers:
#   network intent -- the container's only DNS is a sink that logs every
#     hostname it tries to resolve, then black-holes it (egress stays denied
#     because the network is docker --internal, no route out).
#   files/processes -- a filesystem diff of the mount (files created/modified),
#     plus an strace of exec+connect IF the image already ships strace.
NET="detonet-$$"
SINK="detosink-$$"
cleanup() { docker rm -f "$SINK" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; rm -f "$SRC/.detonate-marker-$$"; }
trap cleanup EXIT

echo ">> starting DNS-logging sink on an internal (egress-denied) network..."
docker network create --internal "$NET" >/dev/null
# 15-line stdlib DNS logger: prints each queried name, answers 0.0.0.0.
docker run -d --name "$SINK" --network "$NET" python:3.12-slim python3 -c '
import socketserver,sys
class H(socketserver.BaseRequestHandler):
    def handle(self):
        data,sock=self.request
        i=12;parts=[]
        while data[i]:
            n=data[i];parts.append(data[i+1:i+1+n].decode("latin1"));i+=1+n
        print(".".join(parts),flush=True)
        q=data[12:i+5]
        r=data[:2]+b"\x81\x80"+data[4:6]+b"\x00\x01\x00\x00\x00\x00"+q
        r+=b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x1e\x00\x04\x00\x00\x00\x00"
        sock.sendto(r,self.client_address)
socketserver.UDPServer(("0.0.0.0",53),H).serve_forever()
' >/dev/null
sleep 1
SINKIP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$SINK")"

# If the target image has strace, wrap the run to trace exec + connect.
TRACED="$RUN"
if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v strace' >/dev/null 2>&1; then
  echo ">> image has strace: tracing exec + connect syscalls"
  TRACED="strace -f -qq -e trace=execve,connect -o /work/.strace-$$ $RUN"
else
  echo ">> image has no strace: skipping syscall trace (DNS + file layers only)"
fi

marker="$SRC/.detonate-marker-$$"; : > "$marker"
echo ">> detonating (egress denied, DNS logged)..."
echo ">>   run: $RUN"
set +e
docker run --rm \
  --network "$NET" --dns "$SINKIP" \
  --cap-add SYS_PTRACE \
  --security-opt no-new-privileges \
  --pids-limit 512 --memory 2g --tmpfs /tmp \
  -v "$SRC:/work" -w /work \
  "$IMAGE" \
  sh -c "$TRACED" 2>&1 | tee detonation.log
code=${PIPESTATUS[0]}
set -e

echo
echo "== behavioral trace =========================================="
echo "-- network: hostnames it tried to resolve (all egress denied) --"
docker logs "$SINK" 2>/dev/null | sort -u | sed 's/^/   /' | grep . || echo "   (none)"
echo "-- files created or modified during the run --"
find "$SRC" -type f -newer "$marker" \
  ! -name '.detonate-marker-*' ! -name '.strace-*' ! -name 'detonation.log' 2>/dev/null \
  | sed "s#^$SRC/#   #" | grep . || echo "   (none)"
if [ -f "$SRC/.strace-$$" ]; then
  echo "-- exec + outbound connect attempts (from strace) --"
  grep -hE 'execve\(|connect\(' "$SRC/.strace-$$" | sed 's/^/   /' | head -40 || true
  rm -f "$SRC/.strace-$$"
fi
echo "=============================================================="
echo ">> exit code: $code   (log: detonation.log)"
exit "$code"
