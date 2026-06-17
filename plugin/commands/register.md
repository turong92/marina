---
description: Register the current project with marina so its worktrees auto-attach
allowed-tools: Bash
---
Register the current git project with marina (infers subrepos + worktree globs). Run exactly this and report the result:

```bash
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "not a git repository — cd into your project first"; exit 1; }
"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" project add "$(dirname "$common")"
```

This resolves the main checkout (even if run from a worktree) and registers it. Confirm the printed project id and inferred subrepos look right; if a subrepo is missing or extra, tell the user they can re-run after fixing, or edit `~/.marina/projects.json`.
