#!/usr/bin/env bash
# Install a global `hal` command that runs the host from any directory:
#
#   ./install.sh                 # installs to ~/.local (no sudo)
#   PREFIX=/usr/local ./install.sh
#
# `hal` is for running your OWN policy files: `hal my-policies.json`, with the
# wasm paths in that file resolved against your current directory. The no-arg
# demo still lives in the repo (it needs the repo's plugins/ folder).
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
LIBEXEC="$PREFIX/libexec/hal"
BIN="$PREFIX/bin"

command -v dotnet >/dev/null 2>&1 || { echo "!! .NET SDK 10+ is required" >&2; exit 1; }

echo ">> publishing host to $LIBEXEC"
rm -rf "$LIBEXEC"
dotnet publish host -c Release -o "$LIBEXEC" >/dev/null

mkdir -p "$BIN"
# Wrapper runs the DLL via `dotnet` (not the bare apphost) so it finds the
# runtime wherever the SDK lives -- the apphost only looks in default paths and
# breaks on a Homebrew-installed .NET.
cat > "$BIN/hal" <<EOF
#!/usr/bin/env bash
exec dotnet "$LIBEXEC/Hal.dll" "\$@"
EOF
chmod +x "$BIN/hal"

echo ">> installed: $BIN/hal"
case ":$PATH:" in
  *":$BIN:"*) echo ">> ready:  hal <your-policies.json>" ;;
  *) echo ">> add to PATH first:  export PATH=\"$BIN:\$PATH\"" ;;
esac
