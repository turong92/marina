---
description: "Manage marina projects. Subcommands: add [path] | ls | rm <id> | infer [path] | default <id> a,b,c"
allowed-tools: Bash
---
Dispatch on the first token of `$ARGUMENTS`. `ENTRY="${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh"`.

- **`add [path]`** — register a project so its worktrees auto-attach. If a `[path]` token follows, register that path. Otherwise resolve the current git project's main checkout (works even from a worktree) and register it:

  ```bash
  ENTRY="${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh"
  read -r _subcmd path <<< "$ARGUMENTS"   # drop the 'add' token; rest (may contain spaces) is the path
  if [ -z "$path" ]; then
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "not a git repository — cd into your project first, or pass a path: /marina:project add <path>"; exit 1; }
    path="$(dirname "$common")"
  fi
  "$ENTRY" project add "$path"
  ```

  This infers subrepos (nested git repos) and worktree globs. Confirm the printed project **id** and inferred **subrepos** look right; if a subrepo is missing or extra, tell the user they can re-run after fixing, or edit `~/.marina/projects.json`.

- **`ls`** → `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" project ls` — list registered projects; present the output.

- **`rm <id>`** → `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" project rm <id>` — unregister a project.

- **`infer [path]`** → print the inferred draft (subrepos + worktree globs) as JSON **without** modifying the registry — use it to preview before `add`. `infer` **requires** a path (unlike `add`, it has no current-project fallback), so resolve one if the user omitted it:

  ```bash
  ENTRY="${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh"
  read -r _subcmd path <<< "$ARGUMENTS"
  if [ -z "$path" ]; then
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "not a git repository — pass a path: /marina:project infer <path>"; exit 1; }
    path="$(dirname "$common")"
  fi
  "$ENTRY" project infer "$path"
  ```

- **`default <id> a,b,c`** → `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" project default <id> a,b,c` — set the default subrepos to auto-attach for that project (comma-separated names).

Run the matching command for the user and report the result.
