---
description: "Manage a project's marina dev services. Subcommands: add [project-path] (LLM analyzes & registers) | ls <id> | rm <id> <name>"
allowed-tools: Bash, Read, Glob, Grep
---
Dispatch on the first token of `$ARGUMENTS`:

- If it starts with **`add`** → run the **registration procedure** below (LLM analyzes the project and proposes services).
- If it starts with **`ls`** or **`rm`** → no analysis needed; **point the user at the CLI** (these are plain reads/deletes):
  - `ls <id>` → `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" service ls <id>` (shows merged definitions with source tags).
  - `rm <id> <name>` → `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" service rm <id> <name>` (add `--root` to remove a team/root definition).

  Run the matching command for the user; for `ls`, present the output; for `rm`, confirm the result. Don't analyze the repo for `ls`/`rm`.

---

## Registration procedure (`add [path]`)

Analyze the target project and register its runnable dev services with marina.

Target: the path token after `add` in `$ARGUMENTS`; if absent, use the current git project's main checkout via `git rev-parse --path-format=absolute --git-common-dir` → its dirname (a subrepo of it is also fine).

1. Resolve the project **id**: `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" project ls` and match the path, or register first with `project add` if missing.
2. Inspect the repo to find runnable services — read `package.json` (scripts.dev/start), `build.gradle*`/`settings.gradle*` (Spring bootRun modules), `Dockerfile`/`docker-compose.yml`, `pyproject.toml`/`requirements.txt` (uvicorn/flask). For each, derive `name` (a valid identifier), `portBase` (the app's default port; avoid collisions across services), `cwd` (relative to the project root / its subrepo), and `run` — a shell command using marina tokens `{port}` (and `{profile}` if the framework has profiles). Native example: `exec npm run dev -- --port {port}`. Docker example: `exec env HOST_PORT={port} COMPOSE_PROJECT_NAME=svc-{session} docker compose up`.
3. **Show the user the proposed services (name/port/cwd/run) and ask for confirmation.** Adjust per feedback.
4. Register each (central by default; pass `--root` only if the user wants it committed to the repo for team sharing):
   `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" service add <id> '<service-json>'`
5. Confirm with `"${CLAUDE_PLUGIN_ROOT}/scripts/marina-entrypoint.sh" project ls` and tell the user to refresh the dashboard.

> The dashboard's ✨ assist bar runs this same analysis directly (the daemon spawns the LLM read-only and fills/registers the form — no copy-paste). This slash command is the terminal/CLI equivalent for when you're already in a session.

Keep `run` a single shell command; complex startup should call a project-side helper script. Default to central storage so the project repo stays untouched unless the user asks for team sharing.
