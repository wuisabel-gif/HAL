# Review style guide: capability security

When reviewing a pull request, do not ask "does this code look malicious?"
Malicious code is written to read well. Ask instead: what authority does this
diff reach for, and does the PR's stated purpose require it? Unneeded
authority is a finding even when the code looks clean.

For every review:

1. State the PR's purpose in one sentence, from its title and description.
2. Inventory every point where the diff reaches for outside authority:
   - network (http clients, sockets, URLs in strings, encoded or
     concatenated hostnames)
   - filesystem (reads/writes, path joins with user input, traversal)
   - process and environment (exec/spawn, env vars, install scripts)
   - dynamic code (eval, deserialization, loading modules from variable paths)
   - data scopes (exact DB tables, KV keys, API scopes touched)
   - new dependencies (inherited authority; check postinstall scripts and
     pinning)
   - CI, manifest, and permission changes (widened scopes, wildcards,
     new allowed hosts) - the highest-signal lines in any diff
3. Flag every reach the stated purpose does not require, even if the code
   is idiomatic and clean.
4. Distrust checks inside the untrusted side. Validation added in a
   plugin/client resolves nothing; only host/server-side enforcement counts.
5. Check resource bounds: unbounded loops, recursion, allocations, and
   catastrophic regexes are denial-of-service overreach.
6. For each finding report: what it reaches for, why the purpose does not
   need it, and the smallest change that removes the authority. End with a
   verdict: approve, approve with changes, or reject.
