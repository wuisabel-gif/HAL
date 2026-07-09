# HAL

<p align="center">
  <img src="assets/hal9000.svg" alt="HAL 9000 camera eye" width="300">
</p>
<p align="center">
  <sub>HAL 9000 from <em>2001: A Space Odyssey</em>. © Warner Bros. Entertainment Inc.</sub>
</p>

A tiny **capability-secure plugin sandbox**: an F# host that loads untrusted
WebAssembly plugins and grants each one *only* the abilities its policy allows.
The demo ships two plugins: one that behaves, and one that tries to overreach
and gets stopped at three different boundaries.

The name is a wink at *2001: A Space Odyssey*. When a plugin reaches for
something it wasn't granted, HAL gives it the most famous refusal in cinema:
*"I'm sorry, Dave. I'm afraid I can't do that."* Here, though, the refusal is the
**hero** behavior, not the villain's. That's the object-capability model, the
same idea the E language pioneered, running on modern, maintained tooling: the
malicious plugin fails not because HAL detects an attack, but because it was
never handed the capability in the first place.

## Layout

```
hal/
  host/                       F# host (loads plugins, grants capabilities)
    Hal.fsproj
    Program.fs
  plugins/
    resize-good/              Rust plugin: trusted, well-behaved
    exfiltrate-evil/          Rust plugin: untrusted, tries to overreach
  build.sh                    build plugins + run host
```

## How it works

The host defines a small capability type:

```fsharp
type Capability =
    | KvNamespace of prefix: string      // may read/write store keys under this prefix
    | NetworkHost of host: string        // may make HTTP requests to this host
    | FuelLimit of instructions: int64   // hard cap before termination
```

Each plugin has a `PluginPolicy` listing exactly what it gets. From that policy HAL
builds an Extism `Manifest` and a set of **host functions**: small F# functions that
are the *only* way a plugin can reach the outside world. A plugin that isn't granted a
capability simply has no way to exercise it:

- **Data access** goes through `kv_read` / `kv_write` host functions. Each plugin's
  copy of those functions is locked to its own namespace prefix, enforced in trusted
  host code. `exfiltrate-evil` asking for `resize-good/input` gets the HAL treatment.
- **Network** is deny-by-default. `exfiltrate-evil` is granted no `NetworkHost`, so its
  HTTP request is blocked by the runtime before it leaves the sandbox.
- **CPU** is bounded by `FuelLimit`. `exfiltrate-evil`'s infinite loop trips the
  instruction budget and the runtime kills it (an `ExtismException` mentioning "fuel").

## Prerequisites

- **.NET SDK 10.0+**: https://dotnet.microsoft.com/download
- **Rust + the wasm target**: https://rustup.rs then
  `rustup target add wasm32-unknown-unknown`

The `Extism.runtime.all` NuGet package pulls in the native `libextism` runtime, so you
do **not** need to install Extism separately for the .NET host.

## Build & run

From the repo root:

```bash
./build.sh
```

Or step by step:

```bash
# 1. build the plugins to wasm
(cd plugins/resize-good     && cargo build --release --target wasm32-unknown-unknown)
(cd plugins/exfiltrate-evil && cargo build --release --target wasm32-unknown-unknown)

# 2. run the host from the repo root (so its relative wasm paths resolve)
dotnet run --project host
```

### Point HAL at your own plugins

The demo policies are the no-argument default. To run HAL as a generic
capability-scoped runner, pass a policy file and it loads that instead of
editing any F#:

```bash
dotnet run --project host -- policies.json
```

Each plugin entry lists only what it's granted (`kvPrefix`, `hosts`, `fuel`)
and the calls to make; the shared `seed` pre-populates the store. See
`policies.json` for the schema, which reproduces the built-in demo.

To get a global `hal` command you can run from any directory:

```bash
./install.sh                 # installs to ~/.local (no sudo)
hal my-policies.json         # wasm paths resolve against your cwd
```

### Detonate untrusted code locally

`detonate.sh` runs a build/test inside a throwaway `--network none` container
with no host secrets, dropped capabilities, and a bounded memory/pid budget.
It's the local twin of the CI workflow below.

```bash
./detonate.sh                                        # detonate HAL's own demo
./detonate.sh --image node:22 --build "npm ci" \
              --run "npm test" --dir ./suspicious-pr # any repo
```

Needs a running Docker daemon.

## Expected output (abridged)

```
HAL -- a capability-secure plugin sandbox  (F# host + Rust/WASM plugins)

=== resize-good : a trusted, well-behaved transform ===
    [HAL] kv_read  'resize-good/input' -> 5 bytes
    [HAL] kv_write 'resize-good/input.out' <- 5 bytes
  plugin returned: transformed 5 bytes: 'resize-good/input' -> 'resize-good/input.out'
  output asset written by plugin: [245, 235, 225, 215, 5]

=== exfiltrate-evil : untrusted code that tries to overreach ===
  -- attempt 1: read another plugin's asset --
    [HAL] I'm sorry, Dave. I'm afraid I can't do that.
          (denied kv_read 'resize-good/input' -- outside namespace 'exfiltrate-evil/')
  plugin returned: could NOT read 'resize-good/input' -- host returned 0 bytes (denied)

  -- attempt 2: phone home over the network --
  runtime BLOCKED the request: no NetworkHost capability granted

  -- attempt 3: burn CPU forever (DoS) --
  runtime KILLED the plugin: instruction/fuel budget exceeded
```

## Notes

- **Package versions** are pinned in `host/Hal.fsproj` (Extism.Sdk 1.10.0,
  Extism.runtime.all 1.13.0).
- **`Manifest.AllowedHosts`.** HAL only sets this when a policy grants network hosts;
  neither demo plugin does, so it stays dormant here. If you extend the demo to allow a
  host, confirm the property name/type against your SDK version
  (`https://extism.github.io/dotnet-sdk/api/Extism.Sdk.html`).
- On the Rust side, `http::request`'s exact generic/body signature has shifted slightly
  across PDK versions; if attempt 2 won't compile, check the version you resolved at
  `https://docs.rs/extism-pdk`.

## What "sandboxed" does and doesn't mean

The isolation boundary here is real: a plugin cannot reach data, network, or CPU it
wasn't granted. What WASM does **not** prevent is a plugin corrupting or misusing its
*own* linear memory, or timing side channels. For a plugin host that's exactly the
boundary you care about, but don't oversell it as "untrusted code can never misbehave
at all."

## The review skill (Claude Code / Cursor / Codex / Gemini)

HAL's idea also ships as an **agent skill** for AI code review: instead of
guessing whether PR code "looks malicious", the agent inventories what
authority the code *reaches for* (network, filesystem, process, data scopes,
new dependencies) and flags anything the PR's stated purpose doesn't require.

### Why bother: the specific problem

This is no longer a niche concern. Roughly 1 in 7 pull requests now involves
an AI agent in review, up from under 1% in 2022; a single review bot
(CodeRabbit) alone is installed on over 2 million repositories, and around
44% of engineering teams run AI review on at least some of their PRs. Every
one of those reviews shares the same blind spot:

An AI auto-reviewing a PR judges code by **how it reads**, and malicious code
is written to read well. The question "is this code secure?" is unanswerable
by inspection; the reviewer fails in predictable ways:

1. **Benign-looking exfiltration.** A PR titled "add retry logic" also POSTs
   error payloads to `https://logs-collector.example.dev`. The HTTP code is
   idiomatic and clean, so a style-focused reviewer sees "nice error
   handling" and never asks why a markdown formatter now talks to the network.
   Real-world shape: the 2018 `event-stream` npm attack, where a helpful
   maintainer's clean-looking dependency update harvested cryptocurrency
   wallets.
2. **Obfuscated intent.** The payload URL never appears as a string:
   it's base64, split across constants, or built at runtime. Pattern-matching
   for "suspicious code" finds nothing; an *authority inventory* still catches
   the socket being opened.
3. **Authority smuggled outside the code.** The diff's code is genuinely
   innocent, but it also adds a dependency with a `postinstall` script, or
   widens a GitHub Actions permission from `contents: read` to `write`, or
   adds `*` to an allowed-hosts manifest. Reviewers anchored on the code
   discuss naming while the actual attack is in the manifest line. Shape of
   the 2024 `xz` backdoor: the hostile payload rode in build scripts and test
   fixtures, not the readable source.
4. **Trusting the untrusted side's own checks.** The PR adds validation
   *inside* the plugin/client and the reviewer marks the concern resolved.
   But the untrusted party can simply not run its own checks. Only
   enforcement on the host/server side counts (that's exactly what this
   repo demonstrates).
5. **Slow-loris DoS.** No single line is dangerous, but an unbounded loop,
   recursive fetch, or catastrophic regex lets one plugin starve the host.
   "Looks correct" review passes it; a resource-bounds check doesn't.

The skill fixes this by swapping the unanswerable question for a checkable
one: **what authority does this diff reach for, and does its stated purpose
require it?** A formatter that opens a socket is a finding *no matter how
clean the socket code is*. No malice detection needed.

### Detonate before you download

Reading a diff only catches what is legible. Some overreach (obfuscated
triggers, `postinstall` and build scripts, URLs assembled at runtime) never
shows up until the code actually runs. So the skill's second rule is: if
reviewing a PR means running it (building, installing dependencies, running
tests, launching the app), never do that on your own machine with real
credentials and network. Run it somewhere disposable first.

The agent is told to refuse the local run and route the code to an isolated
environment instead: an ephemeral container with no secrets and no network, a
throwaway CI runner or VM, a microVM/gVisor sandbox, or (for a WASM plugin) a
capability-scoped host like HAL itself, which grants the code only the
authority its policy allows. Watch what it does in there (outbound
connections, files written, processes spawned), and bring it local only if it
stays inside its granted authority both on paper and at runtime. HAL is the
small, working example of that last option: the sandbox where the grant is
actually enforced.

This repo ships that pattern as a workflow: `.github/workflows/sandbox-pr.yml`
builds a PR and runs the host inside `docker --network none`, then fails the
job unless all three capability boundaries held. It triggers on `pull_request`
(not `pull_request_target`), so a fork PR runs with no repository secrets and a
read-only token. It isolates the *execution*; isolating the build too means
vendoring dependencies and building offline.

For your own repos there's a generic, copy-pastable version:
`templates/detonate-pr.yml`. Drop it in `.github/workflows/`, set three values
(`IMAGE`, `BUILD_CMD`, `RUN_CMD`), and it runs your tests in the same
network-denied, secret-free sandbox. A PR that phones home fails the job.

- Canonical skill: `.claude/skills/capability-security-review/SKILL.md`
- Cursor rule: `.cursor/rules/capability-security-review.mdc`
- Codex: `AGENTS.md`
- Gemini CLI: `GEMINI.md`; Gemini Code Assist (GitHub app): `.gemini/styleguide.md`

### SOP: Claude Code

1. **Install.** Either copy `.claude/skills/capability-security-review/` into
   the target repo's root, or install once for every project:

   ```bash
   mkdir -p ~/.claude/skills
   cp -r .claude/skills/capability-security-review ~/.claude/skills/
   ```

2. **Trigger.** Open `claude` in the repo with the PR and ask for a review;
   the skill auto-triggers on review requests, or invoke it by name:

   ```
   review PR 42 for security
   /capability-security-review the diff between main and this branch
   ```

   Headless (CI or scripts):

   ```bash
   gh pr checkout 42 && claude -p "capability security review of this branch vs main"
   ```

3. **Read the output.** Expect: a one-line statement of the PR's purpose, an
   inventory of every authority the diff reaches for, findings in the form
   *reach → why unneeded → smallest fix*, and a verdict line
   (approve / approve-with-changes / reject). If any of those parts is
   missing, say "follow the capability-security-review skill" and it will
   redo the review against the checklist.

### SOP: Cursor

1. **Install.** Copy `.cursor/rules/capability-security-review.mdc` into the
   target repo's `.cursor/rules/` folder. It is an agent-requested rule, so
   it loads only when review work comes up, not on every chat.
2. **Trigger.** In Agent chat, ask it to review the PR branch or a diff
   ("review this diff for security"). To force the rule explicitly, mention
   `@capability-security-review` in the message.
3. **Verify it engaged.** Cursor lists applied rules in the context panel of
   the response. If the rule is not listed, mention it with `@` and re-ask.

### SOP: Codex

1. **Install.** Copy this repo's `AGENTS.md` to the target repo's root. If
   the repo already has an `AGENTS.md`, paste in the "Reviewing PRs /
   third-party code" section instead of replacing the file. Also copy
   `.claude/skills/capability-security-review/SKILL.md` (same path), since
   `AGENTS.md` points to it for the full procedure.
2. **Trigger.** Codex reads `AGENTS.md` automatically at session start, so a
   plain request is enough:

   ```bash
   codex "review the diff between main and this branch"
   ```

3. **Read the output.** Same contract as Claude Code: purpose, authority
   inventory, findings, verdict. If it summarizes style instead, reply
   "apply the capability security review from AGENTS.md".

### SOP: Gemini

Two separate Gemini agents, two files:

1. **Gemini CLI** (terminal agent). Copy `GEMINI.md` to the target repo's
   root (merge the review section if one already exists) along with the
   SKILL.md it points to. Gemini CLI reads `GEMINI.md` at session start, so
   a plain request works:

   ```bash
   gemini "review the diff between main and this branch"
   ```

2. **Gemini Code Assist** (the GitHub app that auto-reviews PRs). Copy
   `.gemini/styleguide.md` into the target repo and install the app on it.
   The style guide is injected into every automatic PR review, so the
   capability checklist applies with no per-PR action. To re-run a review on
   demand, comment `/gemini review` on the PR. The styleguide is
   self-contained on purpose: the app does not follow pointers to other
   files.

One rule of use across all of these: paste or name the PR's *stated purpose*
(title + description) when you ask, because every judgment in the skill
compares reach against purpose. A vague purpose produces a vague review.

## Extending it

- Add a `FileRead of path: string` capability backed by a host function that only opens
  files under a granted directory.
- Give `resize-good` a real `NetworkHost "api.example.com"` and watch attempt 2 succeed
  for *that* host only.
- Model revocable capabilities: wrap a host function in a flag HAL can flip to cut off
  access mid-session, a nod to the replicant lifespans in *Blade Runner*.
