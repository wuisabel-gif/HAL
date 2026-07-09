---
name: capability-security-review
description: Review a PR, diff, or third-party/plugin code through the capability-security lens — inventory what authority the code reaches for and flag anything its stated purpose doesn't require. Use when reviewing pull requests, auditing contributed/untrusted code, or when asked "is this code safe/secure?"
---

# Capability Security Review

Don't ask "does this code look malicious?" — you can't reliably tell, and
attackers write innocent-looking code. Ask instead: **what authority does this
code reach for, and does its stated purpose require it?** Unneeded authority is
a finding even when the code looks benign.

## Failure modes this skill exists to prevent

A reviewer who judges code by how it reads misses, specifically:

1. **Benign-looking exfiltration** — a "retry logic" PR that also POSTs
   payloads to an external host, written in clean idiomatic style
   (event-stream-style attack).
2. **Obfuscated intent** — the URL/command never appears literally; it's
   base64, split constants, or runtime-built. Style scanning finds nothing;
   an authority inventory still catches the socket.
3. **Authority smuggled outside the code** — the attack is in a new
   dependency's postinstall script, a widened CI permission, or a manifest
   wildcard, while the readable diff is innocent (xz-style attack).
4. **Trusting the untrusted side's own checks** — validation added inside the
   plugin/client "resolves" the concern, but the untrusted party can skip its
   own checks. Only host/server-side enforcement counts.
5. **Slow-loris DoS** — no single dangerous line, just an unbounded loop,
   recursion, or catastrophic regex that starves the host.

## Procedure

1. **State the purpose.** One sentence: what does this PR/plugin claim to do?
   (From the PR description, plugin manifest, or function names.) All later
   judgments compare against this sentence.

2. **Inventory reach.** Search the diff/code for every point where it touches
   the outside world:
   - **Network**: http clients, fetch, sockets, DNS, webhooks, telemetry SDKs,
     URLs in strings (especially base64/hex-encoded or concatenated ones)
   - **Filesystem**: open/read/write, path joins with user input, `..`
     traversal, temp files, globs, symlinks
   - **Process & environment**: exec/spawn/shell, env vars (secrets often live
     there), signals, clipboard
   - **Dynamic code**: eval, deserialization of untrusted data, reflection,
     loading modules/plugins from variable paths, downloading-then-executing
   - **Data access**: DB queries, key-value keys, API scopes — note the exact
     keys/tables/paths/scopes touched
   - **Dependencies**: every NEW dependency is inherited authority — check what
     *it* reaches for, typosquats, install scripts (postinstall), pinned vs
     floating versions
   - **CI/build/manifest changes**: workflows, permission manifests, allowed
     hosts, capability lists — widening any of these is the highest-signal
     change in the diff

3. **Compare reach vs purpose.** Everything in the inventory that the purpose
   sentence doesn't require is a finding. A markdown formatter that opens a
   socket is a finding no matter how clean the socket code is.

4. **Check the boundary, not the promise.** Validation inside untrusted code
   counts for nothing — the untrusted side can lie. Enforcement must live on
   the trusted side (host, server, API gateway, DB constraint). Flag any
   security check that only exists in the code being reviewed if that code is
   the untrusted party.

5. **Check resource bounds.** Unbounded loops, recursion, allocations,
   regexes vulnerable to catastrophic backtracking, unpaginated fetches —
   denial-of-service is overreach too. Note: optimizers can hide or create
   these; reason about the source, and remember a "dead" loop in source may
   be a real burn at a different opt level (and vice versa).

6. **Report.** For each finding: *what it reaches for → why the purpose
   doesn't need it → smallest change that removes the authority* (drop the
   permission, narrow the scope, move the check host-side, pin the version).
   Then one verdict line: **approve / approve-with-changes / reject**, with
   the single most important reason.

## Never execute untrusted code locally — detonate it in a sandbox first

Static reading only catches what is legible. Obfuscated triggers, `postinstall`
and build scripts, and runtime-built URLs stay invisible until the code *runs*.
So if reviewing this PR requires running it (building it, installing its deps,
executing its tests, launching the app), do NOT do that on the host machine
with real credentials, tokens, SSH keys, or network access. That is the exact
moment a benign-looking diff exfiltrates or persists.

Instead:

- **Refuse the local run.** State plainly that you will not `npm install`,
  `pip install`, `cargo run`, `make`, or run the app for an untrusted diff on
  the developer's machine. This refusal is the correct behavior, not an
  inconvenience.
- **Use a ready sandbox if the repo has one.** If a `detonate.sh` (or
  equivalent network-denied container wrapper) exists at the repo root, run the
  untrusted build/test through it and read the report, e.g.
  `./detonate.sh --build "npm ci" --image node:22 --run "npm test" --dir .`.
  That is the enacted version of this whole section.
- **Otherwise route it to an isolated environment** where overreach hits a wall
  instead of real assets. In rough order of cheap-and-available:
  - an ephemeral container with no secrets mounted and `--network none`
    (add a network only after review, scoped to the hosts the purpose needs);
  - a disposable CI runner or cloud VM you can throw away after;
  - a microVM / gVisor / Firecracker sandbox for stronger isolation;
  - for a WASM plugin specifically, a capability-scoped host like HAL — it
    runs the code with *only* the authority its policy grants and nothing
    else, so a denied reach fails at the boundary.
- **Watch what it actually does** in that sandbox: outbound connections,
  files written, processes spawned, env vars read. Runtime behavior that the
  diff's stated purpose doesn't explain is a finding, same rule as static.
- **Only then bring it local**, and only if it stayed inside its granted
  authority both on paper and at runtime.

The principle is the same one this repo demonstrates: don't decide whether to
trust the code, decide what authority to grant it — and grant that authority
in a place where the grant is enforced.

## Red flags that end the benefit of the doubt

- Encoded/obfuscated strings that decode to URLs, hostnames, or shell commands
- Reach that only activates under a condition unrelated to the feature
  (time, env var, specific user) — that's a trigger, not a feature
- New permission/manifest/CI scope wider than the code actually uses
- "Temporary" broad grants (`*` hosts, root paths, admin scopes)
- Diff touches security-relevant files the PR description doesn't mention

## Principle

This is the object-capability model applied to review: code should be handed
exactly the authority its job requires and nothing else, and the grant should
be enforced by the trusted side. If a reach can't be justified by the purpose,
the fix is to remove the authority — not to trust the code harder.
