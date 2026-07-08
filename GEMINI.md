# Gemini instructions

## Reviewing PRs / third-party code

When asked to review a pull request, a diff, or any contributed/untrusted
code, read and follow the procedure in
`.claude/skills/capability-security-review/SKILL.md`.

Summary of the rule: don't judge whether code *looks* malicious. Inventory
every point where it reaches for outside authority (network, filesystem,
process/env, dynamic code, data scopes, new dependencies, CI/manifest
changes), compare that against the PR's stated purpose, and flag every reach
the purpose doesn't require. Security enforcement must live on the trusted
side; validation inside the untrusted code counts for nothing.
